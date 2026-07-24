import Foundation

public struct RemoteTransferAttemptIdentity: Equatable, Hashable, Sendable {
    public let id: UUID
    public let generation: UInt64

    public init(id: UUID, generation: UInt64) throws {
        guard generation >= 1 else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.id = id
        self.generation = generation
    }

    package init(uncheckedID id: UUID, generation: UInt64) {
        self.id = id
        self.generation = generation
    }

    public func nextAttempt(id: UUID) throws -> Self {
        guard id != self.id else {
            throw RemoteFileError(category: .invalidOperation)
        }
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else {
            throw RemoteFileError(category: .limitExceeded)
        }
        return try Self(id: id, generation: next.partialValue)
    }

    public func matches(id: UUID, generation: UInt64) -> Bool {
        self.id == id && self.generation == generation
    }
}

public struct RemoteTransferWorkItemKey: Equatable, Hashable, Sendable {
    public let topLevelKey: RemoteTransferLogicalItemKey
    public let relativeRawComponents: [RemotePathComponent]

    package var retainedByteCount: Int {
        relativeRawComponents.reduce(0) { $0 + $1.rawBytes.count }
    }

    public init(
        topLevelKey: RemoteTransferLogicalItemKey,
        relativeRawComponents: [RemotePathComponent]
    ) throws {
        let rawCount = try relativeRawComponents.reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1.rawBytes.count)
        }
        guard relativeRawComponents.count <= RemoteTransferBounds.maximumWorkItemRelativeComponentCount,
              rawCount <= RemoteTransferBounds.maximumWorkItemRelativeRawPathByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.topLevelKey = topLevelKey
        self.relativeRawComponents = relativeRawComponents
    }

    package init(topLevelKey: RemoteTransferLogicalItemKey) {
        self.topLevelKey = topLevelKey
        relativeRawComponents = []
    }
}

public enum RemoteTransferCheckpointDisposition: Equatable, Sendable {
    case discovered, committed, failed(RemoteFileError), unstarted
}

public struct RemoteTransferCheckpoint: Equatable, Sendable {
    public let key: RemoteTransferWorkItemKey
    public let disposition: RemoteTransferCheckpointDisposition

    public init(
        key: RemoteTransferWorkItemKey,
        disposition: RemoteTransferCheckpointDisposition
    ) {
        self.key = key
        self.disposition = disposition
    }
}

public struct RemoteTransferRetryWorkItem: Equatable, Sendable {
    public let key: RemoteTransferWorkItemKey
    public let restartByteOffset: UInt64
}

public struct RemoteTransferRetryPlan: Equatable, Sendable {
    public let excludedCommittedKeys: [RemoteTransferWorkItemKey]
    public let workToRestart: [RemoteTransferRetryWorkItem]
}

public struct RemoteTransferWorkRecordCounts: Equatable, Sendable {
    public let discoveredWorkItems: Int
    public let checkpoints: Int
    public let itemFailures: Int
    public let combinedCount: Int

    public init(
        discoveredWorkItems: Int,
        checkpoints: Int,
        itemFailures: Int
    ) throws {
        guard discoveredWorkItems >= 0, checkpoints >= 0, itemFailures >= 0 else {
            throw RemoteFileError(category: .limitExceeded)
        }
        let first = try RemoteTransferAggregateCounts.checkedSum(discoveredWorkItems, checkpoints)
        let combined = try RemoteTransferAggregateCounts.checkedSum(first, itemFailures)
        guard combined <= RemoteTransferBounds.maximumWorkCheckpointFailureRecordsPerJob else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.discoveredWorkItems = discoveredWorkItems
        self.checkpoints = checkpoints
        self.itemFailures = itemFailures
        self.combinedCount = combined
    }
}

public enum RemoteTransferCleanupLocation: Equatable, Sendable {
    case remote(endpointID: UUID, path: RemotePath)
    case localDirectoryEntry(
        directory: RemoteTransferLocalFileIdentity,
        component: RemotePathComponent
    )
}

public struct RemoteTransferCleanupEntry: Equatable, Sendable {
    public let attempt: RemoteTransferAttemptIdentity
    public let workItemKey: RemoteTransferWorkItemKey
    public let location: RemoteTransferCleanupLocation

    public init(
        attempt: RemoteTransferAttemptIdentity,
        workItemKey: RemoteTransferWorkItemKey,
        location: RemoteTransferCleanupLocation
    ) {
        self.attempt = attempt
        self.workItemKey = workItemKey
        self.location = location
    }
}

public struct RemoteTransferCheckpointManifest: Equatable, Sendable {
    public static let empty = RemoteTransferCheckpointManifest(
        uncheckedCheckpoints: [],
        cleanupEntries: [],
        retainedByteCount: 0
    )

    public let checkpoints: [RemoteTransferCheckpoint]
    public let cleanupEntries: [RemoteTransferCleanupEntry]
    public let retainedByteCount: Int

    public init(
        checkpoints: [RemoteTransferCheckpoint],
        cleanupEntries: [RemoteTransferCleanupEntry]
    ) throws {
        _ = try RemoteTransferWorkRecordCounts(
            discoveredWorkItems: 0,
            checkpoints: checkpoints.count,
            itemFailures: 0
        )
        guard cleanupEntries.count <= RemoteTransferBounds.maximumCleanupEntriesPerJob else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard Set(checkpoints.map(\.key)).count == checkpoints.count else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard Set(cleanupEntries.map(RemoteTransferCleanupIdentity.init)).count == cleanupEntries.count else {
            throw RemoteFileError(category: .invalidOperation)
        }
        let retained = try Self.retainedByteCount(
            checkpoints: checkpoints,
            cleanupEntries: cleanupEntries
        )
        guard retained <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.checkpoints = checkpoints
        self.cleanupEntries = cleanupEntries
        self.retainedByteCount = retained
    }

    private init(
        uncheckedCheckpoints checkpoints: [RemoteTransferCheckpoint],
        cleanupEntries: [RemoteTransferCleanupEntry],
        retainedByteCount: Int
    ) {
        self.checkpoints = checkpoints
        self.cleanupEntries = cleanupEntries
        self.retainedByteCount = retainedByteCount
    }

    public func retryPlan() -> RemoteTransferRetryPlan {
        var excluded: [RemoteTransferWorkItemKey] = []
        var restart: [RemoteTransferRetryWorkItem] = []
        for checkpoint in checkpoints {
            switch checkpoint.disposition {
            case .committed:
                excluded.append(checkpoint.key)
            case .discovered, .failed, .unstarted:
                restart.append(
                    RemoteTransferRetryWorkItem(
                        key: checkpoint.key,
                        restartByteOffset: 0
                    )
                )
            }
        }
        return RemoteTransferRetryPlan(
            excludedCommittedKeys: excluded,
            workToRestart: restart
        )
    }

    private static func retainedByteCount(
        checkpoints: [RemoteTransferCheckpoint],
        cleanupEntries: [RemoteTransferCleanupEntry]
    ) throws -> Int {
        let checkpointBytes = try checkpoints.reduce(0) { partial, checkpoint in
            let keyBytes = try checkpoint.key.checkedRetainedByteCount()
            let errorBytes: Int = switch checkpoint.disposition {
            case let .failed(error): error.userFacingMessage.utf8.count
            case .discovered, .committed, .unstarted: 0
            }
            return try RemoteTransferAggregateCounts.checkedSum(
                try RemoteTransferAggregateCounts.checkedSum(partial, keyBytes),
                errorBytes
            )
        }
        return try cleanupEntries.reduce(checkpointBytes) { partial, cleanup in
            try RemoteTransferAggregateCounts.checkedSum(
                partial,
                cleanup.checkedRetainedByteCount()
            )
        }
    }
}

private struct RemoteTransferCleanupIdentity: Hashable {
    let attempt: RemoteTransferAttemptIdentity
    let workItemKey: RemoteTransferWorkItemKey
    let location: Location

    init(_ entry: RemoteTransferCleanupEntry) {
        attempt = entry.attempt
        workItemKey = entry.workItemKey
        location = Location(entry.location)
    }

    enum Location: Hashable {
        case remote(UUID, RemotePath)
        case local(URL, RemotePathComponent)

        init(_ location: RemoteTransferCleanupLocation) {
            switch location {
            case let .remote(endpointID, path):
                self = .remote(endpointID, path)
            case let .localDirectoryEntry(directory, component):
                self = .local(directory.url, component)
            }
        }
    }
}

private extension RemoteTransferWorkItemKey {
    func checkedRetainedByteCount() throws -> Int {
        retainedByteCount
    }
}

private extension RemoteTransferCleanupEntry {
    func checkedRetainedByteCount() throws -> Int {
        let locationBytes: Int
        switch location {
        case let .remote(_, path):
            locationBytes = path.rawBytes.count
        case let .localDirectoryEntry(directory, component):
            locationBytes = try RemoteTransferAggregateCounts.checkedSum(
                directory.retainedByteCount,
                component.rawBytes.count
            )
        }
        return try RemoteTransferAggregateCounts.checkedSum(
            workItemKey.checkedRetainedByteCount(),
            locationBytes
        )
    }
}
