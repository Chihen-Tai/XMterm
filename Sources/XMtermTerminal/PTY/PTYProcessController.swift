import CXMtermPTY
import Darwin
import Dispatch
import Foundation
import XMtermCore

/// Determines whether a close preserves unread PTY output or may discard it for prompt teardown.
package enum PTYCloseOutputPolicy: Equatable, Sendable {
    /// Keeps bounded backpressure and requires the existing output consumer to read through EOF.
    case drain
    /// Allows unread kernel-buffered bytes to be discarded after the close grace period.
    case discard
}

/// Point-in-time ownership of the PTY foreground process group.
package enum PTYForegroundProcessGroupState: Equatable, Sendable {
    /// The launched shell's process group owns the foreground terminal.
    case shell
    /// A different process group owns the foreground terminal.
    case foregroundJob
    /// The child or PTY is already closed, exited, or being torn down.
    case terminalUnavailable
    /// The PTY is otherwise live, but the kernel query failed unexpectedly.
    case queryFailed(errorNumber: Int32)
}

/// Serial owner of one PTY master descriptor and its child-process lifecycle.
package actor PTYProcessController: TerminalProcess {
    /// Stable identifier of the direct child created by `forkpty`.
    package nonisolated let processIdentifier: pid_t
    /// Stable PID of the launched local shell.
    package nonisolated let shellProcessIdentifier: pid_t
    /// Stable process-group ID assigned to the shell by `forkpty`.
    package nonisolated let shellProcessGroupIdentifier: pid_t

    private static let maximumBufferedOutputBytes = 64 * 1024
    private static let maximumPendingWriteBytes = TerminalConfiguration.pasteByteLimit

    private let eventQueue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private let processSource: DispatchSourceProcess

    private var masterFileDescriptor: Int32?
    private var sourcesStarted = false
    private var ioSourcesCancelled = false
    private var processSourceCancelled = false
    private var readSourceIsResumed = false
    private var writeSourceIsResumed = false

    private var bufferedOutput: [UInt8] = []
    private var outputReachedEOF = false
    private var readFailure: PTYControllerError?
    private var activeReadIdentifier: UUID?
    private var pendingRead: PendingRead?
    private var pendingWrites: [PendingWrite] = []
    private var pendingWriteByteCount = 0

    private var closeStarted = false
    private var closeSignalsFinished = false
    private var closeEscalationFinished = false
    private var observedForegroundProcessGroupIdentifiers: Set<pid_t> = []
    private var observedUnknownForegroundProcessGroup = false
    private var closeFailure: PTYControllerError?
    private var childCleanupTimedOut = false
    private var childWasReaped = false
    private var childStatus: TerminalExitStatus?
    private var completionStatus: TerminalExitStatus?
    private var completionFailure: PTYControllerError?
    private var completionWaiters: [UUID: CheckedContinuation<TerminalExitStatus, Error>] = [:]

    /// Validates and launches one process without blocking the caller's actor on `forkpty`/`execve`.
    package static func launch(_ configuration: PTYLaunchConfiguration) async throws -> PTYProcessController {
        let handles = try await Task.detached(priority: .userInitiated) {
            try spawnPTY(for: configuration)
        }.value
        let controller = PTYProcessController(handles: handles)
        await controller.startMonitoring()
        return controller
    }

    private init(handles: PTYSpawnHandles) {
        processIdentifier = handles.childProcessIdentifier
        shellProcessIdentifier = handles.childProcessIdentifier
        shellProcessGroupIdentifier = handles.childProcessGroupIdentifier
        masterFileDescriptor = handles.masterFileDescriptor
        eventQueue = DispatchQueue(label: "app.xmterm.pty.events.\(handles.childProcessIdentifier)")
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: handles.masterFileDescriptor,
            queue: eventQueue
        )
        writeSource = DispatchSource.makeWriteSource(
            fileDescriptor: handles.masterFileDescriptor,
            queue: eventQueue
        )
        processSource = DispatchSource.makeProcessSource(
            identifier: handles.childProcessIdentifier,
            eventMask: .exit,
            queue: eventQueue
        )
    }

    deinit {
        if !ioSourcesCancelled {
            if !readSourceIsResumed {
                readSource.resume()
            }
            readSource.cancel()
            if !writeSourceIsResumed {
                writeSource.resume()
            }
            writeSource.cancel()
        }
        if !processSourceCancelled {
            processSource.cancel()
        }
        if let masterFileDescriptor {
            Darwin.close(masterFileDescriptor)
        }

        guard !childWasReaped else { return }
        let childProcessIdentifier = processIdentifier
        DispatchQueue.global(qos: .utility).async {
            _ = xmterm_pty_signal_process_group(childProcessIdentifier, SIGKILL)
            var rawStatus: Int32 = 0
            while Darwin.waitpid(childProcessIdentifier, &rawStatus, 0) == -1 && errno == EINTR {
            }
        }
    }

    /// Returns the next output chunk, or `nil` after final PTY EOF. Only one consumer may wait at once.
    package func read(upToCount maximumByteCount: Int) async throws -> [UInt8]? {
        guard maximumByteCount > 0 else {
            throw PTYControllerError.invalidReadByteCount(maximumByteCount)
        }
        guard activeReadIdentifier == nil else {
            throw PTYControllerError.readAlreadyInProgress
        }

        if !bufferedOutput.isEmpty {
            let output = takeBufferedOutput(upToCount: maximumByteCount)
            resumeReadEventsIfNeeded()
            handleReadableEvent()
            return output
        }
        if let readFailure {
            throw readFailure
        }
        if outputReachedEOF {
            return nil
        }

        let identifier = UUID()
        activeReadIdentifier = identifier
        resumeReadEventsIfNeeded()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    activeReadIdentifier = nil
                    continuation.resume(throwing: CancellationError())
                } else if !bufferedOutput.isEmpty {
                    activeReadIdentifier = nil
                    continuation.resume(returning: takeBufferedOutput(upToCount: maximumByteCount))
                } else if let readFailure {
                    activeReadIdentifier = nil
                    continuation.resume(throwing: readFailure)
                } else if outputReachedEOF {
                    activeReadIdentifier = nil
                    continuation.resume(returning: nil)
                } else {
                    pendingRead = PendingRead(
                        identifier: identifier,
                        maximumByteCount: maximumByteCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRead(identifier: identifier) }
        }
    }

    /// Writes bytes in invocation order using a bounded, nonblocking queue.
    package func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        guard !closeStarted,
              childStatus == nil,
              masterFileDescriptor != nil,
              !outputReachedEOF else {
            throw PTYControllerError.closed
        }
        guard bytes.count <= Self.maximumPendingWriteBytes - pendingWriteByteCount else {
            throw PTYControllerError.pendingWriteLimitExceeded(
                limit: Self.maximumPendingWriteBytes
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            pendingWriteByteCount += bytes.count
            pendingWrites.append(
                PendingWrite(bytes: bytes, offset: 0, continuation: continuation)
            )
            drainWrites()
        }
    }

    /// Updates the PTY kernel window size and triggers normal terminal resize semantics.
    package func resize(to size: TerminalGridSize) async throws {
        try PTYLaunchConfiguration.validate(size: size)
        guard !closeStarted,
              childStatus == nil,
              let masterFileDescriptor,
              !outputReachedEOF else {
            throw PTYControllerError.closed
        }

        guard xmterm_pty_set_window_size(masterFileDescriptor, size.columns, size.rows) == 0 else {
            throw PTYControllerError.resizeFailed(errno: errno)
        }
    }

    /// Reconciles a child that exited before its owner could publish a running state.
    /// Final PTY bytes may still remain and are drained through `read(upToCount:)`.
    package func childExitStatusIfAvailable() async -> TerminalExitStatus? {
        reapChildIfExited()
        return childStatus
    }

    /// Waits until both the direct child is reaped and final PTY output has reached EOF.
    package func waitForExit() async throws -> TerminalExitStatus {
        try await awaitCompletion()
    }

    /// Queries foreground ownership from the PTY itself. Shell liveness and terminal
    /// output are intentionally not used as activity signals.
    package func foregroundProcessGroupState() async -> PTYForegroundProcessGroupState {
        reapChildIfExited()
        guard !closeStarted,
              !childWasReaped,
              completionStatus == nil,
              completionFailure == nil,
              !outputReachedEOF,
              let masterFileDescriptor else {
            return .terminalUnavailable
        }

        var processGroupIdentifier: pid_t = -1
        repeat {
            errno = 0
            processGroupIdentifier = xmterm_pty_foreground_process_group(masterFileDescriptor)
        } while processGroupIdentifier == -1 && errno == EINTR
        let queryErrno = errno

        if processGroupIdentifier == -1 {
            // The process may have exited between the pre-query state check and
            // tcgetpgrp(3). Reconcile that expected race before reporting failure.
            reapChildIfExited()
            if childWasReaped || outputReachedEOF || self.masterFileDescriptor == nil {
                return .terminalUnavailable
            }
        }

        return Self.classifyForegroundProcessGroup(
            queryResult: processGroupIdentifier,
            shellProcessGroupIdentifier: shellProcessGroupIdentifier,
            errorNumber: queryErrno
        )
    }

    package nonisolated static func classifyForegroundProcessGroup(
        queryResult: pid_t,
        shellProcessGroupIdentifier: pid_t,
        errorNumber: Int32
    ) -> PTYForegroundProcessGroupState {
        guard queryResult > 0 else {
            return .queryFailed(errorNumber: errorNumber == 0 ? EIO : errorNumber)
        }
        return queryResult == shellProcessGroupIdentifier ? .shell : .foregroundJob
    }

    /// Terminates this PTY session, reaps its child, and returns the cached terminal status.
    @discardableResult
    package func close(
        outputPolicy: PTYCloseOutputPolicy = .discard
    ) async throws -> TerminalExitStatus {
        if !closeStarted, completionStatus == nil, completionFailure == nil {
            beginCloseSequence(outputPolicy: outputPolicy)
        }
        return try await awaitCompletion()
    }

    private func startMonitoring() {
        guard !sourcesStarted else { return }

        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleReadableEvent() }
        }
        writeSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleWritableEvent() }
        }
        processSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleProcessExitEvent() }
        }

        sourcesStarted = true
        readSource.resume()
        readSourceIsResumed = true
        processSource.resume()

        handleReadableEvent()
        reapChildIfExited()
    }

    private func handleReadableEvent() {
        guard let masterFileDescriptor, !outputReachedEOF, readFailure == nil else { return }

        var bytesReadThisPass = 0
        while bytesReadThisPass < Self.maximumBufferedOutputBytes {
            let capacity = nextReadCapacity()
            guard capacity > 0 else {
                pauseReadEventsIfNeeded()
                return
            }

            var bytes = [UInt8](repeating: 0, count: capacity)
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(masterFileDescriptor, buffer.baseAddress, capacity)
            }

            if result > 0 {
                acceptReadBytes(Array(bytes.prefix(result)))
                bytesReadThisPass += result
                continue
            }
            if result == 0 {
                markOutputEOF()
                return
            }

            let readErrno = errno
            if readErrno == EINTR {
                continue
            }
            if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                return
            }
            if readErrno == EIO {
                markOutputEOF()
                return
            }

            markReadFailure(PTYControllerError.readFailed(errno: readErrno))
            return
        }
    }

    private func nextReadCapacity() -> Int {
        if let pendingRead {
            return min(16 * 1024, pendingRead.maximumByteCount)
        }
        let remainingCapacity = Self.maximumBufferedOutputBytes - bufferedOutput.count
        if remainingCapacity > 0 {
            return min(16 * 1024, remainingCapacity)
        }
        return 0
    }

    private func acceptReadBytes(_ bytes: [UInt8]) {
        if let pendingRead {
            self.pendingRead = nil
            activeReadIdentifier = nil
            pendingRead.continuation.resume(returning: bytes)
        } else {
            bufferedOutput.append(contentsOf: bytes)
        }
    }

    private func takeBufferedOutput(upToCount maximumByteCount: Int) -> [UInt8] {
        let count = min(maximumByteCount, bufferedOutput.count)
        let output = Array(bufferedOutput.prefix(count))
        bufferedOutput.removeFirst(count)
        return output
    }

    private func cancelRead(identifier: UUID) {
        guard activeReadIdentifier == identifier else { return }
        activeReadIdentifier = nil
        guard let pendingRead, pendingRead.identifier == identifier else { return }
        self.pendingRead = nil
        pendingRead.continuation.resume(throwing: CancellationError())
    }

    private func markOutputEOF() {
        guard !outputReachedEOF else { return }
        outputReachedEOF = true
        if let pendingRead {
            self.pendingRead = nil
            activeReadIdentifier = nil
            pendingRead.continuation.resume(returning: nil)
        }
        closeMasterFileDescriptor()
        reapChildIfExited()
        resolveCompletionIfPossible()
    }

    private func markReadFailure(_ error: PTYControllerError) {
        guard readFailure == nil else { return }
        readFailure = error
        if !closeStarted {
            beginCloseSequence(outputPolicy: .discard)
        }
        if let pendingRead {
            self.pendingRead = nil
            activeReadIdentifier = nil
            pendingRead.continuation.resume(throwing: error)
        }
        outputReachedEOF = true
        closeMasterFileDescriptor()
        reapChildIfExited()
        resolveCompletionIfPossible()
    }

    private func handleWritableEvent() {
        drainWrites()
    }

    private func drainWrites() {
        guard let masterFileDescriptor else {
            failAllWrites(with: PTYControllerError.closed)
            return
        }

        while let request = pendingWrites.first {
            let remainingCount = request.bytes.count - request.offset
            let result = request.bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    masterFileDescriptor,
                    buffer.baseAddress?.advanced(by: request.offset),
                    remainingCount
                )
            }

            if result > 0 {
                let nextOffset = request.offset + result
                pendingWriteByteCount -= result
                if nextOffset == request.bytes.count {
                    pendingWrites.removeFirst()
                    request.continuation.resume()
                } else {
                    pendingWrites[0] = PendingWrite(
                        bytes: request.bytes,
                        offset: nextOffset,
                        continuation: request.continuation
                    )
                }
                continue
            }

            let writeErrno = result == 0 ? EIO : errno
            if result == -1, writeErrno == EINTR {
                continue
            }
            if result == -1, writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
                resumeWriteEventsIfNeeded()
                return
            }

            failAllWrites(with: PTYControllerError.writeFailed(errno: writeErrno))
            return
        }

        pauseWriteEventsIfNeeded()
    }

    private func failAllWrites(with error: Error) {
        let writes = pendingWrites
        pendingWrites = []
        pendingWriteByteCount = 0
        pauseWriteEventsIfNeeded()
        for write in writes {
            write.continuation.resume(throwing: error)
        }
    }

    private func handleProcessExitEvent() {
        reapChildIfExited()
    }

    private func reapChildIfExited() {
        guard !childWasReaped else { return }
        // Keep the direct child's PID/process-group identity allocated until the
        // last close signal has been sent. This prevents delayed escalation from
        // targeting a recycled shell process-group number.
        if closeStarted, !closeSignalsFinished {
            // Process-source delivery is also the final-read wakeup. Drain any
            // remaining PTY bytes even though waitpid is intentionally deferred.
            handleReadableEvent()
            return
        }

        var rawStatus: Int32 = 0
        let result = Darwin.waitpid(processIdentifier, &rawStatus, WNOHANG)
        if result == 0 {
            return
        }
        if result == processIdentifier {
            childWasReaped = true
            cancelProcessSourceIfNeeded()
            do {
                childStatus = try TerminalExitStatus(decodingDarwinWaitStatus: rawStatus)
            } catch {
                completionFailure = PTYControllerError.waitFailed(errno: EINVAL)
            }
            handleReadableEvent()
            resolveCompletionIfPossible()
            return
        }

        let waitErrno = errno
        if waitErrno == EINTR {
            reapChildIfExited()
        } else {
            childWasReaped = waitErrno == ECHILD
            if completionFailure == nil {
                completionFailure = PTYControllerError.waitFailed(errno: waitErrno)
            }
            if childWasReaped {
                cancelProcessSourceIfNeeded()
            }
            resolveCompletionIfPossible()
        }
    }

    private func awaitCompletion() async throws -> TerminalExitStatus {
        if let completionStatus {
            return completionStatus
        }
        if let completionFailure {
            throw completionFailure
        }

        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let completionStatus {
                    continuation.resume(returning: completionStatus)
                } else if let completionFailure {
                    continuation.resume(throwing: completionFailure)
                } else {
                    completionWaiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCompletionWaiter(identifier: identifier) }
        }
    }

    private func cancelCompletionWaiter(identifier: UUID) {
        completionWaiters.removeValue(forKey: identifier)?.resume(throwing: CancellationError())
    }

    private func resolveCompletionIfPossible() {
        guard !closeStarted || closeEscalationFinished else { return }

        if childCleanupTimedOut, let closeFailure {
            // A still-live direct child is the terminal cleanup outcome even if
            // an earlier wait or signal error was recorded on the way there.
            completionFailure = closeFailure
        } else if completionFailure == nil,
                  Self.canSurfaceCloseFailure(
                      childWasReaped: childWasReaped,
                      childCleanupTimedOut: childCleanupTimedOut
                  ),
                  let closeFailure {
            completionFailure = closeFailure
        }

        if let completionFailure {
            let waiters = completionWaiters.values
            completionWaiters = [:]
            for waiter in waiters {
                waiter.resume(throwing: completionFailure)
            }
            return
        }
        guard outputReachedEOF, let childStatus else { return }

        completionStatus = childStatus
        let waiters = completionWaiters.values
        completionWaiters = [:]
        for waiter in waiters {
            waiter.resume(returning: childStatus)
        }
    }

    private func beginCloseSequence(outputPolicy: PTYCloseOutputPolicy) {
        guard !closeStarted else { return }
        closeStarted = true
        failAllWrites(with: PTYControllerError.closed)
        signalTerminalProcessGroups(SIGHUP)
        resumeReadEventsIfNeeded()
        handleReadableEvent()
        startCloseEscalation(outputPolicy: outputPolicy)
    }

    private func startCloseEscalation(outputPolicy: PTYCloseOutputPolicy) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(150))
            await self.signalTerminalProcessGroups(SIGTERM)
            try? await Task.sleep(for: .milliseconds(250))
            if outputPolicy == .drain {
                await self.waitForDrainCompletionGrace()
            }
            await self.signalTerminalProcessGroups(SIGKILL)
            let processGroups = await self.foregroundProcessGroupsForVerification()
            await self.finishCloseSignals(outputPolicy: outputPolicy)
            if outputPolicy == .drain {
                // A child-exit notification can precede the PTY line discipline's
                // final readable event. Keep the master open for one bounded final
                // drain window; treating a transient EAGAIN as EOF loses tail bytes.
                await self.waitForDrainCompletionGrace()
                await self.forceCloseMasterAfterDrainGrace()
                await self.reapChildIfExited()
            }
            let survivors = await Self.waitForProcessGroupsToExit(processGroups)
            if !survivors.isEmpty {
                await self.recordCloseFailure(.foregroundProcessGroupStillRunning)
            }
            await self.recordUnknownForegroundVerificationFailureIfNeeded()
            if !(await self.waitForDirectChildReap()) {
                await self.handleDirectChildReapTimeout()
            }
            await self.finishCloseEscalation()
        }
    }

    private func forceCloseMasterAfterDrainGrace() {
        guard !outputReachedEOF else { return }
        handleReadableEvent()
        guard !outputReachedEOF else { return }
        markOutputEOF()
    }

    private func signalTerminalProcessGroups(_ signalNumber: Int32) {
        if let masterFileDescriptor {
            let foregroundProcessGroup = refreshForegroundProcessGroup(
                using: masterFileDescriptor
            )
            // TIOCSIG is required for race-free delivery to a foreground group
            // that can change between tcgetpgrp and signal delivery. Darwin's
            // TIOCSIG(SIGHUP) can discard a final PTY tail when the shell itself
            // is foreground, so only that initial graceful signal uses the pinned
            // shell group below. TERM and final KILL always use TIOCSIG.
            let shouldSignalForeground = signalNumber != SIGHUP
                || (foregroundProcessGroup != nil
                    && foregroundProcessGroup != shellProcessGroupIdentifier)
            if shouldSignalForeground {
                if xmterm_pty_signal_foreground_process_group(
                    masterFileDescriptor,
                    signalNumber
                ) == -1 {
                    handleForegroundSignalFailure(
                        errorNumber: errno,
                        signalNumber: signalNumber
                    )
                }
            }
        } else if observedForegroundActivityMayStillBeRunning {
            recordCloseFailure(.foregroundProcessCleanupUnverifiable)
        }

        guard !childWasReaped else { return }
        if xmterm_pty_signal_process_group(shellProcessGroupIdentifier, signalNumber) == -1 {
            let groupError = errno
            guard groupError != ESRCH else { return }
            if Darwin.kill(shellProcessIdentifier, signalNumber) == -1,
               let failure = Self.closeSignalFailure(
                   errorNumber: errno,
                   signalNumber: signalNumber
               ) {
                recordCloseFailure(failure)
            }
        }
    }

    private func refreshForegroundProcessGroup(
        using masterFileDescriptor: Int32
    ) -> pid_t? {
        var processGroupIdentifier: pid_t = -1
        repeat {
            errno = 0
            processGroupIdentifier = xmterm_pty_foreground_process_group(masterFileDescriptor)
        } while processGroupIdentifier == -1 && errno == EINTR
        if processGroupIdentifier > 0 {
            if processGroupIdentifier != shellProcessGroupIdentifier {
                observedForegroundProcessGroupIdentifiers.insert(processGroupIdentifier)
            }
            return processGroupIdentifier
        }
        observedUnknownForegroundProcessGroup = true
        return nil
    }

    private func handleForegroundSignalFailure(
        errorNumber: Int32,
        signalNumber: Int32
    ) {
        if [EIO, ENXIO, ENOTTY, ESRCH].contains(errorNumber) {
            if observedForegroundActivityMayStillBeRunning {
                recordCloseFailure(.foregroundProcessCleanupUnverifiable)
            }
            return
        }
        if let failure = Self.closeSignalFailure(
            errorNumber: errorNumber,
            signalNumber: signalNumber
        ) {
            recordCloseFailure(failure)
        }
    }

    private var observedForegroundActivityMayStillBeRunning: Bool {
        observedUnknownForegroundProcessGroup
            || observedForegroundProcessGroupIdentifiers.contains(where: Self.processGroupExists)
    }

    private func foregroundProcessGroupsForVerification() -> [pid_t] {
        observedForegroundProcessGroupIdentifiers.sorted()
    }

    private func recordUnknownForegroundVerificationFailureIfNeeded() {
        if observedUnknownForegroundProcessGroup {
            recordCloseFailure(.foregroundProcessCleanupUnverifiable)
        }
    }

    private func finishCloseSignals(outputPolicy: PTYCloseOutputPolicy) {
        closeSignalsFinished = true
        if outputPolicy == .discard {
            forceCloseMasterAfterDrainGrace()
        }
        reapChildIfExited()
    }

    private func waitForDrainCompletionGrace() async {
        for _ in 0 ..< 50 {
            handleReadableEvent()
            guard !outputReachedEOF, readFailure == nil else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func recordCloseFailure(_ failure: PTYControllerError) {
        closeFailure = Self.prioritizedCloseFailure(current: closeFailure, new: failure)
    }

    package nonisolated static func canSurfaceCloseFailure(
        childWasReaped: Bool,
        childCleanupTimedOut: Bool
    ) -> Bool {
        childWasReaped || childCleanupTimedOut
    }

    package nonisolated static func prioritizedCloseFailure(
        current: PTYControllerError?,
        new: PTYControllerError
    ) -> PTYControllerError {
        if new == .childProcessStillRunning {
            return new
        }
        if current == .childProcessStillRunning {
            return .childProcessStillRunning
        }
        return current ?? new
    }

    package nonisolated static func closeSignalFailure(
        errorNumber: Int32,
        signalNumber: Int32
    ) -> PTYControllerError? {
        guard errorNumber != ESRCH else { return nil }
        return .processGroupSignalFailed(signal: signalNumber, errno: errorNumber)
    }

    private nonisolated static func waitForProcessGroupsToExit(
        _ processGroupIdentifiers: [pid_t]
    ) async -> [pid_t] {
        for _ in 0 ..< 50 {
            let survivors = processGroupIdentifiers.filter(processGroupExists)
            guard !survivors.isEmpty else { return [] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return processGroupIdentifiers.filter(processGroupExists)
    }

    private nonisolated static func processGroupExists(_ processGroupIdentifier: pid_t) -> Bool {
        guard Darwin.kill(-processGroupIdentifier, 0) == -1 else { return true }
        return errno == EPERM
    }

    private func waitForDirectChildReap() async -> Bool {
        for _ in 0 ..< 50 {
            reapChildIfExited()
            if childWasReaped {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        reapChildIfExited()
        return childWasReaped
    }

    private func handleDirectChildReapTimeout() {
        reapChildIfExited()
        guard !childWasReaped else { return }
        childCleanupTimedOut = true
        recordCloseFailure(.childProcessStillRunning)
        retainControllerUntilDirectChildExits()
    }

    private func retainControllerUntilDirectChildExits() {
        guard !processSourceCancelled, !childWasReaped else { return }
        // The actor owns the source and this handler intentionally retains the
        // actor after a surfaced timeout. Child exit is event-driven; successful
        // reaping clears the handler in cancelProcessSourceIfNeeded and breaks the
        // temporary cycle without a polling task.
        processSource.setEventHandler { [self] in
            Task.detached { await self.handleProcessExitEvent() }
        }
    }

    private func finishCloseEscalation() {
        closeEscalationFinished = true
        reapChildIfExited()
        handleReadableEvent()
        if closeFailure != nil, !outputReachedEOF {
            markOutputEOF()
        }
        resolveCompletionIfPossible()
    }

    private func resumeReadEventsIfNeeded() {
        guard !ioSourcesCancelled, !readSourceIsResumed else { return }
        readSource.resume()
        readSourceIsResumed = true
    }

    private func pauseReadEventsIfNeeded() {
        guard !ioSourcesCancelled, readSourceIsResumed else { return }
        readSource.suspend()
        readSourceIsResumed = false
    }

    private func resumeWriteEventsIfNeeded() {
        guard !ioSourcesCancelled, !writeSourceIsResumed else { return }
        writeSource.resume()
        writeSourceIsResumed = true
    }

    private func pauseWriteEventsIfNeeded() {
        guard !ioSourcesCancelled, writeSourceIsResumed else { return }
        writeSource.suspend()
        writeSourceIsResumed = false
    }

    private func closeMasterFileDescriptor() {
        guard let masterFileDescriptor else { return }
        self.masterFileDescriptor = nil
        cancelIOSourcesIfNeeded()
        failAllWrites(with: PTYControllerError.closed)
        _ = Darwin.close(masterFileDescriptor)
    }

    private func cancelIOSourcesIfNeeded() {
        guard !ioSourcesCancelled else { return }
        ioSourcesCancelled = true
        if !readSourceIsResumed {
            readSource.resume()
            readSourceIsResumed = true
        }
        readSource.cancel()
        if !writeSourceIsResumed {
            writeSource.resume()
            writeSourceIsResumed = true
        }
        writeSource.cancel()
    }

    private func cancelProcessSourceIfNeeded() {
        guard !processSourceCancelled else { return }
        processSourceCancelled = true
        processSource.setEventHandler {}
        processSource.cancel()
    }
}

private struct PendingRead {
    let identifier: UUID
    let maximumByteCount: Int
    let continuation: CheckedContinuation<[UInt8]?, Error>
}

private struct PendingWrite {
    let bytes: [UInt8]
    let offset: Int
    let continuation: CheckedContinuation<Void, Error>
}
