import Foundation
import XMtermCore

public enum RemoteTransferCollisionPolicy: Equatable, Sendable {
    case notApplicable, ask, replace, skip, keepBoth

    var isExplicit: Bool { self != .notApplicable }
}

public enum RemoteTransferMetadataPolicy: Equatable, Sendable {
    case notApplicable, preserveSupportedPermissions
}

public enum RemoteTransferSymlinkPolicy: Equatable, Sendable {
    case rejectTransfer, operateOnLinkIdentity
}

public enum RemoteTransferRecursivePolicy: Equatable, Sendable {
    case none
    case bounded(maximumItems: Int, maximumDepth: Int, maximumPendingDirectories: Int)

    public static func validatedBounded(
        maximumItems: Int,
        maximumDepth: Int,
        maximumPendingDirectories: Int
    ) throws -> Self {
        guard maximumItems >= 0,
              maximumItems <= RemoteTransferBounds.maximumTopLevelRequestedItemsPerJob,
              maximumDepth >= 0,
              maximumDepth <= RemoteTransferBounds.maximumRecursiveDepth,
              maximumPendingDirectories >= 0,
              maximumPendingDirectories <= RemoteTransferBounds.maximumPendingDirectories else {
            throw RemoteFileError(category: .limitExceeded)
        }
        return .bounded(
            maximumItems: maximumItems,
            maximumDepth: maximumDepth,
            maximumPendingDirectories: maximumPendingDirectories
        )
    }

    func validateBounds() throws {
        if case let .bounded(maximumItems, maximumDepth, maximumPendingDirectories) = self {
            _ = try Self.validatedBounded(
                maximumItems: maximumItems,
                maximumDepth: maximumDepth,
                maximumPendingDirectories: maximumPendingDirectories
            )
        }
    }

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

public enum RemoteTransferCrossRuntimePolicy: Equatable, Sendable {
    case sameRuntimeOnly
    case destinationOwnedCopy(sourceOwner: RemoteTransferOwnerIdentity)
}

public struct RemoteTransferRequest: Equatable, Sendable {
    public let id: UUID
    public let owner: RemoteTransferOwnerIdentity
    public let kind: RemoteTransferJobKind
    public let requestedItems: [RemoteTransferRequestedItem]
    public let destination: RemoteTransferDestination
    public let collisionPolicy: RemoteTransferCollisionPolicy
    public let metadataPolicy: RemoteTransferMetadataPolicy
    public let symlinkPolicy: RemoteTransferSymlinkPolicy
    public let recursivePolicy: RemoteTransferRecursivePolicy
    public let crossRuntimePolicy: RemoteTransferCrossRuntimePolicy
    public let retainedByteCount: Int

    public var logicalItemKeys: [RemoteTransferLogicalItemKey] {
        requestedItems.map(\.logicalKey)
    }

    public init(
        id: UUID,
        owner: RemoteTransferOwnerIdentity,
        kind: RemoteTransferJobKind,
        requestedItems: [RemoteTransferRequestedItem],
        destination: RemoteTransferDestination,
        collisionPolicy: RemoteTransferCollisionPolicy,
        metadataPolicy: RemoteTransferMetadataPolicy,
        symlinkPolicy: RemoteTransferSymlinkPolicy,
        recursivePolicy: RemoteTransferRecursivePolicy,
        crossRuntimePolicy: RemoteTransferCrossRuntimePolicy
    ) throws {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.requestedItems = requestedItems
        self.destination = destination
        self.collisionPolicy = collisionPolicy
        self.metadataPolicy = metadataPolicy
        self.symlinkPolicy = symlinkPolicy
        self.recursivePolicy = recursivePolicy
        self.crossRuntimePolicy = crossRuntimePolicy
        retainedByteCount = try Self.retainedByteCount(
            requestedItems: requestedItems,
            destination: destination
        )
        try validate()
    }

    init(logicalItemKeys: [RemoteTransferLogicalItemKey]) {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let endpoint = RemoteTransferEndpointSnapshot.packageCompatibility(owner: owner)
        self.id = UUID()
        self.owner = owner
        self.kind = .download
        self.requestedItems = logicalItemKeys.map {
            RemoteTransferRequestedItem(
                logicalKey: $0,
                source: .remote(endpoint: endpoint, path: .root)
            )
        }
        self.destination = .localDirectory(
            RemoteTransferLocalFileIdentity.packageCompatibilityDirectory()
        )
        self.collisionPolicy = .ask
        self.metadataPolicy = .preserveSupportedPermissions
        self.symlinkPolicy = .rejectTransfer
        self.recursivePolicy = .none
        self.crossRuntimePolicy = .sameRuntimeOnly
        self.retainedByteCount = 0
    }

    private static func retainedByteCount(
        requestedItems: [RemoteTransferRequestedItem],
        destination: RemoteTransferDestination
    ) throws -> Int {
        let destinationEndpoints = destination.remoteEndpoint.map { [$0] } ?? []
        let remoteEndpoints = requestedItems.compactMap { $0.source.remoteEndpoint }
            + destinationEndpoints
        let uniqueEndpoints = Dictionary(
            grouping: remoteEndpoints,
            by: \.id
        ).values.compactMap(\.first)
        let endpointBytes = try uniqueEndpoints.reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1.retainedByteCount)
        }
        let sourceBytes = try requestedItems.reduce(0) { partial, item in
            try RemoteTransferAggregateCounts.checkedSum(
                partial,
                item.source.checkedRetainedByteCountExcludingEndpoint()
            )
        }
        let total = try [
            endpointBytes,
            sourceBytes,
            destination.checkedRetainedByteCountExcludingEndpoint()
        ].reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1)
        }
        guard total <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        return total
    }

    private func validate() throws {
        try recursivePolicy.validateBounds()
        guard !requestedItems.isEmpty else { throw RemoteFileError(category: .invalidOperation) }
        guard requestedItems.count <= RemoteTransferBounds.maximumTopLevelRequestedItemsPerJob else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard Set(logicalItemKeys).count == requestedItems.count else {
            throw RemoteFileError(category: .invalidOperation)
        }
        try validateSingleSourceEndpoint()
        if case let .bounded(maximumItems, _, _) = recursivePolicy,
           maximumItems < requestedItems.count {
            throw RemoteFileError(category: .limitExceeded)
        }

        switch kind {
        case .upload: try validateUpload()
        case .download: try validateDownload()
        case .remoteCopy: try validateRemoteCopy()
        case .remoteMove: try validateRemoteMove()
        case .delete: try validateDelete()
        case .createFile, .createDirectory: try validateCreate()
        case .rename: try validateRename()
        }
    }

    private func validateUpload() throws {
        guard requestedItems.allSatisfy(\.source.isLocal),
              case let .remoteDirectory(endpoint, _) = destination,
              endpoint.owner == owner,
              collisionPolicy.isExplicit,
              metadataPolicy == .preserveSupportedPermissions,
              crossRuntimePolicy == .sameRuntimeOnly,
              symlinkPolicy == .rejectTransfer else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func validateDownload() throws {
        guard requestedItems.allSatisfy({ $0.source.remoteEndpoint?.owner == owner }),
              case let .localDirectory(localDirectory) = destination,
              localDirectory.kind == .directory,
              collisionPolicy.isExplicit,
              metadataPolicy == .preserveSupportedPermissions,
              crossRuntimePolicy == .sameRuntimeOnly,
              symlinkPolicy == .rejectTransfer else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func validateRemoteCopy() throws {
        guard requestedItems.allSatisfy(\.source.isRemote),
              case let .remoteDirectory(destinationEndpoint, _) = destination,
              destinationEndpoint.owner == owner,
              collisionPolicy.isExplicit,
              metadataPolicy == .preserveSupportedPermissions,
              symlinkPolicy == .rejectTransfer else {
            throw RemoteFileError(category: .invalidOperation)
        }
        switch crossRuntimePolicy {
        case .sameRuntimeOnly:
            guard requestedItems.allSatisfy({ $0.source.remoteEndpoint?.owner == owner }),
                  requestedItems.first?.source.remoteEndpoint == destinationEndpoint else {
                throw RemoteFileError(category: .invalidOperation)
            }
        case let .destinationOwnedCopy(sourceOwner):
            guard requestedItems.allSatisfy({ $0.source.remoteEndpoint?.owner == sourceOwner }),
                  sourceOwner != owner else {
                throw RemoteFileError(category: .invalidOperation)
            }
        }
    }

    private func validateRemoteMove() throws {
        guard requestedItems.allSatisfy({ $0.source.remoteEndpoint?.owner == owner }),
              case let .remoteDirectory(endpoint, _) = destination,
              endpoint.owner == owner,
              requestedItems.first?.source.remoteEndpoint == endpoint,
              collisionPolicy.isExplicit,
              metadataPolicy == .notApplicable,
              crossRuntimePolicy == .sameRuntimeOnly,
              symlinkPolicy == .operateOnLinkIdentity,
              recursivePolicy.isNone else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func validateDelete() throws {
        guard requestedItems.allSatisfy({ $0.source.remoteEndpoint?.owner == owner }),
              destination == .none,
              collisionPolicy == .notApplicable,
              metadataPolicy == .notApplicable,
              crossRuntimePolicy == .sameRuntimeOnly,
              symlinkPolicy == .operateOnLinkIdentity else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func validateCreate() throws {
        guard requestedItems.count == 1,
              requestedItems.allSatisfy({ $0.source.remoteEndpoint?.owner == owner }),
              destination == .none,
              collisionPolicy == .ask,
              metadataPolicy == .notApplicable,
              recursivePolicy.isNone,
              crossRuntimePolicy == .sameRuntimeOnly,
              symlinkPolicy == .rejectTransfer else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func validateRename() throws {
        guard requestedItems.count == 1,
              case let .remote(sourceEndpoint, _) = requestedItems[0].source,
              case let .remotePath(destinationEndpoint, _) = destination,
              sourceEndpoint.owner == owner,
              destinationEndpoint.owner == owner,
              sourceEndpoint == destinationEndpoint,
              collisionPolicy.isExplicit,
              metadataPolicy == .notApplicable,
              recursivePolicy.isNone,
              crossRuntimePolicy == .sameRuntimeOnly,
              symlinkPolicy == .operateOnLinkIdentity else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func validateSingleSourceEndpoint() throws {
        let endpointIDs = Set(requestedItems.compactMap { $0.source.remoteEndpoint?.id })
        guard endpointIDs.count <= 1 else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }
}

private extension RemoteTransferItemSource {
    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var isRemote: Bool { remoteEndpoint != nil }
}

private struct PackageCompatibilityTransferMaterial: RemoteTransferTrustedConnectionMaterial {
    let retainedByteCount = 0
}

private extension RemoteTransferEndpointSnapshot {
    static func packageCompatibility(owner: RemoteTransferOwnerIdentity) -> Self {
        Self(
            uncheckedID: UUID(),
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText(unchecked: "Package test"),
                kind: .packageTest
            ),
            trustedConnectionMaterial: PackageCompatibilityTransferMaterial()
        )
    }

    init(
        uncheckedID id: UUID,
        owner: RemoteTransferOwnerIdentity,
        summary: RemoteTransferEndpointSummary,
            trustedConnectionMaterial: any RemoteTransferTrustedConnectionMaterial
    ) {
        self.id = id
        self.owner = owner
        self.summary = summary
        self.trustedConnectionMaterial = trustedConnectionMaterial
        self.storedRetainedByteCount = summary.displayName.value.utf8.count
    }
}

private extension RemoteTransferLocalFileIdentity {
    static func packageCompatibilityDirectory() -> Self {
        Self(
            uncheckedURL: URL(fileURLWithPath: "/tmp"),
            fileResourceIdentifier: Data(),
            volumeIdentifier: nil,
            kind: .directory,
            observedSize: nil,
            observedModificationNanoseconds: nil,
            securityScopedBookmark: nil
        )
    }

    init(
        uncheckedURL url: URL,
        fileResourceIdentifier: Data,
        volumeIdentifier: Data?,
        kind: RemoteTransferLocalItemKind,
        observedSize: UInt64?,
        observedModificationNanoseconds: Int64?,
        securityScopedBookmark: Data?
    ) {
        self.url = url
        self.fileResourceIdentifier = fileResourceIdentifier
        self.volumeIdentifier = volumeIdentifier
        self.kind = kind
        self.observedSize = observedSize
        self.observedModificationNanoseconds = observedModificationNanoseconds
        self.securityScopedBookmark = securityScopedBookmark
        self.storedRetainedByteCount = url.path(percentEncoded: false).utf8.count
    }
}
