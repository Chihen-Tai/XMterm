import Foundation

public struct RemoteTransferAggregateCounts: Equatable, Sendable {
    public let nonterminalJobs: Int
    public let terminalRecords: Int
    public let workCheckpointFailureRecords: Int
    public let cleanupEntries: Int

    public init(
        nonterminalJobs: Int,
        terminalRecords: Int,
        workCheckpointFailureRecords: Int,
        cleanupEntries: Int
    ) throws {
        guard nonterminalJobs >= 0,
              terminalRecords >= 0,
              workCheckpointFailureRecords >= 0,
              cleanupEntries >= 0,
              nonterminalJobs <= RemoteTransferBounds.maximumNonterminalJobs,
              terminalRecords <= RemoteTransferBounds.maximumTerminalRecords,
              workCheckpointFailureRecords <= RemoteTransferBounds.maximumWorkCheckpointFailureRecordsPerEngine,
              cleanupEntries <= RemoteTransferBounds.maximumCleanupEntriesPerEngine else {
            throw RemoteFileError(category: .limitExceeded)
        }
        _ = try Self.checkedSum(nonterminalJobs, terminalRecords)
        self.nonterminalJobs = nonterminalJobs
        self.terminalRecords = terminalRecords
        self.workCheckpointFailureRecords = workCheckpointFailureRecords
        self.cleanupEntries = cleanupEntries
    }

    public static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw RemoteFileError(category: .limitExceeded)
        }
        return result.partialValue
    }
}

public struct RemoteTransferRetainedDataBudget: Equatable, Sendable {
    public let jobRetainedByteCount: Int
    public let engineRetainedByteCount: Int

    public init(jobRetainedByteCount: Int, engineRetainedByteCount: Int) throws {
        guard jobRetainedByteCount >= 0,
              engineRetainedByteCount >= 0,
              jobRetainedByteCount <= RemoteTransferBounds.maximumJobRetainedByteCount,
              engineRetainedByteCount <= RemoteTransferBounds.maximumEngineRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.jobRetainedByteCount = jobRetainedByteCount
        self.engineRetainedByteCount = engineRetainedByteCount
    }
}

public struct RemoteTransferAttemptItem: Equatable, Sendable {
    public let logicalItemKey: RemoteTransferLogicalItemKey
    public let attemptItemID: RemoteTransferAttemptItemID

    public init(
        logicalItemKey: RemoteTransferLogicalItemKey,
        attemptItemID: RemoteTransferAttemptItemID
    ) {
        self.logicalItemKey = logicalItemKey
        self.attemptItemID = attemptItemID
    }
}

public struct RemoteTransferWorkerContext: Equatable, Sendable {
    public let request: RemoteTransferRequest
    public let attempt: RemoteTransferAttemptIdentity
    public let items: [RemoteTransferAttemptItem]
    public let checkpointManifest: RemoteTransferCheckpointManifest
    public let retryPlan: RemoteTransferRetryPlan
    public let resolvedCollision: RemoteTransferResolvedCollision?
    public let applyToAllResolution: RemoteTransferCollisionResolution?
    public let requiresDestinationRevalidation: Bool

    public var jobID: UUID { request.id }
    public var attemptID: UUID { attempt.id }
    public var excludedCompletedItems: [RemoteTransferLogicalItemKey] {
        let committed = Set(
            checkpointManifest.checkpoints.compactMap { checkpoint in
                if case .committed = checkpoint.disposition,
                   checkpoint.key.relativeRawComponents.isEmpty {
                    return checkpoint.key.topLevelKey
                }
                return nil
            }
        )
        return request.logicalItemKeys.filter { committed.contains($0) }
    }

    public init(
        request: RemoteTransferRequest,
        attempt: RemoteTransferAttemptIdentity,
        items: [RemoteTransferAttemptItem],
        checkpointManifest: RemoteTransferCheckpointManifest,
        resolvedCollision: RemoteTransferResolvedCollision?,
        applyToAllResolution: RemoteTransferCollisionResolution?,
        requiresDestinationRevalidation: Bool
    ) {
        self.request = request
        self.attempt = attempt
        self.items = items
        self.checkpointManifest = checkpointManifest
        self.retryPlan = checkpointManifest.retryPlan()
        self.resolvedCollision = resolvedCollision
        self.applyToAllResolution = applyToAllResolution
        self.requiresDestinationRevalidation = requiresDestinationRevalidation
    }
}

public enum RemoteTransferWorkerEvent: Equatable, Sendable {
    case phase(RemoteTransferRunningPhase)
    case currentItem(RemoteTransferPresentationText?)
    case progress(
        bytesCompleted: UInt64,
        bytesTotal: UInt64?,
        itemsCompleted: Int,
        itemsTotal: Int?
    )
}

public enum RemoteTransferWorkerDisposition: Equatable, Sendable {
    case completed
    case conflict(RemoteTransferCollision)
    case cancelled
    case failed(RemoteFileError, itemFailures: [RemoteTransferItemFailure])
}

public struct RemoteTransferWorkerOutcome: Equatable, Sendable {
    public let disposition: RemoteTransferWorkerDisposition
    public let completedItems: Set<RemoteTransferLogicalItemKey>
    public let checkpointManifest: RemoteTransferCheckpointManifest

    public init(
        disposition: RemoteTransferWorkerDisposition,
        completedItems: Set<RemoteTransferLogicalItemKey>,
        checkpointManifest: RemoteTransferCheckpointManifest
    ) {
        self.disposition = disposition
        self.completedItems = completedItems
        self.checkpointManifest = checkpointManifest
    }

    public static func completed(
        completedItems: Set<RemoteTransferLogicalItemKey>,
        checkpointManifest: RemoteTransferCheckpointManifest
    ) -> Self {
        Self(
            disposition: .completed,
            completedItems: completedItems,
            checkpointManifest: checkpointManifest
        )
    }

    public static func conflict(
        collision: RemoteTransferCollision,
        completedItems: Set<RemoteTransferLogicalItemKey>,
        checkpointManifest: RemoteTransferCheckpointManifest
    ) -> Self {
        Self(
            disposition: .conflict(collision),
            completedItems: completedItems,
            checkpointManifest: checkpointManifest
        )
    }

    public static func cancelled(
        completedItems: Set<RemoteTransferLogicalItemKey>,
        checkpointManifest: RemoteTransferCheckpointManifest
    ) -> Self {
        Self(
            disposition: .cancelled,
            completedItems: completedItems,
            checkpointManifest: checkpointManifest
        )
    }

    public static func failed(
        error: RemoteFileError,
        itemFailures: [RemoteTransferItemFailure],
        completedItems: Set<RemoteTransferLogicalItemKey>,
        checkpointManifest: RemoteTransferCheckpointManifest
    ) -> Self {
        Self(
            disposition: .failed(error, itemFailures: itemFailures),
            completedItems: completedItems,
            checkpointManifest: checkpointManifest
        )
    }
}

public protocol RemoteTransferWorker: Sendable {
    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome
}

public protocol RemoteTransferWorkerFactory: Sendable {
    func makeWorker(for context: RemoteTransferWorkerContext) async throws
        -> any RemoteTransferWorker
}

public protocol RemoteTransferClock: Sendable {
    func nowNanoseconds() async -> UInt64
}

public struct SystemRemoteTransferClock: RemoteTransferClock {
    public init() {}

    public func nowNanoseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public protocol RemoteTransferIdentifierGenerator: Sendable {
    func nextIdentifier() async -> UUID
}

public struct SystemRemoteTransferIdentifierGenerator: RemoteTransferIdentifierGenerator {
    public init() {}

    public func nextIdentifier() async -> UUID {
        UUID()
    }
}

public enum RemoteTransferEngineError: Error, Equatable, Sendable {
    case invalidRequest
    case queueCapacityExceeded
    case jobNotFound
    case invalidState
    case identifierCollision
}
