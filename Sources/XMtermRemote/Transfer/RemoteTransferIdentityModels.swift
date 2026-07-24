import Foundation
import XMtermCore

public enum RemoteTransferBounds {
    public static let maximumNonterminalJobs = 1_000
    public static let maximumTerminalRecords = 500
    public static let maximumTopLevelRequestedItemsPerJob = 20_000
    public static let maximumWorkCheckpointFailureRecordsPerJob = 20_000
    public static let maximumWorkCheckpointFailureRecordsPerEngine = 40_000
    public static let maximumCleanupEntriesPerJob = 40_000
    public static let maximumCleanupEntriesPerEngine = 80_000
    public static let maximumRecursiveDepth = 128
    public static let maximumPendingDirectories = 1_024
    public static let maximumCurrentCollisionsPerJob = 1
    public static let maximumWorkItemRelativeComponentCount = 128
    public static let maximumWorkItemRelativeRawPathByteCount = 32 * 1_024
    public static let maximumLocalURLByteCount = 32 * 1_024
    public static let maximumLocalIdentifierByteCount = 4 * 1_024
    public static let maximumSecurityScopedBookmarkByteCount = 64 * 1_024
    public static let maximumJobRetainedByteCount = 16 * 1_024 * 1_024
    public static let maximumEngineRetainedByteCount = 64 * 1_024 * 1_024
    public static let maximumSafeFailuresPerSnapshot = 20_000
}

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

public enum RemoteTransferJobKind: Equatable, Sendable {
    case upload, download, remoteCopy, remoteMove, delete
    case createFile, createDirectory, rename
}

public struct RemoteTransferOwnerIdentity: Equatable, Hashable, Sendable {
    public let runtimeID: TerminalSessionID
    public let workspaceID: RemoteWorkspaceID

    public init(runtimeID: TerminalSessionID, workspaceID: RemoteWorkspaceID) {
        self.runtimeID = runtimeID
        self.workspaceID = workspaceID
    }
}

public enum RemoteTransferEndpointKind: Equatable, Sendable {
    case openSSH, simulated, packageTest
}

public struct RemoteTransferPresentationText: Equatable, Sendable {
    public static let maximumUTF8ByteCount = 4 * 1_024

    public let value: String

    public init(_ value: String) throws {
        guard value.utf8.count <= Self.maximumUTF8ByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.value = value
    }

    package init(unchecked value: String) {
        self.value = value
    }

    package init(bounding value: String) {
        self.value = RemoteUserFacingText.bounded(
            value,
            maximumByteCount: Self.maximumUTF8ByteCount
        )
    }
}

package protocol RemoteTransferTrustedConnectionMaterial: Sendable {
    var retainedByteCount: Int { get }
}

public struct RemoteTransferEndpointSummary: Equatable, Sendable {
    public let displayName: RemoteTransferPresentationText
    public let kind: RemoteTransferEndpointKind

    public init(displayName: RemoteTransferPresentationText, kind: RemoteTransferEndpointKind) {
        self.displayName = displayName
        self.kind = kind
    }
}

public struct RemoteTransferEndpointSnapshot: Equatable, Sendable {
    public let id: UUID
    public let owner: RemoteTransferOwnerIdentity
    public let summary: RemoteTransferEndpointSummary
    package let trustedConnectionMaterial: any RemoteTransferTrustedConnectionMaterial
    package let storedRetainedByteCount: Int

    package var retainedByteCount: Int {
        storedRetainedByteCount
    }

    package init(
        id: UUID,
        owner: RemoteTransferOwnerIdentity,
        summary: RemoteTransferEndpointSummary,
        trustedConnectionMaterial: any RemoteTransferTrustedConnectionMaterial
    ) throws {
        let retained = try RemoteTransferAggregateCounts.checkedSum(
            summary.displayName.value.utf8.count,
            trustedConnectionMaterial.retainedByteCount
        )
        guard trustedConnectionMaterial.retainedByteCount >= 0,
              retained <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.id = id
        self.owner = owner
        self.summary = summary
        self.trustedConnectionMaterial = trustedConnectionMaterial
        self.storedRetainedByteCount = retained
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

public enum RemoteTransferLocalItemKind: Equatable, Sendable {
    case regularFile, directory
}

public struct RemoteTransferLocalFileIdentity: Equatable, Sendable {
    public let url: URL
    public let fileResourceIdentifier: Data
    public let volumeIdentifier: Data?
    public let kind: RemoteTransferLocalItemKind
    public let observedSize: UInt64?
    public let observedModificationNanoseconds: Int64?
    package let securityScopedBookmark: Data?
    package let storedRetainedByteCount: Int

    public var retainedByteCount: Int {
        storedRetainedByteCount
    }

    package init(
        url: URL,
        fileResourceIdentifier: Data,
        volumeIdentifier: Data?,
        kind: RemoteTransferLocalItemKind,
        observedSize: UInt64?,
        observedModificationNanoseconds: Int64?,
        securityScopedBookmark: Data?
    ) throws {
        let pathByteCount = url.path(percentEncoded: false).utf8.count
        let retained = try [
            pathByteCount,
            fileResourceIdentifier.count,
            volumeIdentifier?.count ?? 0,
            securityScopedBookmark?.count ?? 0
        ].reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1)
        }
        guard url.isFileURL,
              url.path(percentEncoded: false).hasPrefix("/"),
              !fileResourceIdentifier.isEmpty else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard pathByteCount <= RemoteTransferBounds.maximumLocalURLByteCount,
              fileResourceIdentifier.count <= RemoteTransferBounds.maximumLocalIdentifierByteCount,
              (volumeIdentifier?.count ?? 0) <= RemoteTransferBounds.maximumLocalIdentifierByteCount,
              (securityScopedBookmark?.count ?? 0) <= RemoteTransferBounds.maximumSecurityScopedBookmarkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.url = url
        self.fileResourceIdentifier = fileResourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.kind = kind
        self.observedSize = observedSize
        self.observedModificationNanoseconds = observedModificationNanoseconds
        self.securityScopedBookmark = securityScopedBookmark
        self.storedRetainedByteCount = retained
    }
}

public enum RemoteTransferItemSource: Equatable, Sendable {
    case remote(endpoint: RemoteTransferEndpointSnapshot, path: RemotePath)
    case local(RemoteTransferLocalFileIdentity)

    func checkedRetainedByteCountExcludingEndpoint() -> Int {
        switch self {
        case let .remote(_, path):
            return path.rawBytes.count
        case let .local(identity):
            return identity.retainedByteCount
        }
    }

    var remoteEndpoint: RemoteTransferEndpointSnapshot? {
        if case let .remote(endpoint, _) = self { return endpoint }
        return nil
    }
}

public struct RemoteTransferRequestedItem: Equatable, Sendable {
    public let logicalKey: RemoteTransferLogicalItemKey
    public let source: RemoteTransferItemSource

    public init(logicalKey: RemoteTransferLogicalItemKey, source: RemoteTransferItemSource) {
        self.logicalKey = logicalKey
        self.source = source
    }
}

public enum RemoteTransferDestination: Equatable, Sendable {
    case remoteDirectory(endpoint: RemoteTransferEndpointSnapshot, path: RemotePath)
    case remotePath(endpoint: RemoteTransferEndpointSnapshot, path: RemotePath)
    case localDirectory(RemoteTransferLocalFileIdentity)
    case none

    var remoteEndpoint: RemoteTransferEndpointSnapshot? {
        switch self {
        case let .remoteDirectory(endpoint, _), let .remotePath(endpoint, _):
            return endpoint
        case .localDirectory, .none:
            return nil
        }
    }

    func checkedRetainedByteCountExcludingEndpoint() -> Int {
        switch self {
        case let .remoteDirectory(_, path), let .remotePath(_, path):
            return path.rawBytes.count
        case let .localDirectory(identity):
            return identity.retainedByteCount
        case .none:
            return 0
        }
    }
}
