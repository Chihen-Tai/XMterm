import XMtermRemote

actor ControllableRemoteFileProvider: RemoteFileProvider {
    enum Attempt: Equatable, Sendable {
        case resolveInitialDirectory(requestID: UInt64)
        case listDirectory(requestID: UInt64, path: RemotePath)
        case cancelledWaiter

        var requestID: UInt64 {
            switch self {
            case let .resolveInitialDirectory(requestID): requestID
            case let .listDirectory(requestID, _): requestID
            case .cancelledWaiter: UInt64.max
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        let attempts: [Attempt]
        let cancelledRequestIDs: Set<UInt64>
        let cancelAllCount: Int
        let closeCount: Int
        let pendingRequestCount: Int
        let maximumPendingRequestCount: Int
        let maximumPendingListingCountByPath: [RemotePath: Int]
    }

    private enum PendingRequest {
        case resolve(CheckedContinuation<RemotePath, Error>)
        case listing(
            path: RemotePath,
            continuation: CheckedContinuation<RemoteDirectoryListing, Error>
        )
    }

    private var nextRequestID: UInt64 = 0
    private var pendingRequests: [UInt64: PendingRequest] = [:]
    private var bufferedAttempts: [Attempt] = []
    private var recordedAttempts: [Attempt] = []
    private var cancelledRequestIDs: Set<UInt64> = []
    private var cancelAllCount = 0
    private var closeCount = 0
    private var maximumPendingRequestCount = 0
    private var maximumPendingListingCountByPath: [RemotePath: Int] = [:]

    private let suspendsCancelAll: Bool
    private let suspendsClose: Bool
    private let honorsTaskCancellation: Bool
    private var cancelAllWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseCancelAllWasRequested = false
    private var releaseCloseWasRequested = false

    init(
        suspendsCancelAll: Bool = false,
        suspendsClose: Bool = false,
        honorsTaskCancellation: Bool = true
    ) {
        self.suspendsCancelAll = suspendsCancelAll
        self.suspendsClose = suspendsClose
        self.honorsTaskCancellation = honorsTaskCancellation
    }

    func resolveInitialDirectory() async throws -> RemotePath {
        try Task.checkCancellation()
        let requestID = allocateRequestID()
        record(.resolveInitialDirectory(requestID: requestID))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = .resolve(continuation)
                recordPendingRequestHighWaterMarks()
            }
        } onCancel: {
            Task { await self.cancelFromTask(requestID: requestID) }
        }
    }

    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        try Task.checkCancellation()
        let requestID = allocateRequestID()
        record(.listDirectory(requestID: requestID, path: path))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = .listing(
                    path: path,
                    continuation: continuation
                )
                recordPendingRequestHighWaterMarks()
            }
        } onCancel: {
            Task { await self.cancelFromTask(requestID: requestID) }
        }
    }

    func cancelAll() async {
        cancelAllCount += 1
        let requestIDs = Array(pendingRequests.keys)
        for requestID in requestIDs {
            cancel(requestID: requestID)
        }
        guard suspendsCancelAll, !releaseCancelAllWasRequested else { return }
        await withCheckedContinuation { continuation in
            cancelAllWaiters = cancelAllWaiters + [continuation]
        }
    }

    func close() async {
        closeCount += 1
        guard suspendsClose, !releaseCloseWasRequested else { return }
        await withCheckedContinuation { continuation in
            closeWaiters = closeWaiters + [continuation]
        }
    }

    func nextAttempt() async -> Attempt {
        while bufferedAttempts.isEmpty {
            if Task.isCancelled { return .cancelledWaiter }
            await Task.yield()
        }
        return bufferedAttempts.removeFirst()
    }

    func succeedResolve(requestID: UInt64, path: RemotePath) {
        guard case let .resolve(continuation) = pendingRequests.removeValue(
            forKey: requestID
        ) else { return }
        continuation.resume(returning: path)
    }

    func succeedListing(
        requestID: UInt64,
        listing: RemoteDirectoryListing
    ) {
        guard case let .listing(_, continuation) = pendingRequests.removeValue(
            forKey: requestID
        ) else { return }
        continuation.resume(returning: listing)
    }

    func fail(requestID: UInt64, error: RemoteFileError) {
        guard let request = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        switch request {
        case let .resolve(continuation):
            continuation.resume(throwing: error)
        case let .listing(_, continuation):
            continuation.resume(throwing: error)
        }
    }

    func releaseCancelAll() {
        releaseCancelAllWasRequested = true
        let waiters = cancelAllWaiters
        cancelAllWaiters = []
        waiters.forEach { $0.resume() }
    }

    func releaseClose() {
        releaseCloseWasRequested = true
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            attempts: recordedAttempts,
            cancelledRequestIDs: cancelledRequestIDs,
            cancelAllCount: cancelAllCount,
            closeCount: closeCount,
            pendingRequestCount: pendingRequests.count,
            maximumPendingRequestCount: maximumPendingRequestCount,
            maximumPendingListingCountByPath: maximumPendingListingCountByPath
        )
    }

    private func allocateRequestID() -> UInt64 {
        let requestID = nextRequestID
        nextRequestID &+= 1
        return requestID
    }

    private func record(_ attempt: Attempt) {
        recordedAttempts.append(attempt)
        bufferedAttempts.append(attempt)
    }

    private func cancelFromTask(requestID: UInt64) {
        cancelledRequestIDs.insert(requestID)
        guard honorsTaskCancellation else { return }
        cancel(requestID: requestID)
    }

    private func cancel(requestID: UInt64) {
        guard let request = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        cancelledRequestIDs.insert(requestID)
        let error = RemoteFileError(category: .cancelled)
        switch request {
        case let .resolve(continuation):
            continuation.resume(throwing: error)
        case let .listing(_, continuation):
            continuation.resume(throwing: error)
        }
    }

    private func recordPendingRequestHighWaterMarks() {
        maximumPendingRequestCount = max(
            maximumPendingRequestCount,
            pendingRequests.count
        )
        let listingCounts = pendingRequests.values.reduce(
            into: [RemotePath: Int]()
        ) { counts, request in
            guard case let .listing(path, _) = request else { return }
            counts[path, default: 0] += 1
        }
        for (path, count) in listingCounts {
            maximumPendingListingCountByPath[path] = max(
                maximumPendingListingCountByPath[path] ?? 0,
                count
            )
        }
    }
}
