import Foundation
import Observation
import XMtermCore
import XMtermRemote
import XMtermTerminal

struct TerminalClosePrompt: Identifiable, Equatable {
    let id: UUID
    let tabID: TerminalTab.ID
    let title: String
    let disposition: TerminalCloseDisposition

    init(
        tabID: TerminalTab.ID,
        title: String,
        disposition: TerminalCloseDisposition
    ) {
        id = UUID()
        self.tabID = tabID
        self.title = title
        self.disposition = disposition
    }
}

enum TerminalWorkspaceShutdownScope: Equatable {
    case window
    case application
}

struct TerminalWorkspaceShutdownPrompt: Identifiable, Equatable {
    let id: UUID
    let scope: TerminalWorkspaceShutdownScope
    let foregroundJobCount: Int
    let unknownForegroundActivityCount: Int
    let sshSessionCount: Int

    var confirmationTerminalCount: Int {
        foregroundJobCount + unknownForegroundActivityCount + sshSessionCount
    }

    init(
        scope: TerminalWorkspaceShutdownScope,
        foregroundJobCount: Int,
        unknownForegroundActivityCount: Int,
        sshSessionCount: Int
    ) {
        id = UUID()
        self.scope = scope
        self.foregroundJobCount = foregroundJobCount
        self.unknownForegroundActivityCount = unknownForegroundActivityCount
        self.sshSessionCount = sshSessionCount
    }
}

enum TerminalWorkspaceAlert: Identifiable, Equatable {
    case close(TerminalClosePrompt)
    case shutdown(TerminalWorkspaceShutdownPrompt)
    case error(id: UUID, message: String)

    var id: UUID {
        switch self {
        case let .close(prompt): prompt.id
        case let .shutdown(prompt): prompt.id
        case let .error(id, _): id
        }
    }
}

private struct PendingWorkspaceShutdown {
    let prompt: TerminalWorkspaceShutdownPrompt
    let completions: [@MainActor (Bool) -> Void]
}

private struct PendingWorkspaceShutdownEvaluation {
    let scope: TerminalWorkspaceShutdownScope
    let completions: [@MainActor (Bool) -> Void]
}

typealias TerminalCloseDispositionResolver = @MainActor (TerminalSession) async
    -> TerminalCloseDisposition
typealias TerminalTabIDSource = @MainActor () -> UUID
typealias TerminalSessionIDSource = @MainActor () -> TerminalSessionID
typealias TerminalLaunchPreflight = @MainActor (SessionLaunchSpecification) throws -> Void
typealias TerminalSessionFactory = @MainActor (
    TerminalSessionID,
    SessionLaunchSpecification
) throws -> TerminalSession
typealias LegacyTerminalSessionFactory = @MainActor (UUID, TerminalTabKind) -> TerminalSession

private enum TerminalWorkspaceLaunchError: Error {
    case factoryContractViolation
    case identityCollision
    case missingPreparedTab
}

/// Window-local owner of immutable tab state and stable per-tab terminal sessions.
@MainActor
@Observable
final class TerminalWorkspaceStore {
    private(set) var tabsState = TerminalTabsState()
    private(set) var runtimes: [TerminalTab.ID: RuntimeSession] = [:]
    var activeAlert: TerminalWorkspaceAlert?

    private var pendingRuntimeRemoval: Set<TerminalTab.ID> = []
    @ObservationIgnored private let closeDispositionResolver: TerminalCloseDispositionResolver
    @ObservationIgnored private let tabIDSource: TerminalTabIDSource
    @ObservationIgnored private let sessionIDSource: TerminalSessionIDSource
    @ObservationIgnored private let launchPreflight: TerminalLaunchPreflight
    @ObservationIgnored private let sessionFactory: TerminalSessionFactory
    @ObservationIgnored private let remoteWorkspaceFactory: RemoteWorkspaceFactory
    @ObservationIgnored var newTerminalRequest: (@MainActor () -> Void)?
    @ObservationIgnored private var closeDispositionTasks: [
        TerminalTab.ID: Task<Void, Never>
    ] = [:]
    @ObservationIgnored private var shutdownEvaluationTask: Task<Void, Never>?
    private var didStart = false
    private var isShuttingDown = false
    private var pendingShutdown: PendingWorkspaceShutdown?
    private var pendingShutdownEvaluation: PendingWorkspaceShutdownEvaluation?
    private var shutdownCompletions: [@MainActor (Bool) -> Void] = []
    private var shutdownFailureMessage: String?

    var tabs: [TerminalTab] { tabsState.tabs }

    var sessions: [TerminalTab.ID: TerminalSession] {
        runtimes.mapValues(\.terminal)
    }

    var selectedTab: TerminalTab? {
        guard let selectedTabID = tabsState.selectedTabID else { return nil }
        return tabsState.tabs.first { $0.id == selectedTabID }
    }

    var selectedRuntime: RuntimeSession? {
        guard let selectedTabID = tabsState.selectedTabID else { return nil }
        return runtimes[selectedTabID]
    }

    var selectedSession: TerminalSession? { selectedRuntime?.terminal }

    var canCreateTerminal: Bool {
        !isShuttingDown && pendingShutdown == nil && pendingShutdownEvaluation == nil
    }

    init(
        closeDispositionResolver: @escaping TerminalCloseDispositionResolver = {
            await $0.closeDisposition()
        },
        tabIDSource: @escaping TerminalTabIDSource = { UUID() },
        sessionIDSource: @escaping TerminalSessionIDSource = { TerminalSessionID() },
        launchPreflight: @escaping TerminalLaunchPreflight = { specification in
            _ = try SessionLaunchConfigurationFactory.live().configuration(
                for: specification,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )
        },
        sessionFactory: @escaping TerminalSessionFactory = { sessionID, specification in
            TerminalSession(
                sessionID: sessionID,
                launchSpecification: specification
            )
        },
        remoteWorkspaceFactory: @escaping RemoteWorkspaceFactory = { _, _ in
            RemoteWorkspace(provider: UnavailableRemoteFileProvider())
        }
    ) {
        self.closeDispositionResolver = closeDispositionResolver
        self.tabIDSource = tabIDSource
        self.sessionIDSource = sessionIDSource
        self.launchPreflight = launchPreflight
        self.sessionFactory = sessionFactory
        self.remoteWorkspaceFactory = remoteWorkspaceFactory
    }

    convenience init(
        closeDispositionResolver: @escaping TerminalCloseDispositionResolver = {
            await $0.closeDisposition()
        },
        sessionFactory: @escaping LegacyTerminalSessionFactory
    ) {
        self.init(
            closeDispositionResolver: closeDispositionResolver,
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                sessionFactory(sessionID.rawValue, specification.kind)
            }
        )
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        createTerminal()
    }

    func createTerminal() {
        createTerminal(kind: .local)
    }

    func createSSHTerminal() {
        createTerminal(kind: .relaySSH)
    }

    @discardableResult
    func openProfile(_ profile: SessionProfile) -> Bool {
        guard canCreateTerminal else { return false }

        do {
            let specification = try SessionLaunchSpecification(profile: profile)
            try launchPreflight(specification)
            let tabID = tabIDSource()
            let nextState = try tabsState.creatingTab(
                launchSpecification: specification,
                id: tabID
            )
            try publishPreparedRuntime(
                specification: specification,
                tabID: tabID,
                nextState: nextState
            )
            return true
        } catch let error as SessionLaunchConfigurationError {
            presentWorkspaceError(profileLaunchMessage(for: error))
            return false
        } catch {
            presentWorkspaceError("XMterm could not launch the selected session profile.")
            return false
        }
    }

    private func profileLaunchMessage(
        for error: SessionLaunchConfigurationError
    ) -> String {
        switch error {
        case .loginShellExecutableUnavailable:
            "The macOS login shell is unavailable. Review the account shell configuration and try again."
        case .customShellExecutableUnavailable:
            "The saved custom shell is unavailable. Edit the session profile and choose an executable shell."
        case .sshExecutableUnavailable:
            "System OpenSSH is unavailable, so XMterm cannot launch this SSH session."
        }
    }

    private func createTerminal(kind: TerminalTabKind) {
        guard canCreateTerminal else { return }
        let tabID = tabIDSource()
        do {
            let nextState = try tabsState.creatingTab(kind: kind, id: tabID)
            guard let specification = nextState.tabs.first(where: { $0.id == tabID })?
                .launchSpecification else {
                throw TerminalWorkspaceLaunchError.missingPreparedTab
            }
            try launchPreflight(specification)
            try publishPreparedRuntime(
                specification: specification,
                tabID: tabID,
                nextState: nextState
            )
        } catch {
            let terminalKind = kind == .relaySSH ? "SSH" : "local"
            presentWorkspaceError("XMterm could not create another \(terminalKind) terminal tab.")
        }
    }

    private func publishPreparedRuntime(
        specification: SessionLaunchSpecification,
        tabID: TerminalTab.ID,
        nextState: TerminalTabsState
    ) throws {
        let sessionID = sessionIDSource()
        let profileID = specification.sourceProfileID.rawValue
        let preparedTabIDs = Set(nextState.tabs.map(\.id))
        let retainedTabIDs = Set(runtimes.keys)
        let retainedSessionIDs = Set(runtimes.values.map { $0.id.rawValue })
        let retainedProfileIDs = Set(
            runtimes.values.map { $0.launchSpecification.sourceProfileID.rawValue }
        )
        let newIdentifiers: Set<UUID> = [tabID, sessionID.rawValue, profileID]
        let newEphemeralIdentifiers: Set<UUID> = [tabID, sessionID.rawValue]
        guard newIdentifiers.count == 3,
              !preparedTabIDs.contains(sessionID.rawValue),
              retainedTabIDs.isDisjoint(with: newIdentifiers),
              retainedSessionIDs.isDisjoint(with: newIdentifiers),
              retainedProfileIDs.isDisjoint(with: newEphemeralIdentifiers) else {
            throw TerminalWorkspaceLaunchError.identityCollision
        }

        let terminal = try sessionFactory(sessionID, specification)
        guard terminal.sessionID == sessionID,
              terminal.launchSpecification == specification,
              terminal.lifecycle == .idle else {
            throw TerminalWorkspaceLaunchError.factoryContractViolation
        }
        let remoteWorkspace: RemoteWorkspace? = switch specification.target {
        case .local:
            nil
        case .ssh:
            remoteWorkspaceFactory(sessionID, specification)
        }
        if let remoteWorkspace,
           runtimes.values.contains(where: { $0.remoteWorkspace === remoteWorkspace }) {
            throw TerminalWorkspaceLaunchError.factoryContractViolation
        }
        let runtime: RuntimeSession
        do {
            runtime = try RuntimeSession(
                id: sessionID,
                launchSpecification: specification,
                terminal: terminal,
                remoteWorkspace: remoteWorkspace
            )
        } catch {
            throw TerminalWorkspaceLaunchError.factoryContractViolation
        }
        configure(runtime, id: tabID)

        tabsState = nextState
        runtimes = runtimes.merging([tabID: runtime]) { existing, _ in existing }
        runtime.start()
        focus(terminal)
    }

    func selectTab(_ id: TerminalTab.ID) {
        let selectedState = tabsState.selectingTab(id: id)
        guard selectedState.selectedTabID == id else { return }
        tabsState = selectedState
        if let runtime = runtimes[id] {
            focus(runtime.terminal)
        }
    }

    func requestClose(_ id: TerminalTab.ID) {
        guard !isShuttingDown,
              pendingShutdown == nil,
              pendingShutdownEvaluation == nil,
              closeDispositionTasks[id] == nil,
              tabsState.tabs.contains(where: { $0.id == id }),
              let runtime = runtimes[id] else {
            if runtimes[id] == nil {
                closeImmediately(id)
            }
            return
        }

        let resolver = closeDispositionResolver
        let task = Task { @MainActor [weak self, weak runtime] in
            guard let runtime else { return }
            let disposition = await resolver(runtime.terminal)
            guard !Task.isCancelled else { return }
            self?.finishCloseDispositionEvaluation(
                disposition,
                for: id,
                runtime: runtime
            )
        }
        closeDispositionTasks = closeDispositionTasks.merging([id: task]) {
            existing, _ in existing
        }
    }

    func requestCloseSelected() {
        guard let selectedTabID = tabsState.selectedTabID else { return }
        requestClose(selectedTabID)
    }

    func confirmClose(_ prompt: TerminalClosePrompt) {
        guard case .close(prompt) = activeAlert else { return }
        activeAlert = nil
        closeImmediately(prompt.tabID)
    }

    func dismissWorkspaceAlert() {
        if case .shutdown = activeAlert {
            let completions = pendingShutdown?.completions ?? []
            pendingShutdown = nil
            activeAlert = nil
            for completion in completions {
                completion(false)
            }
            if let selectedSession {
                focus(selectedSession)
            }
            return
        }
        activeAlert = nil
        if let selectedSession {
            focus(selectedSession)
        }
    }

    func findInSelectedTerminal() {
        selectedSession?.showFind()
    }

    func focusSelectedTerminal() {
        guard let selectedSession else { return }
        focus(selectedSession)
    }

    func requestWorkspaceShutdown(
        _ scope: TerminalWorkspaceShutdownScope,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isShuttingDown else {
            shutdownCompletions.append(completion)
            finishWorkspaceShutdownIfPossible()
            return
        }

        if let pendingShutdown {
            let combinedScope: TerminalWorkspaceShutdownScope =
                pendingShutdown.prompt.scope == .application || scope == .application
                ? .application
                : .window
            let prompt = TerminalWorkspaceShutdownPrompt(
                scope: combinedScope,
                foregroundJobCount: pendingShutdown.prompt.foregroundJobCount,
                unknownForegroundActivityCount:
                    pendingShutdown.prompt.unknownForegroundActivityCount,
                sshSessionCount: pendingShutdown.prompt.sshSessionCount
            )
            self.pendingShutdown = PendingWorkspaceShutdown(
                prompt: prompt,
                completions: pendingShutdown.completions + [completion]
            )
            activeAlert = .shutdown(prompt)
            return
        }

        if let pendingShutdownEvaluation {
            let combinedScope: TerminalWorkspaceShutdownScope =
                pendingShutdownEvaluation.scope == .application || scope == .application
                ? .application
                : .window
            self.pendingShutdownEvaluation = PendingWorkspaceShutdownEvaluation(
                scope: combinedScope,
                completions: pendingShutdownEvaluation.completions + [completion]
            )
            return
        }

        pendingShutdownEvaluation = PendingWorkspaceShutdownEvaluation(
            scope: scope,
            completions: [completion]
        )
        evaluateWorkspaceShutdown()
    }

    func confirmWorkspaceShutdown(_ prompt: TerminalWorkspaceShutdownPrompt) {
        guard case .shutdown(prompt) = activeAlert,
              let pendingShutdown,
              pendingShutdown.prompt == prompt else { return }
        self.pendingShutdown = nil
        activeAlert = nil
        beginWorkspaceShutdown(completions: pendingShutdown.completions)
    }

    /// Last-resort cleanup for unexpected SwiftUI teardown. Normal window close and app quit
    /// call `requestWorkspaceShutdown` first and wait for cleanup to finish.
    func cleanupAllSessions() {
        guard !isShuttingDown else { return }
        let pendingCompletions = pendingShutdownEvaluation?.completions
            ?? pendingShutdown?.completions
            ?? []
        beginWorkspaceShutdown(completions: pendingCompletions)
    }

    private func configure(_ runtime: RuntimeSession, id: TerminalTab.ID) {
        let terminal = runtime.terminal
        terminal.onLifecycleEvent = { [weak self, weak runtime] event in
            guard let runtime else { return }
            self?.handleLifecycleEvent(event, for: id, expected: runtime)
        }
        terminal.onTitleChanged = { [weak self, weak runtime] title in
            guard let runtime else { return }
            self?.handleTitleChange(title, for: id, expected: runtime)
        }
        terminal.onLocalAction = { [weak self, weak runtime] action in
            guard let runtime else { return }
            self?.handleLocalAction(action, for: id, expected: runtime)
        }
        runtime.onCleanupFinished = { [weak self, weak runtime] in
            guard let runtime else { return }
            self?.finishRuntimeRemoval(id, expected: runtime)
        }
        runtime.onCleanupFailed = { [weak self, weak runtime] message in
            guard let self, let runtime, self.runtimes[id] === runtime else { return }
            self.handleCleanupFailure(message)
        }
    }

    private func handleLifecycleEvent(
        _ event: TerminalLifecycleEvent,
        for id: TerminalTab.ID,
        expected runtime: RuntimeSession
    ) {
        guard runtimes[id] === runtime,
              tabsState.tabs.contains(where: { $0.id == id }) else { return }
        do {
            tabsState = try tabsState.transitioningLifecycle(of: id, by: event)
        } catch {
            presentWorkspaceError("XMterm encountered an internal terminal state error.")
        }
    }

    private func handleTitleChange(
        _ title: String,
        for id: TerminalTab.ID,
        expected runtime: RuntimeSession
    ) {
        guard runtimes[id] === runtime,
              let tab = tabsState.tabs.first(where: { $0.id == id }),
              tab.kind == .local else { return }
        do {
            tabsState = try tabsState.updatingTitle(of: id, to: title)
        } catch {
            presentWorkspaceError("XMterm could not update the terminal tab title.")
        }
    }

    private func handleLocalAction(
        _ action: TerminalLocalAction,
        for id: TerminalTab.ID,
        expected runtime: RuntimeSession
    ) {
        guard runtimes[id] === runtime,
              tabsState.tabs.contains(where: { $0.id == id }) else { return }
        switch action {
        case .newTab:
            if let newTerminalRequest {
                newTerminalRequest()
            } else {
                createTerminal()
            }
        case .closeTab:
            requestClose(id)
        case .find:
            runtimes[id]?.terminal.showFind()
        case .copy, .paste, .selectAll, .unhandledCommand:
            break
        }
    }

    private func finishCloseDispositionEvaluation(
        _ disposition: TerminalCloseDisposition,
        for id: TerminalTab.ID,
        runtime: RuntimeSession
    ) {
        closeDispositionTasks = closeDispositionTasks.filter { $0.key != id }
        guard !isShuttingDown,
              pendingShutdown == nil,
              pendingShutdownEvaluation == nil,
              runtimes[id] === runtime,
              let tab = tabsState.tabs.first(where: { $0.id == id }) else { return }

        guard runtime.terminal.lifecycle == .running, disposition.requiresConfirmation else {
            closeImmediately(id)
            return
        }
        activeAlert = .close(
            TerminalClosePrompt(
                tabID: id,
                title: tab.title,
                disposition: disposition
            )
        )
    }

    private func evaluateWorkspaceShutdown() {
        guard shutdownEvaluationTask == nil else { return }
        let resolver = closeDispositionResolver
        shutdownEvaluationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let capturedRuntimes = self.tabsState.tabs.compactMap { tab in
                self.runtimes[tab.id].map { (tab.id, $0) }
            }
            var dispositions: [TerminalTab.ID: TerminalCloseDisposition] = [:]
            for (id, runtime) in capturedRuntimes {
                guard !Task.isCancelled else { return }
                let resolved = await resolver(runtime.terminal)
                let disposition = runtime.terminal.lifecycle == .running
                    ? resolved
                    : .closeImmediately
                dispositions = dispositions.merging([id: disposition]) {
                    _, replacement in replacement
                }
            }
            guard !Task.isCancelled else { return }
            self.finishWorkspaceShutdownEvaluation(
                dispositions,
                capturedRuntimes: capturedRuntimes
            )
        }
    }

    private func finishWorkspaceShutdownEvaluation(
        _ dispositions: [TerminalTab.ID: TerminalCloseDisposition],
        capturedRuntimes: [(TerminalTab.ID, RuntimeSession)]
    ) {
        shutdownEvaluationTask = nil
        guard !isShuttingDown, let evaluation = pendingShutdownEvaluation else { return }

        let currentRuntimesAreCaptured = capturedRuntimes.allSatisfy { id, runtime in
            runtimes[id] === runtime
        }
        let capturedIDs = Set(capturedRuntimes.map(\.0))
        let currentIDs = Set(tabsState.tabs.compactMap { runtimes[$0.id] == nil ? nil : $0.id })
        guard currentRuntimesAreCaptured, capturedIDs == currentIDs else {
            evaluateWorkspaceShutdown()
            return
        }

        let foregroundJobCount = dispositions.values.count(where: {
            $0 == .confirmForegroundJob
        })
        let unknownCount = dispositions.values.count(where: {
            $0 == .confirmUnknownForegroundActivity
        })
        let sshSessionCount = dispositions.values.count(where: {
            $0 == .confirmSSHSession
        })
        pendingShutdownEvaluation = nil

        guard foregroundJobCount + unknownCount + sshSessionCount > 0 else {
            beginWorkspaceShutdown(completions: evaluation.completions)
            return
        }

        let prompt = TerminalWorkspaceShutdownPrompt(
            scope: evaluation.scope,
            foregroundJobCount: foregroundJobCount,
            unknownForegroundActivityCount: unknownCount,
            sshSessionCount: sshSessionCount
        )
        pendingShutdown = PendingWorkspaceShutdown(
            prompt: prompt,
            completions: evaluation.completions
        )
        activeAlert = .shutdown(prompt)
    }

    private func closeImmediately(_ id: TerminalTab.ID) {
        closeDispositionTasks[id]?.cancel()
        closeDispositionTasks = closeDispositionTasks.filter { $0.key != id }
        guard let runtime = runtimes[id] else {
            tabsState = tabsState.closingTab(id: id)
            return
        }

        pendingRuntimeRemoval = pendingRuntimeRemoval.union([id])
        runtime.requestClose()
        tabsState = tabsState.closingTab(id: id)

        if let replacement = selectedSession {
            focus(replacement)
        }
    }

    private func finishRuntimeRemoval(
        _ id: TerminalTab.ID,
        expected runtime: RuntimeSession
    ) {
        guard pendingRuntimeRemoval.contains(id),
              runtimes[id] === runtime else { return }
        pendingRuntimeRemoval = pendingRuntimeRemoval.subtracting([id])
        runtimes = runtimes.filter { $0.key != id }
        finishWorkspaceShutdownIfPossible()
    }

    private func beginWorkspaceShutdown(completions: [@MainActor (Bool) -> Void]) {
        for task in closeDispositionTasks.values {
            task.cancel()
        }
        closeDispositionTasks = [:]
        shutdownEvaluationTask?.cancel()
        shutdownEvaluationTask = nil
        isShuttingDown = true
        activeAlert = nil
        pendingShutdown = nil
        pendingShutdownEvaluation = nil
        shutdownCompletions = shutdownCompletions + completions
        shutdownFailureMessage = nil

        let capturedRuntimes = runtimes
        pendingRuntimeRemoval = pendingRuntimeRemoval.union(capturedRuntimes.keys)
        let visibleTabIDs = tabsState.tabs.map(\.id)
        for id in visibleTabIDs {
            tabsState = tabsState.closingTab(id: id)
        }
        for runtime in capturedRuntimes.values {
            runtime.requestClose()
        }
        finishWorkspaceShutdownIfPossible()
    }

    private func finishWorkspaceShutdownIfPossible() {
        guard isShuttingDown, tabsState.tabs.isEmpty, runtimes.isEmpty else { return }
        let completions = shutdownCompletions
        shutdownCompletions = []
        if let shutdownFailureMessage {
            self.shutdownFailureMessage = nil
            isShuttingDown = false
            activeAlert = .error(id: UUID(), message: shutdownFailureMessage)
            for completion in completions {
                completion(false)
            }
        } else {
            for completion in completions {
                completion(true)
            }
        }
    }

    private func handleCleanupFailure(_ message: String) {
        if isShuttingDown {
            shutdownFailureMessage = message
        } else {
            presentWorkspaceError(message)
        }
    }

    private func focus(_ session: TerminalSession) {
        Task { @MainActor in
            await Task.yield()
            session.focus()
        }
    }

    private func presentWorkspaceError(_ message: String) {
        activeAlert = .error(id: UUID(), message: message)
    }
}
