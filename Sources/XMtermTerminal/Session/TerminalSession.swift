import Darwin
import Foundation
import Observation
import XMtermCore

package enum TerminalSessionIOFailureDisposition: Equatable, Sendable {
    case awaitProcessExit
    case failSession
}

package enum TerminalCloseDisposition: Equatable, Sendable {
    case closeImmediately
    case confirmForegroundJob
    case confirmUnknownForegroundActivity
    case confirmSSHSession

    package var requiresConfirmation: Bool {
        self != .closeImmediately
    }
}

/// Main-actor boundary joining one retained terminal engine to one PTY process.
///
/// The AppKit view never owns a file descriptor. PTY reads, writes, resizing, and child reaping
/// remain isolated in `PTYProcessController`; this object only routes bounded chunks between the
/// controller and the retained view.
@MainActor
@Observable
package final class TerminalSession {
    /// UUID compatibility projection retained for the Phase 1/2 workspace map.
    package let id: UUID
    package let sessionID: TerminalSessionID
    package let launchSpecification: SessionLaunchSpecification
    package let kind: TerminalTabKind
    package let terminalView: XMtermTerminalView

    package private(set) var lifecycle: TerminalLifecycle = .idle
    package private(set) var hasNewOutputBelow = false
    package private(set) var activeAlert: TerminalSessionAlert?
    package private(set) var currentDirectory: String?

    @ObservationIgnored package var onLifecycleEvent: ((TerminalLifecycleEvent) -> Void)?
    @ObservationIgnored package var onTitleChanged: ((String) -> Void)?
    @ObservationIgnored package var onLocalAction: ((TerminalLocalAction) -> Void)?
    @ObservationIgnored package var onCleanupFinished: (() -> Void)?
    @ObservationIgnored package var onCleanupFailed: ((String) -> Void)?

    @ObservationIgnored private let configurationProvider: (TerminalGridSize) throws -> PTYLaunchConfiguration
    @ObservationIgnored private let processLauncher: TerminalProcessLauncher
    @ObservationIgnored private var process: (any TerminalProcess)?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var inputDrainTask: Task<Void, Never>?
    @ObservationIgnored private var resizeDrainTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInput: [[UInt8]] = []
    @ObservationIgnored private var pendingInputByteCount = 0
    @ObservationIgnored private var pendingResize: TerminalGridSize?
    @ObservationIgnored private var latestGridSize = TerminalGridSize(columns: 80, rows: 24)
    @ObservationIgnored private var pasteCompletion: ((Bool) -> Void)?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var didFinishCleanup = false
    @ObservationIgnored private var cleanupShouldNotifyOwner = false

    private static let outputChunkSize = 16 * 1024
    private static let maximumQueuedInputBytes = TerminalConfiguration.pasteByteLimit

    package convenience init(id: UUID, kind: TerminalTabKind = .local) {
        let title = switch kind {
        case .local: "Local Shell"
        case .relaySSH: "Relay Host"
        }
        self.init(
            sessionID: TerminalSessionID(rawValue: id),
            launchSpecification: .legacy(kind: kind, title: title),
            configurationFactory: .live(),
            processLauncher: PTYProcessController.launch
        )
    }

    package convenience init(
        sessionID: TerminalSessionID = TerminalSessionID(),
        launchSpecification: SessionLaunchSpecification
    ) {
        self.init(
            sessionID: sessionID,
            launchSpecification: launchSpecification,
            configurationFactory: .live(),
            processLauncher: PTYProcessController.launch
        )
    }

    package convenience init(
        id: UUID,
        shellResolver: @escaping () throws -> ResolvedTerminalShell
    ) {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        let userHomeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        self.init(
            sessionID: TerminalSessionID(rawValue: id),
            launchSpecification: .legacy(kind: .local, title: "Local Shell"),
            configurationFactory: SessionLaunchConfigurationFactory(
                inheritedEnvironment: inheritedEnvironment,
                userHomeDirectory: userHomeDirectory,
                loginShellResolver: shellResolver,
                isUsableExecutableFile: { _ in true }
            ),
            processLauncher: PTYProcessController.launch
        )
    }

    package convenience init(
        id: UUID,
        kind: TerminalTabKind,
        inheritedEnvironment: [String: String],
        userHomeDirectory: String,
        processLauncher: @escaping TerminalProcessLauncher
    ) {
        let title = switch kind {
        case .local: "Local Shell"
        case .relaySSH: "Relay Host"
        }
        self.init(
            sessionID: TerminalSessionID(rawValue: id),
            launchSpecification: .legacy(kind: kind, title: title),
            configurationFactory: SessionLaunchConfigurationFactory(
                inheritedEnvironment: inheritedEnvironment,
                userHomeDirectory: userHomeDirectory,
                loginShellResolver: { try TerminalSession.resolveShell() },
                isUsableExecutableFile: TerminalSession.isUsableExecutableFile(at:)
            ),
            processLauncher: processLauncher
        )
    }

    package init(
        sessionID: TerminalSessionID,
        launchSpecification: SessionLaunchSpecification,
        configurationFactory: SessionLaunchConfigurationFactory,
        processLauncher: @escaping TerminalProcessLauncher
    ) {
        id = sessionID.rawValue
        self.sessionID = sessionID
        self.launchSpecification = launchSpecification
        kind = launchSpecification.kind
        self.processLauncher = processLauncher
        configurationProvider = { size in
            try configurationFactory.configuration(
                for: launchSpecification,
                initialSize: size
            )
        }
        terminalView = XMtermTerminalView(frame: .zero)
        terminalView.acceptsInput = false
        installViewCallbacks()
    }

    package func start() {
        guard !didStart else { return }
        didStart = true
        transition(by: .startRequested)
        launchTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.launchShell()
        }
    }

    package func focus() {
        terminalView.focus()
    }

    package func showFind() {
        terminalView.showFindBar()
    }

    package func jumpToLatestOutput() {
        terminalView.jumpToLatestOutput()
        hasNewOutputBelow = false
    }

    package func closeDisposition() async -> TerminalCloseDisposition {
        guard lifecycle == .running, let process else {
            return .closeImmediately
        }
        guard kind == .local else { return .confirmSSHSession }
        let foregroundState = await process.foregroundProcessGroupState()
        return Self.closeDisposition(
            kind: kind,
            lifecycle: lifecycle,
            foregroundState: foregroundState
        )
    }

    package nonisolated static func closeDisposition(
        lifecycle: TerminalLifecycle,
        foregroundState: PTYForegroundProcessGroupState
    ) -> TerminalCloseDisposition {
        closeDisposition(
            kind: .local,
            lifecycle: lifecycle,
            foregroundState: foregroundState
        )
    }

    package nonisolated static func closeDisposition(
        kind: TerminalTabKind,
        lifecycle: TerminalLifecycle,
        foregroundState: PTYForegroundProcessGroupState
    ) -> TerminalCloseDisposition {
        guard lifecycle == .running else { return .closeImmediately }
        guard kind == .local else { return .confirmSSHSession }
        switch foregroundState {
        case .shell, .terminalUnavailable:
            return .closeImmediately
        case .foregroundJob:
            return .confirmForegroundJob
        case .queryFailed:
            return .confirmUnknownForegroundActivity
        }
    }

    /// Starts deterministic PTY cleanup. The owning workspace may remove the visible tab
    /// immediately, but retains this session until `onCleanupFinished` fires.
    package func requestClose() {
        if lifecycle == .idle || lifecycle == .starting || lifecycle == .running {
            transition(by: .closeRequested)
        }
        terminalView.acceptsInput = false
        cancelPendingPaste()
        pendingInput = []
        pendingInputByteCount = 0
        pendingResize = nil

        guard let process else {
            if didStart, launchTask != nil {
                // Launch may currently be inside forkpty/execve. It observes `.closing` and
                // immediately closes the resulting controller instead of exposing it as running.
                return
            }
            finishCleanup()
            return
        }
        beginCleanup(of: process, outputPolicy: .discard)
    }

    package func resolvePasteAlert(approved: Bool) {
        guard case .paste = activeAlert else { return }
        let completion = pasteCompletion
        pasteCompletion = nil
        activeAlert = nil
        completion?(approved)
    }

    package func dismissAlert() {
        if case .paste = activeAlert {
            resolvePasteAlert(approved: false)
        } else {
            activeAlert = nil
        }
    }

    private func installViewCallbacks() {
        terminalView.onBytesToPTY = { [weak self] bytes in
            self?.enqueueInput(bytes)
        }
        terminalView.onGridSizeChanged = { [weak self] size in
            self?.enqueueResize(size)
        }
        terminalView.onTitleChanged = { [weak self] title in
            self?.onTitleChanged?(title)
        }
        terminalView.onCurrentDirectoryChanged = { [weak self] directory in
            self?.currentDirectory = directory
        }
        terminalView.onScrollPositionChanged = { [weak self] position in
            guard let self else { return }
            if position >= 0.999 {
                self.hasNewOutputBelow = false
            }
        }
        terminalView.onLocalAction = { [weak self] action in
            self?.onLocalAction?(action)
        }
        terminalView.onPasteConfirmationRequested = { [weak self] payload, completion in
            self?.requestPasteConfirmation(for: payload, completion: completion)
        }
        terminalView.onPasteRejected = { [weak self] rejection in
            self?.presentError(rejection.userFacingMessage)
        }
    }

    private func launchShell() async {
        do {
            let configuration = try configurationProvider(latestGridSize)
            let launchedProcess = try await processLauncher(configuration)
            process = launchedProcess
            launchTask = nil

            if lifecycle == .closing {
                beginCleanup(of: launchedProcess, outputPolicy: .discard)
            } else if let status = await launchedProcess.childExitStatusIfAvailable() {
                let outputTask = startOutputMonitoring(launchedProcess)
                await outputTask.value
                handleProcessExit(status)
            } else {
                startMonitoring(launchedProcess)
                transition(by: .launchSucceeded)
                terminalView.acceptsInput = lifecycle.acceptsInput
                enqueueResize(latestGridSize)
                terminalView.focus()
            }
        } catch {
            launchTask = nil
            if lifecycle == .closing {
                finishCleanup()
                return
            }
            transition(by: launchFailureEvent(for: error))
        }
    }

    private func startMonitoring(_ process: any TerminalProcess) {
        let outputTask = startOutputMonitoring(process)
        exitTask = Task<Void, Never> { [weak self] in
            do {
                let status = try await process.waitForExit()
                await outputTask.value
                self?.handleProcessExit(status)
            } catch is CancellationError {
                return
            } catch {
                self?.handleFatalIOFailure(.readFailed("Child process monitoring failed."))
            }
        }
    }

    private func startOutputMonitoring(_ process: any TerminalProcess) -> Task<Void, Never> {
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.consumeOutput(from: process)
        }
        outputTask = task
        return task
    }

    private func consumeOutput(from process: any TerminalProcess) async {
        do {
            while let bytes = try await process.read(upToCount: Self.outputChunkSize) {
                guard !bytes.isEmpty else { continue }
                let wasReadingHistory = terminalView.isViewingScrollback
                terminalView.receivePTYOutput(bytes)
                if wasReadingHistory {
                    hasNewOutputBelow = true
                }
            }
        } catch is CancellationError {
            return
        } catch {
            handleFatalIOFailure(.readFailed("PTY output could not be read."))
        }
    }

    private func handleProcessExit(_ status: TerminalExitStatus) {
        process = nil
        terminalView.acceptsInput = false
        pendingInput = []
        pendingInputByteCount = 0
        pendingResize = nil

        switch lifecycle {
        case .idle, .starting, .running, .closing, .failed:
            transition(by: .processExited(status))
        case .exited:
            break
        }
    }

    private func enqueueInput(_ bytes: [UInt8]) {
        guard lifecycle.acceptsInput, !bytes.isEmpty else { return }
        guard bytes.count <= Self.maximumQueuedInputBytes - pendingInputByteCount else {
            handleFatalIOFailure(.writeFailed("The terminal input queue reached its safety limit."))
            return
        }

        pendingInput = pendingInput + [bytes]
        pendingInputByteCount += bytes.count
        guard inputDrainTask == nil else { return }
        inputDrainTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drainInput()
        }
    }

    private func drainInput() async {
        defer { inputDrainTask = nil }
        while lifecycle.acceptsInput, !pendingInput.isEmpty {
            let bytes = pendingInput[0]
            pendingInput = Array(pendingInput.dropFirst())
            pendingInputByteCount -= bytes.count
            guard let process else { return }

            do {
                try await process.write(bytes)
            } catch is CancellationError {
                return
            } catch {
                handleIOFailure(
                    error,
                    fallbackEvent: .writeFailed("PTY input could not be written.")
                )
                return
            }
        }
    }

    private func enqueueResize(_ size: TerminalGridSize) {
        latestGridSize = size
        pendingResize = size
        guard lifecycle.acceptsInput, resizeDrainTask == nil else { return }
        resizeDrainTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drainResize()
        }
    }

    private func drainResize() async {
        defer { resizeDrainTask = nil }
        while lifecycle.acceptsInput, let size = pendingResize {
            pendingResize = nil
            guard let process else { return }
            do {
                try await process.resize(to: size)
            } catch is CancellationError {
                return
            } catch {
                handleIOFailure(
                    error,
                    fallbackEvent: .resizeFailed("The PTY window size could not be updated.")
                )
                return
            }
        }
    }

    package nonisolated static func ioFailureDisposition(
        for error: Error
    ) -> TerminalSessionIOFailureDisposition {
        guard let controllerError = error as? PTYControllerError else {
            return .failSession
        }
        switch controllerError {
        case .closed:
            return .awaitProcessExit
        case let .writeFailed(errorNumber), let .resizeFailed(errorNumber):
            return errorNumber == EIO || errorNumber == ENXIO
                ? .awaitProcessExit
                : .failSession
        default:
            return .failSession
        }
    }

    private func handleIOFailure(
        _ error: Error,
        fallbackEvent: TerminalLifecycleEvent
    ) {
        guard Self.ioFailureDisposition(for: error) == .failSession else { return }
        handleFatalIOFailure(fallbackEvent)
    }

    private func handleFatalIOFailure(_ event: TerminalLifecycleEvent) {
        guard case .running = lifecycle else { return }
        transition(by: event)
        terminalView.acceptsInput = false
        cancelPendingPaste()
        if let process {
            beginCleanup(
                of: process,
                notifyOwner: false,
                outputPolicy: .drain
            )
        }
    }

    private func beginCleanup(
        of process: any TerminalProcess,
        notifyOwner: Bool = true,
        outputPolicy: PTYCloseOutputPolicy
    ) {
        cleanupShouldNotifyOwner = cleanupShouldNotifyOwner || notifyOwner
        guard cleanupTask == nil else { return }
        cleanupTask = Task<Void, Never> { [weak self] in
            var cleanupFailed = false
            do {
                _ = try await process.close(outputPolicy: outputPolicy)
            } catch is CancellationError {
                return
            } catch {
                cleanupFailed = true
            }
            guard let self else { return }
            await self.outputTask?.value
            self.process = nil
            self.inputDrainTask?.cancel()
            self.resizeDrainTask?.cancel()
            if cleanupFailed {
                self.onCleanupFailed?(
                    self.kind == .relaySSH
                        ? "XMterm could not verify that the SSH process was fully cleaned up."
                        : "XMterm could not verify that the local terminal process was fully cleaned up."
                )
            }
            if self.cleanupShouldNotifyOwner {
                self.finishCleanup()
            }
        }
    }

    private func requestPasteConfirmation(
        for payload: TerminalPastePayload,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        cancelPendingPaste()
        pasteCompletion = completion
        let lineCount = payload.normalizedText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count
        activeAlert = .paste(
            TerminalPastePrompt(
                byteCount: payload.normalizedText.utf8.count,
                lineCount: lineCount,
                containsControlCharacters: payload.requiresConfirmation && !payload.isMultiline
            )
        )
    }

    private func presentError(_ message: String) {
        cancelPendingPaste()
        activeAlert = .error(TerminalSessionErrorAlert(message: message))
    }

    private func cancelPendingPaste() {
        let completion = pasteCompletion
        pasteCompletion = nil
        if case .paste = activeAlert {
            activeAlert = nil
        }
        completion?(false)
    }

    private func transition(by event: TerminalLifecycleEvent) {
        do {
            lifecycle = try lifecycle.transitioned(by: event)
            terminalView.acceptsInput = lifecycle.acceptsInput
            onLifecycleEvent?(event)
        } catch {
            terminalView.acceptsInput = false
            lifecycle = .failed(.launch(message: "Terminal lifecycle invariant failed."))
            presentError("XMterm could not safely continue this terminal session.")
        }
    }

    private func finishCleanup() {
        guard !didFinishCleanup else { return }
        didFinishCleanup = true
        launchTask?.cancel()
        outputTask?.cancel()
        exitTask?.cancel()
        inputDrainTask?.cancel()
        resizeDrainTask?.cancel()
        onCleanupFinished?()
    }

    private func launchFailureEvent(for error: Error) -> TerminalLifecycleEvent {
        switch error {
        case PTYControllerError.ptyCreationFailed:
            .ptyCreationFailed("Native PTY creation failed.")
        default:
            .launchFailed(
                kind == .relaySSH
                    ? "The SSH process could not be launched."
                    : "The configured login shell could not be launched."
            )
        }
    }

    private static func resolveShell() throws -> ResolvedTerminalShell {
        let environment = ProcessInfo.processInfo.environment
        return try TerminalShellResolver.resolve(
            accountShell: accountShellPath(),
            environmentShell: environment["SHELL"],
            userHomeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            isUsableExecutableFile: isUsableExecutableFile(at:)
        )
    }

    private static func launchEnvironment(
        inherited: [String: String],
        shellPath: String
    ) -> [String: String] {
        return inherited.merging(
            [
                "SHELL": shellPath,
                "TERM": TerminalConfiguration.termName,
                "TERM_PROGRAM": "XMterm"
            ],
            uniquingKeysWith: { _, xmtermValue in xmtermValue }
        )
    }

    private static func accountShellPath() -> String? {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = buffer.withUnsafeMutableBufferPointer { storage in
            getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &result)
        }
        guard status == 0, result != nil, let shell = account.pw_shell else { return nil }
        let value = String(cString: shell).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isUsableExecutableFile(at path: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: path) else { return false }
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
