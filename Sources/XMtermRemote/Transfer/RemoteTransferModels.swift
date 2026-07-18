import Foundation

public struct RemoteTransferLogicalItemKey: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RemoteTransferAttemptItemID: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RemoteTransferRequest: Equatable, Sendable {
    public let logicalItemKeys: [RemoteTransferLogicalItemKey]

    public init(logicalItemKeys: [RemoteTransferLogicalItemKey]) {
        self.logicalItemKeys = logicalItemKeys
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

public enum RemoteTransferRunningPhase: Equatable, Sendable {
    case transferring
    case verifying
}

public enum RemoteTransferJobState: Equatable, Sendable {
    case queued
    case preparing
    case running
    case conflict
    case cancelling
    case cancelled
    case completed
    case failed(RemoteFileError)

    public var isTerminal: Bool {
        switch self {
        case .cancelled, .completed, .failed:
            true
        case .queued, .preparing, .running, .conflict, .cancelling:
            false
        }
    }
}

public struct RemoteTransferItemFailure: Equatable, Sendable {
    public let logicalItemKey: RemoteTransferLogicalItemKey
    public let error: RemoteFileError

    public init(logicalItemKey: RemoteTransferLogicalItemKey, error: RemoteFileError) {
        self.logicalItemKey = logicalItemKey
        self.error = error
    }
}

public struct RemoteTransferCollision: Equatable, Sendable {
    public let logicalItemKey: RemoteTransferLogicalItemKey
    public let destination: RemotePath

    public init(logicalItemKey: RemoteTransferLogicalItemKey, destination: RemotePath) {
        self.logicalItemKey = logicalItemKey
        self.destination = destination
    }
}

public enum RemoteTransferCollisionDecision: Equatable, Sendable {
    case replace
    case skip
    case keepBoth
    case cancel
}

public struct RemoteTransferCollisionResolution: Equatable, Sendable {
    public let decision: RemoteTransferCollisionDecision
    public let applyToAll: Bool

    public init(decision: RemoteTransferCollisionDecision, applyToAll: Bool) {
        self.decision = decision
        self.applyToAll = applyToAll
    }
}

public struct RemoteTransferJobSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let attemptID: UUID
    public let state: RemoteTransferJobState
    public let runningPhase: RemoteTransferRunningPhase?
    public let bytesCompleted: UInt64
    public let bytesTotal: UInt64?
    public let itemsCompleted: Int
    public let itemsTotal: Int?
    public let itemFailures: [RemoteTransferItemFailure]
    public let collision: RemoteTransferCollision?

    public init(
        id: UUID,
        attemptID: UUID,
        state: RemoteTransferJobState,
        runningPhase: RemoteTransferRunningPhase? = nil,
        bytesCompleted: UInt64 = 0,
        bytesTotal: UInt64? = nil,
        itemsCompleted: Int = 0,
        itemsTotal: Int? = nil,
        itemFailures: [RemoteTransferItemFailure] = [],
        collision: RemoteTransferCollision? = nil
    ) {
        self.id = id
        self.attemptID = attemptID
        self.state = state
        self.runningPhase = runningPhase
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
        self.itemFailures = itemFailures
        self.collision = collision
    }
}

public struct RemoteTransferWorkerContext: Equatable, Sendable {
    public let jobID: UUID
    public let attemptID: UUID
    public let items: [RemoteTransferAttemptItem]
    public let excludedCompletedItems: [RemoteTransferLogicalItemKey]
    public let collisionResolution: RemoteTransferCollisionResolution?
    public let applyToAllDecision: RemoteTransferCollisionDecision?
    /// A resumed worker must reacquire its channel set and revalidate the current
    /// destination before applying a collision decision.
    public let requiresDestinationRevalidation: Bool

    public init(
        jobID: UUID,
        attemptID: UUID,
        items: [RemoteTransferAttemptItem],
        excludedCompletedItems: [RemoteTransferLogicalItemKey],
        collisionResolution: RemoteTransferCollisionResolution?,
        applyToAllDecision: RemoteTransferCollisionDecision?,
        requiresDestinationRevalidation: Bool
    ) {
        self.jobID = jobID
        self.attemptID = attemptID
        self.items = items
        self.excludedCompletedItems = excludedCompletedItems
        self.collisionResolution = collisionResolution
        self.applyToAllDecision = applyToAllDecision
        self.requiresDestinationRevalidation = requiresDestinationRevalidation
    }
}

public enum RemoteTransferWorkerEvent: Equatable, Sendable {
    case phase(RemoteTransferRunningPhase)
    case progress(
        bytesCompleted: UInt64,
        bytesTotal: UInt64?,
        itemsCompleted: Int,
        itemsTotal: Int?
    )
}

public enum RemoteTransferWorkerOutcome: Equatable, Sendable {
    case completed(completedItems: Set<RemoteTransferLogicalItemKey>)
    case conflict(
        collision: RemoteTransferCollision,
        completedItems: Set<RemoteTransferLogicalItemKey>
    )
    case cancelled(completedItems: Set<RemoteTransferLogicalItemKey>)
    case failed(
        error: RemoteFileError,
        itemFailures: [RemoteTransferItemFailure],
        completedItems: Set<RemoteTransferLogicalItemKey>
    )
}

public protocol RemoteTransferWorker: Sendable {
    /// Returning from cancellation means the worker has invalidated/reaped its
    /// channel set and settled its exact attempt-owned cleanup manifest.
    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome
}

public protocol RemoteTransferWorkerFactory: Sendable {
    /// Each call creates a fresh worker/channel set. A conflict-resumed context
    /// requires destination revalidation before the supplied decision is used.
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
