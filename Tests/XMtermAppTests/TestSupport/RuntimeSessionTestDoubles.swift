import Darwin
import XMtermCore
import XMtermRemote
import XMtermTerminal

actor RuntimeSessionTestRemoteFileProvider: RemoteFileProvider {
    struct Snapshot: Sendable {
        let resolveCount: Int
        let listCount: Int
        let cancelAllCount: Int
        let closeCount: Int
    }

    private let resolveFailure: RemoteFileError?
    private let suspendsClose: Bool
    private var closeWasReleased = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var resolveCount = 0
    private var listCount = 0
    private var cancelAllCount = 0
    private var closeCount = 0

    init(
        resolveFailure: RemoteFileError? = nil,
        suspendsClose: Bool = false
    ) {
        self.resolveFailure = resolveFailure
        self.suspendsClose = suspendsClose
    }

    func resolveInitialDirectory() async throws -> RemotePath {
        resolveCount += 1
        if let resolveFailure { throw resolveFailure }
        return .root
    }

    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        listCount += 1
        return try RemoteDirectoryListing(directory: path, entries: [])
    }

    func cancelAll() async {
        cancelAllCount += 1
    }

    func close() async {
        closeCount += 1
        guard suspendsClose, !closeWasReleased else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    func releaseClose() {
        closeWasReleased = true
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            resolveCount: resolveCount,
            listCount: listCount,
            cancelAllCount: cancelAllCount,
            closeCount: closeCount
        )
    }
}

actor RuntimeSessionTestTerminalProcess: TerminalProcess {
    private let suspendsClose: Bool
    private var closeWasReleased = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitStatus: TerminalExitStatus?
    private var exitWaiters: [CheckedContinuation<TerminalExitStatus, Error>] = []
    private var closeCount = 0

    init(suspendsClose: Bool = false) {
        self.suspendsClose = suspendsClose
    }

    func read(upToCount maximumByteCount: Int) async throws -> [UInt8]? { nil }
    func write(_ bytes: [UInt8]) async throws {}
    func resize(to size: TerminalGridSize) async throws {}
    func childExitStatusIfAvailable() async -> TerminalExitStatus? { exitStatus }

    func waitForExit() async throws -> TerminalExitStatus {
        if let exitStatus { return exitStatus }
        return try await withCheckedThrowingContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    func foregroundProcessGroupState() async -> PTYForegroundProcessGroupState { .shell }

    func close(outputPolicy: PTYCloseOutputPolicy) async throws -> TerminalExitStatus {
        closeCount += 1
        if suspendsClose, !closeWasReleased {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
        }
        let status = TerminalExitStatus.signaled(signal: SIGTERM)
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters = []
        waiters.forEach { $0.resume(returning: status) }
        return status
    }

    func releaseClose() {
        closeWasReleased = true
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func recordedCloseCount() -> Int { closeCount }
}

actor RuntimeSessionTestLaunchProbe {
    private var launchCount = 0

    func recordLaunch() {
        launchCount += 1
    }

    func count() -> Int { launchCount }
}
