import Foundation

public enum RemoteMetadataCompleteness: Equatable, Hashable, Sendable {
    case complete
    case partial
}

public enum RemoteFileEntryValidationError: Error, Equatable, Sendable {
    case rootCannotBeEntry
    case invalidPermissionBits(UInt16)
    case emptySymbolicLinkTarget
    case symbolicLinkTargetContainsNul
    case symbolicLinkTargetTooLong(maximum: Int, actual: Int)
    case symbolicLinkTargetRequiresSymbolicLinkKind
}

public struct RemoteSymlinkTarget: Equatable, Hashable, Sendable {
    public static let maximumRawByteCount = 32 * 1_024

    private let storage: Data

    public var rawBytes: [UInt8] {
        Array(storage)
    }

    public var losslessString: String? {
        String(data: storage, encoding: .utf8)
    }

    public var escapedDisplayString: String {
        RemoteByteDisplay.escaped(storage)
    }

    public init(rawBytes: [UInt8]) throws {
        guard !rawBytes.isEmpty else {
            throw RemoteFileEntryValidationError.emptySymbolicLinkTarget
        }
        guard rawBytes.count <= Self.maximumRawByteCount else {
            throw RemoteFileEntryValidationError.symbolicLinkTargetTooLong(
                maximum: Self.maximumRawByteCount,
                actual: rawBytes.count
            )
        }
        guard !rawBytes.contains(0x00) else {
            throw RemoteFileEntryValidationError.symbolicLinkTargetContainsNul
        }
        storage = Data(rawBytes)
    }
}

public struct RemoteFileEntry: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: Int, CaseIterable, Equatable, Hashable, Sendable {
        case directory
        case regular
        case symbolicLink
        case other
    }

    public static let maximumPermissionBits: UInt16 = 0o7_777

    public let path: RemotePath
    public let name: RemotePathComponent
    public let kind: Kind
    public let size: UInt64?
    public let modificationDate: Date?
    public let permissions: UInt16?
    public let symbolicLinkTarget: RemoteSymlinkTarget?
    public let metadataCompleteness: RemoteMetadataCompleteness

    public var id: RemotePath {
        path
    }

    public var isHidden: Bool {
        name.rawBytes.first == 0x2E
    }

    public var isExecutable: Bool? {
        permissions.map { ($0 & 0o111) != 0 }
    }

    public init(
        path: RemotePath,
        kind: Kind,
        size: UInt64? = nil,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        symbolicLinkTarget: RemoteSymlinkTarget? = nil,
        metadataCompleteness: RemoteMetadataCompleteness = .partial
    ) throws {
        guard let name = path.lastComponent else {
            throw RemoteFileEntryValidationError.rootCannotBeEntry
        }
        if let permissions, permissions > Self.maximumPermissionBits {
            throw RemoteFileEntryValidationError.invalidPermissionBits(permissions)
        }
        if symbolicLinkTarget != nil, kind != .symbolicLink {
            throw RemoteFileEntryValidationError.symbolicLinkTargetRequiresSymbolicLinkKind
        }

        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.symbolicLinkTarget = symbolicLinkTarget
        self.metadataCompleteness = metadataCompleteness
    }

    public static func defaultOrdering(_ left: Self, _ right: Self) -> Bool {
        if left.kind != right.kind {
            return left.kind.rawValue < right.kind.rawValue
        }
        if left.name.rawBytes != right.name.rawBytes {
            return left.name.rawBytes.lexicographicallyPrecedes(right.name.rawBytes)
        }
        return left.path.rawBytes.lexicographicallyPrecedes(right.path.rawBytes)
    }
}
