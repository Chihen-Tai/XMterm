import Darwin
import Dispatch
import Foundation

struct SFTPProcessLaunch: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let currentDirectoryURL: URL?

    init(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
    }
}

struct SFTPProcessTimeouts: Equatable, Sendable {
    static let production = Self(request: .seconds(15), settlement: .seconds(2))

    let request: Duration
    let settlement: Duration
}

final class BoundedOpenSSHDiagnostic: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    private var storage: [UInt8] = []

    init(maximumByteCount: Int = 64 * 1_024) {
        self.maximumByteCount = maximumByteCount
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func append(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, maximumByteCount - storage.count)
        guard available > 0 else { return }
        storage.append(contentsOf: bytes.prefix(available))
    }

    func classifiedFailure() -> OpenSSHSFTPFailure? {
        lock.lock()
        let snapshot = storage
        lock.unlock()

        let diagnostic = String(decoding: snapshot, as: UTF8.self).lowercased()
        if diagnostic.contains("host key verification failed")
            || diagnostic.contains("remote host identification has changed") {
            return .hostKeyVerificationFailed
        }
        if diagnostic.contains("keyboard-interactive")
            || diagnostic.contains("verification code is required") {
            return .interactiveAuthenticationUnsupported
        }
        if diagnostic.contains("permission denied (publickey")
            || diagnostic.contains("permission denied (password")
            || diagnostic.contains("no supported authentication methods available") {
            return .authenticationRequired
        }
        return nil
    }
}

private final class BoundedSFTPProcessInput: @unchecked Sendable {
    private static let maximumWriteByteCount = 1_024 * 1_024

    private let fileDescriptor: Int32
    private let eventQueue: DispatchQueue
    private let lock = NSLock()
    private var pendingWrite: PendingSFTPProcessWrite?
    private var writeSource: DispatchSourceWrite?
    private var isClosed = false
    private var cancellationRequested = false

    init(fileDescriptor: Int32) throws {
        self.fileDescriptor = fileDescriptor
        eventQueue = DispatchQueue(label: "app.xmterm.sftp.stdin.\(fileDescriptor)")

        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        guard bytes.count <= Self.maximumWriteByteCount else {
            throw OpenSSHSFTPFailure.limitExceeded
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: SFTPProcessWriteAction?
                lock.lock()
                if cancellationRequested {
                    cancellationRequested = false
                    action = .failure(continuation, CancellationError(), nil)
                } else if isClosed {
                    action = .failure(
                        continuation,
                        OpenSSHSFTPFailure.transportUnavailable,
                        nil
                    )
                } else if pendingWrite != nil {
                    action = .failure(
                        continuation,
                        OpenSSHSFTPFailure.malformedResponse,
                        nil
                    )
                } else {
                    pendingWrite = PendingSFTPProcessWrite(
                        bytes: bytes,
                        offset: 0,
                        continuation: continuation
                    )
                    action = drainLocked()
                }
                lock.unlock()
                action?.perform()
            }
        } onCancel: {
            self.cancelPendingWrite()
        }
    }

    func close() {
        let action: SFTPProcessWriteAction?
        lock.lock()
        isClosed = true
        if let pendingWrite {
            self.pendingWrite = nil
            let source = writeSource
            writeSource = nil
            action = .failure(
                pendingWrite.continuation,
                OpenSSHSFTPFailure.transportUnavailable,
                source
            )
        } else {
            let source = writeSource
            writeSource = nil
            action = source.map(SFTPProcessWriteAction.cancelSource)
        }
        lock.unlock()
        action?.perform()
    }

    private func cancelPendingWrite() {
        let action: SFTPProcessWriteAction?
        lock.lock()
        if let pendingWrite {
            self.pendingWrite = nil
            let source = writeSource
            writeSource = nil
            action = .failure(pendingWrite.continuation, CancellationError(), source)
        } else {
            cancellationRequested = true
            action = nil
        }
        lock.unlock()
        action?.perform()
    }

    private func handleWritableEvent() {
        let action: SFTPProcessWriteAction?
        lock.lock()
        action = drainLocked()
        lock.unlock()
        action?.perform()
    }

    private func drainLocked() -> SFTPProcessWriteAction? {
        guard var pendingWrite else { return nil }

        while pendingWrite.offset < pendingWrite.bytes.count {
            let result = pendingWrite.bytes.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: pendingWrite.offset),
                    pendingWrite.bytes.count - pendingWrite.offset
                )
            }
            if result > 0 {
                pendingWrite.offset += result
                self.pendingWrite = pendingWrite
                continue
            }
            if result == -1, errno == EINTR {
                continue
            }
            if result == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                ensureWriteSourceLocked()
                return nil
            }

            self.pendingWrite = nil
            let source = writeSource
            writeSource = nil
            return .failure(
                pendingWrite.continuation,
                OpenSSHSFTPFailure.transportUnavailable,
                source
            )
        }

        self.pendingWrite = nil
        let source = writeSource
        writeSource = nil
        return .success(pendingWrite.continuation, source)
    }

    private func ensureWriteSourceLocked() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: fileDescriptor,
            queue: eventQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleWritableEvent()
        }
        writeSource = source
        source.resume()
    }
}

private struct PendingSFTPProcessWrite {
    let bytes: [UInt8]
    var offset: Int
    let continuation: CheckedContinuation<Void, any Error>
}

private enum SFTPProcessWriteAction {
    case success(CheckedContinuation<Void, any Error>, DispatchSourceWrite?)
    case failure(
        CheckedContinuation<Void, any Error>,
        any Error,
        DispatchSourceWrite?
    )
    case cancelSource(DispatchSourceWrite)

    func perform() {
        switch self {
        case .success(let continuation, let source):
            source?.cancel()
            continuation.resume()
        case .failure(let continuation, let error, let source):
            source?.cancel()
            continuation.resume(throwing: error)
        case .cancelSource(let source):
            source.cancel()
        }
    }
}

actor FoundationSFTPProcessChannel: SFTPProcessChannel {
    private let launch: SFTPProcessLaunch
    private let timeouts: SFTPProcessTimeouts
    private var resources: SFTPProcessResources?
    private var didSettle = false
    private var lateReapTask: Task<Void, Never>?

    init(
        launch: SFTPProcessLaunch,
        timeouts: SFTPProcessTimeouts = .production
    ) {
        self.launch = launch
        self.timeouts = timeouts
    }

    var isRunningForTesting: Bool {
        resources?.process.isRunning == true
    }

    var processIdentifierForTesting: Int32? {
        resources.map { $0.process.processIdentifier }
    }

    func start() async throws {
        guard resources == nil, !didSettle else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let standardError = Pipe()
        let outputBuffer = BoundedSFTPProcessOutput(maximumByteCount: 1_024 * 1_024)
        let diagnostic = BoundedOpenSSHDiagnostic()
        let exitSignal = SFTPProcessExitSignal()
        let inputWriter: BoundedSFTPProcessInput

        do {
            inputWriter = try BoundedSFTPProcessInput(
                fileDescriptor: input.fileHandleForWriting.fileDescriptor
            )
        } catch {
            Self.closeFileHandles(input: input, output: output, error: standardError)
            throw OpenSSHSFTPFailure.transportUnavailable
        }

        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.currentDirectoryURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = standardError

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outputBuffer.finish(SFTPProcessOutputError.endOfFile)
            } else {
                outputBuffer.append(data)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                diagnostic.append(Array(data))
            }
        }
        process.terminationHandler = { _ in
            outputBuffer.finish(SFTPProcessOutputError.endOfFile)
            exitSignal.finish()
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            Self.closeFileHandles(input: input, output: output, error: standardError)
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        resources = SFTPProcessResources(
            process: process,
            input: input,
            output: output,
            error: standardError,
            outputBuffer: outputBuffer,
            diagnostic: diagnostic,
            exitSignal: exitSignal,
            inputWriter: inputWriter
        )
    }

    func write(_ bytes: [UInt8]) async throws {
        guard let resources, resources.process.isRunning else {
            throw classifiedExitFailure()
        }
        do {
            try Task.checkCancellation()
            try await Self.writeWithTimeout(
                bytes,
                to: resources.inputWriter,
                duration: timeouts.request
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OpenSSHSFTPFailure {
            throw failure
        } catch {
            throw classifiedExitFailure()
        }
    }

    func readPacket(maximumByteCount: Int) async throws -> [UInt8] {
        guard let resources else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        do {
            return try await Self.readWithTimeout(
                output: resources.outputBuffer,
                maximumByteCount: maximumByteCount,
                duration: timeouts.request
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OpenSSHSFTPFailure {
            if failure == .transportUnavailable,
               let classified = resources.diagnostic.classifiedFailure() {
                throw classified
            }
            throw failure
        } catch {
            throw classifiedExitFailure()
        }
    }

    func invalidate() async {
        await settle()
    }

    func close() async {
        await settle()
    }

    private func settle() async {
        guard !didSettle else { return }
        didSettle = true
        guard let resources else { return }

        resources.inputWriter.close()
        resources.input.fileHandleForWriting.closeFile()
        var observedExit = !resources.process.isRunning
        if !observedExit {
            observedExit = await Self.waitForExit(
                resources.exitSignal,
                duration: .milliseconds(100)
            )
        }
        if !observedExit {
            Darwin.kill(resources.process.processIdentifier, SIGHUP)
        }
        if !observedExit {
            observedExit = await Self.waitForExit(
                resources.exitSignal,
                duration: .milliseconds(150)
            )
        }
        if !observedExit {
            Darwin.kill(resources.process.processIdentifier, SIGTERM)
        }
        if !observedExit {
            observedExit = await Self.waitForExit(
                resources.exitSignal,
                duration: .milliseconds(250)
            )
        }
        if !observedExit {
            Darwin.kill(resources.process.processIdentifier, SIGKILL)
        }
        if !observedExit {
            observedExit = await Self.waitForExit(
                resources.exitSignal,
                duration: timeouts.settlement
            )
        }

        resources.output.fileHandleForReading.readabilityHandler = nil
        resources.error.fileHandleForReading.readabilityHandler = nil
        resources.outputBuffer.finish(SFTPProcessOutputError.endOfFile)
        Self.closeFileHandles(
            input: resources.input,
            output: resources.output,
            error: resources.error
        )

        if !observedExit {
            let processIdentifier = resources.process.processIdentifier
            let process = resources.process
            let reapTask = Task.detached {
                process.waitUntilExit()
            }
            lateReapTask = reapTask
            Task { [weak self] in
                await reapTask.value
                await self?.completeLateReap(processIdentifier: processIdentifier)
            }
            return
        }

        await Task.detached { resources.process.waitUntilExit() }.value
        self.resources = nil
    }

    private func completeLateReap(processIdentifier: Int32) {
        guard resources?.process.processIdentifier == processIdentifier else { return }
        resources = nil
        lateReapTask = nil
    }

    private func classifiedExitFailure() -> OpenSSHSFTPFailure {
        resources?.diagnostic.classifiedFailure() ?? .transportUnavailable
    }

    private static func readWithTimeout(
        output: BoundedSFTPProcessOutput,
        maximumByteCount: Int,
        duration: Duration
    ) async throws -> [UInt8] {
        try await withThrowingTaskGroup(of: [UInt8].self) { group in
            group.addTask {
                try await output.readPacket(maximumByteCount: maximumByteCount)
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw OpenSSHSFTPFailure.timeout
            }
            guard let result = try await group.next() else {
                throw OpenSSHSFTPFailure.transportUnavailable
            }
            group.cancelAll()
            return result
        }
    }

    private static func writeWithTimeout(
        _ bytes: [UInt8],
        to input: BoundedSFTPProcessInput,
        duration: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await input.write(bytes)
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw OpenSSHSFTPFailure.timeout
            }
            guard try await group.next() != nil else {
                throw OpenSSHSFTPFailure.transportUnavailable
            }
            group.cancelAll()
        }
    }

    private static func waitForExit(
        _ signal: SFTPProcessExitSignal,
        duration: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await signal.wait()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private static func closeFileHandles(input: Pipe, output: Pipe, error: Pipe) {
        input.fileHandleForReading.closeFile()
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        error.fileHandleForReading.closeFile()
        error.fileHandleForWriting.closeFile()
    }
}

struct OpenSSHSubsystemProcessFactory: SFTPProcessChannelFactory {
    let target: OpenSSHSFTPTarget
    let timeouts: SFTPProcessTimeouts

    init(
        target: OpenSSHSFTPTarget,
        timeouts: SFTPProcessTimeouts = .production
    ) {
        self.target = target
        self.timeouts = timeouts
    }

    func makeChannel() -> any SFTPProcessChannel {
        FoundationSFTPProcessChannel(
            launch: SFTPProcessLaunch(
                executablePath: target.executablePath,
                arguments: target.arguments
            ),
            timeouts: timeouts
        )
    }
}

private final class SFTPProcessResources: @unchecked Sendable {
    let process: Process
    let input: Pipe
    let output: Pipe
    let error: Pipe
    let outputBuffer: BoundedSFTPProcessOutput
    let diagnostic: BoundedOpenSSHDiagnostic
    let exitSignal: SFTPProcessExitSignal
    let inputWriter: BoundedSFTPProcessInput

    init(
        process: Process,
        input: Pipe,
        output: Pipe,
        error: Pipe,
        outputBuffer: BoundedSFTPProcessOutput,
        diagnostic: BoundedOpenSSHDiagnostic,
        exitSignal: SFTPProcessExitSignal,
        inputWriter: BoundedSFTPProcessInput
    ) {
        self.process = process
        self.input = input
        self.output = output
        self.error = error
        self.outputBuffer = outputBuffer
        self.diagnostic = diagnostic
        self.exitSignal = exitSignal
        self.inputWriter = inputWriter
    }
}

private enum SFTPProcessOutputError: Error {
    case endOfFile
}

private final class BoundedSFTPProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    private var storage: [UInt8] = []
    private var pendingRead: CheckedContinuation<[UInt8], any Error>?
    private var pendingMaximumByteCount: Int?
    private var terminalError: (any Error)?
    private var cancellationRequested = false

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func append(_ data: Data) {
        let action: ReadAction?
        lock.lock()
        if terminalError == nil {
            let available = maximumByteCount - storage.count
            if data.count > available {
                terminalError = OpenSSHSFTPFailure.limitExceeded
            } else {
                storage.append(contentsOf: data)
            }
        }
        action = nextReadActionLocked()
        lock.unlock()
        action?.resume()
    }

    func finish(_ error: any Error) {
        let action: ReadAction?
        lock.lock()
        if terminalError == nil {
            terminalError = error
        }
        action = nextReadActionLocked()
        lock.unlock()
        action?.resume()
    }

    func readPacket(maximumByteCount: Int) async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: ReadAction?
                lock.lock()
                if cancellationRequested {
                    cancellationRequested = false
                    action = .failure(continuation, CancellationError())
                } else if pendingRead != nil {
                    action = .failure(continuation, OpenSSHSFTPFailure.malformedResponse)
                } else {
                    pendingRead = continuation
                    pendingMaximumByteCount = maximumByteCount
                    action = nextReadActionLocked()
                }
                lock.unlock()
                action?.resume()
            }
        } onCancel: {
            self.cancelPendingRead()
        }
    }

    private func cancelPendingRead() {
        let action: ReadAction?
        lock.lock()
        if let pendingRead {
            self.pendingRead = nil
            pendingMaximumByteCount = nil
            action = .failure(pendingRead, CancellationError())
        } else {
            cancellationRequested = true
            action = nil
        }
        lock.unlock()
        action?.resume()
    }

    private func nextReadActionLocked() -> ReadAction? {
        guard let pendingRead else { return nil }
        if storage.count >= 4 {
            let length = storage.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 1, let payloadCount = Int(exactly: length) else {
                self.pendingRead = nil
                pendingMaximumByteCount = nil
                return .failure(pendingRead, OpenSSHSFTPFailure.malformedResponse)
            }
            let packetCount = payloadCount + 4
            let effectiveMaximum = min(
                pendingMaximumByteCount ?? maximumByteCount,
                maximumByteCount
            )
            guard packetCount <= effectiveMaximum else {
                self.pendingRead = nil
                pendingMaximumByteCount = nil
                return .failure(pendingRead, OpenSSHSFTPFailure.limitExceeded)
            }
            if storage.count >= packetCount {
                let packet = Array(storage.prefix(packetCount))
                storage.removeFirst(packetCount)
                self.pendingRead = nil
                pendingMaximumByteCount = nil
                return .success(pendingRead, packet)
            }
        }
        if let terminalError {
            self.pendingRead = nil
            pendingMaximumByteCount = nil
            return .failure(pendingRead, terminalError)
        }
        return nil
    }
}

private enum ReadAction {
    case success(CheckedContinuation<[UInt8], any Error>, [UInt8])
    case failure(CheckedContinuation<[UInt8], any Error>, any Error)

    func resume() {
        switch self {
        case .success(let continuation, let bytes):
            continuation.resume(returning: bytes)
        case .failure(let continuation, let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class SFTPProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancellationRequested: Set<UUID> = []

    func finish() {
        let continuations: [CheckedContinuation<Void, any Error>]
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        continuations = Array(waiters.values)
        waiters.removeAll()
        cancellationRequested.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func wait() async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: SFTPProcessExitWaitAction?
                lock.lock()
                if didFinish {
                    action = .success(continuation)
                } else if cancellationRequested.remove(identifier) != nil {
                    action = .failure(continuation, CancellationError())
                } else {
                    waiters[identifier] = continuation
                    action = nil
                }
                lock.unlock()
                action?.resume()
            }
        } onCancel: {
            self.cancelWait(identifier: identifier)
        }
    }

    private func cancelWait(identifier: UUID) {
        let continuation: CheckedContinuation<Void, any Error>?
        lock.lock()
        continuation = waiters.removeValue(forKey: identifier)
        if continuation == nil, !didFinish {
            cancellationRequested.insert(identifier)
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

private enum SFTPProcessExitWaitAction {
    case success(CheckedContinuation<Void, any Error>)
    case failure(CheckedContinuation<Void, any Error>, any Error)

    func resume() {
        switch self {
        case .success(let continuation):
            continuation.resume()
        case .failure(let continuation, let error):
            continuation.resume(throwing: error)
        }
    }
}
