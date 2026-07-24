import Foundation

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

public struct RemoteTransferSafeFailureList: Equatable, Sendable {
    public let failures: [RemoteTransferItemFailure]
    public let retainedByteCount: Int

    public init(_ failures: [RemoteTransferItemFailure]) throws {
        guard failures.count <= RemoteTransferBounds.maximumSafeFailuresPerSnapshot else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard Set(failures.map(\.logicalItemKey)).count == failures.count else {
            throw RemoteFileError(category: .invalidOperation)
        }
        retainedByteCount = try failures.reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1.error.userFacingMessage.utf8.count)
        }
        guard retainedByteCount <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.failures = failures
    }
}

public struct RemoteTransferCollision: Equatable, Sendable {
    public let workItemKey: RemoteTransferWorkItemKey
    public var logicalItemKey: RemoteTransferLogicalItemKey { workItemKey.topLevelKey }
    public let destination: RemotePath

    public init(logicalItemKey: RemoteTransferLogicalItemKey, destination: RemotePath) {
        workItemKey = RemoteTransferWorkItemKey(topLevelKey: logicalItemKey)
        self.destination = destination
    }

    public init(workItemKey: RemoteTransferWorkItemKey, destination: RemotePath) {
        self.workItemKey = workItemKey
        self.destination = destination
    }
}

public struct RemoteTransferCollisionSummary: Equatable, Sendable {
    public let logicalItemKey: RemoteTransferLogicalItemKey
    public let destinationSummary: RemoteTransferPresentationText

    public init(
        logicalItemKey: RemoteTransferLogicalItemKey,
        destinationSummary: RemoteTransferPresentationText
    ) {
        self.logicalItemKey = logicalItemKey
        self.destinationSummary = destinationSummary
    }

    package init(_ collision: RemoteTransferCollision) {
        logicalItemKey = collision.logicalItemKey
        destinationSummary = RemoteTransferPresentationText(
            bounding: collision.destination.escapedDisplayString
        )
    }
}

public struct RemoteTransferCurrentCollision: Equatable, Sendable {
    public let collision: RemoteTransferCollisionSummary?

    public init(collisions: [RemoteTransferCollisionSummary]) throws {
        guard collisions.count <= RemoteTransferBounds.maximumCurrentCollisionsPerJob else {
            throw RemoteFileError(category: .limitExceeded)
        }
        collision = collisions.first
    }
}

public enum RemoteTransferCollisionDecision: Equatable, Sendable {
    case replace
    case skip
    case keepBoth
    case cancel
}

public enum RemoteTransferReplacementGuarantee: Equatable, Sendable {
    case notApplicable
    case atomicOnly
    case explicitlyAcceptedNonAtomicFallback
}

public struct RemoteTransferCollisionResolution: Equatable, Sendable {
    public let decision: RemoteTransferCollisionDecision
    public let applyToAll: Bool
    public let replacementGuarantee: RemoteTransferReplacementGuarantee

    public init(decision: RemoteTransferCollisionDecision, applyToAll: Bool) throws {
        try self.init(
            decision: decision,
            applyToAll: applyToAll,
            replacementGuarantee: decision == .replace ? .atomicOnly : .notApplicable
        )
    }

    public init(
        decision: RemoteTransferCollisionDecision,
        applyToAll: Bool,
        replacementGuarantee: RemoteTransferReplacementGuarantee
    ) throws {
        let validGuarantee = switch (decision, replacementGuarantee) {
        case (.replace, .atomicOnly),
             (.replace, .explicitlyAcceptedNonAtomicFallback):
            true
        case (.skip, .notApplicable),
             (.keepBoth, .notApplicable),
             (.cancel, .notApplicable):
            true
        default:
            false
        }
        guard validGuarantee,
              !(applyToAll && decision == .cancel) else {
            throw RemoteFileError(category: .invalidOperation)
        }
        self.decision = decision
        self.applyToAll = applyToAll
        self.replacementGuarantee = replacementGuarantee
    }
}

public struct RemoteTransferResolvedCollision: Equatable, Sendable {
    public let collision: RemoteTransferCollision
    private let boundResolution: RemoteTransferCollisionResolution

    public init(
        collision: RemoteTransferCollision,
        resolution: RemoteTransferCollisionResolution
    ) {
        self.collision = collision
        boundResolution = resolution
    }

    public func resolution(
        ifRevalidated revalidatedCollision: RemoteTransferCollision
    ) -> RemoteTransferCollisionResolution? {
        guard collision.workItemKey == revalidatedCollision.workItemKey,
              collision.destination.rawBytes == revalidatedCollision.destination.rawBytes else {
            return nil
        }
        return boundResolution
    }
}

public struct RemoteTransferTimestamps: Equatable, Sendable {
    public let createdAtNanoseconds: UInt64
    public let startedAtNanoseconds: UInt64?
    public let updatedAtNanoseconds: UInt64
    public let settledAtNanoseconds: UInt64?

    public init(
        createdAtNanoseconds: UInt64,
        startedAtNanoseconds: UInt64?,
        updatedAtNanoseconds: UInt64,
        settledAtNanoseconds: UInt64?
    ) throws {
        guard startedAtNanoseconds.map({ $0 >= createdAtNanoseconds }) ?? true,
              updatedAtNanoseconds >= createdAtNanoseconds,
              startedAtNanoseconds.map({ updatedAtNanoseconds >= $0 }) ?? true,
              settledAtNanoseconds.map({ $0 >= updatedAtNanoseconds }) ?? true else {
            throw RemoteFileError(category: .invalidOperation)
        }
        self.createdAtNanoseconds = createdAtNanoseconds
        self.startedAtNanoseconds = startedAtNanoseconds
        self.updatedAtNanoseconds = updatedAtNanoseconds
        self.settledAtNanoseconds = settledAtNanoseconds
    }

    package init(
        uncheckedCreatedAtNanoseconds createdAtNanoseconds: UInt64,
        startedAtNanoseconds: UInt64?,
        updatedAtNanoseconds: UInt64,
        settledAtNanoseconds: UInt64?
    ) {
        self.createdAtNanoseconds = createdAtNanoseconds
        self.startedAtNanoseconds = startedAtNanoseconds
        self.updatedAtNanoseconds = updatedAtNanoseconds
        self.settledAtNanoseconds = settledAtNanoseconds
    }
}

public struct RemoteTransferJobSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let attempt: RemoteTransferAttemptIdentity
    public var attemptID: UUID { attempt.id }
    public let kind: RemoteTransferJobKind
    public let state: RemoteTransferJobState
    public let runningPhase: RemoteTransferRunningPhase?
    public let sourceSummary: RemoteTransferPresentationText
    public let destinationSummary: RemoteTransferPresentationText
    public let currentItemDisplay: RemoteTransferPresentationText?
    public let bytesCompleted: UInt64
    public let bytesTotal: UInt64?
    public let itemsCompleted: Int
    public let itemsTotal: Int?
    public let itemFailures: [RemoteTransferItemFailure]
    public let collision: RemoteTransferCollisionSummary?
    public let canRetry: Bool
    public let timestamps: RemoteTransferTimestamps

    public init(
        id: UUID,
        attempt: RemoteTransferAttemptIdentity,
        kind: RemoteTransferJobKind,
        state: RemoteTransferJobState,
        runningPhase: RemoteTransferRunningPhase? = nil,
        sourceSummary: RemoteTransferPresentationText,
        destinationSummary: RemoteTransferPresentationText,
        currentItemDisplay: RemoteTransferPresentationText?,
        bytesCompleted: UInt64 = 0,
        bytesTotal: UInt64? = nil,
        itemsCompleted: Int = 0,
        itemsTotal: Int? = nil,
        itemFailures: [RemoteTransferItemFailure] = [],
        collision: RemoteTransferCollisionSummary? = nil,
        canRetry: Bool,
        timestamps: RemoteTransferTimestamps
    ) throws {
        let safeFailures = try RemoteTransferSafeFailureList(itemFailures)
        let collisionState = try RemoteTransferCurrentCollision(
            collisions: collision.map { [$0] } ?? []
        )
        let stateFailureByteCount: Int
        if case let .failed(error) = state {
            stateFailureByteCount = error.userFacingMessage.utf8.count
        } else {
            stateFailureByteCount = 0
        }
        let presentationBytes = try [
            sourceSummary.value.utf8.count,
            destinationSummary.value.utf8.count,
            currentItemDisplay?.value.utf8.count ?? 0,
            safeFailures.retainedByteCount,
            collision?.destinationSummary.value.utf8.count ?? 0,
            stateFailureByteCount
        ].reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1)
        }
        guard presentationBytes <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard bytesTotal.map({ bytesCompleted <= $0 }) ?? true,
              itemsCompleted >= 0,
              itemsTotal.map({ itemsCompleted <= $0 }) ?? true else {
            throw RemoteFileError(category: .invalidOperation)
        }

        self.id = id
        self.attempt = attempt
        self.kind = kind
        self.state = state
        self.runningPhase = runningPhase
        self.sourceSummary = sourceSummary
        self.destinationSummary = destinationSummary
        self.currentItemDisplay = currentItemDisplay
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
        self.itemFailures = safeFailures.failures
        self.collision = collisionState.collision
        self.canRetry = canRetry
        self.timestamps = timestamps
    }

    package init(
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
        self.attempt = RemoteTransferAttemptIdentity(uncheckedID: attemptID, generation: 1)
        self.kind = .download
        self.state = state
        self.runningPhase = runningPhase
        self.sourceSummary = RemoteTransferPresentationText(unchecked: "")
        self.destinationSummary = RemoteTransferPresentationText(unchecked: "")
        self.currentItemDisplay = nil
        self.bytesCompleted = bytesCompleted
        self.bytesTotal = bytesTotal
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
        self.itemFailures = itemFailures
        self.collision = collision.map(RemoteTransferCollisionSummary.init)
        self.canRetry = false
        self.timestamps = RemoteTransferTimestamps(
            uncheckedCreatedAtNanoseconds: 0,
            startedAtNanoseconds: nil,
            updatedAtNanoseconds: 0,
            settledAtNanoseconds: nil
        )
    }

    package init(
        failClosedFrom prior: RemoteTransferJobSnapshot,
        error: RemoteFileError,
        updatedAtNanoseconds: UInt64,
        canRetry: Bool
    ) {
        let updated = max(updatedAtNanoseconds, prior.timestamps.updatedAtNanoseconds)
        self.id = prior.id
        self.attempt = prior.attempt
        self.kind = prior.kind
        self.state = .failed(error)
        self.runningPhase = nil
        self.sourceSummary = prior.sourceSummary
        self.destinationSummary = prior.destinationSummary
        self.currentItemDisplay = nil
        self.bytesCompleted = prior.bytesCompleted
        self.bytesTotal = prior.bytesTotal
        self.itemsCompleted = prior.itemsCompleted
        self.itemsTotal = prior.itemsTotal
        self.itemFailures = []
        self.collision = nil
        self.canRetry = canRetry
        self.timestamps = RemoteTransferTimestamps(
            uncheckedCreatedAtNanoseconds: prior.timestamps.createdAtNanoseconds,
            startedAtNanoseconds: prior.timestamps.startedAtNanoseconds,
            updatedAtNanoseconds: updated,
            settledAtNanoseconds: updated
        )
    }

    package init(
        settlingFrom prior: RemoteTransferJobSnapshot,
        updatedAtNanoseconds: UInt64
    ) {
        let updated = max(updatedAtNanoseconds, prior.timestamps.updatedAtNanoseconds)
        self.id = prior.id
        self.attempt = prior.attempt
        self.kind = prior.kind
        self.state = .cancelling
        self.runningPhase = nil
        self.sourceSummary = prior.sourceSummary
        self.destinationSummary = prior.destinationSummary
        self.currentItemDisplay = nil
        self.bytesCompleted = prior.bytesCompleted
        self.bytesTotal = prior.bytesTotal
        self.itemsCompleted = prior.itemsCompleted
        self.itemsTotal = prior.itemsTotal
        self.itemFailures = []
        self.collision = nil
        self.canRetry = false
        self.timestamps = RemoteTransferTimestamps(
            uncheckedCreatedAtNanoseconds: prior.timestamps.createdAtNanoseconds,
            startedAtNanoseconds: prior.timestamps.startedAtNanoseconds,
            updatedAtNanoseconds: updated,
            settledAtNanoseconds: nil
        )
    }
}

extension RemoteTransferJobState {
    package var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
