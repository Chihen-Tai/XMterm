import Foundation

enum SFTPRequestType: UInt8, Equatable, Sendable {
    case close = 4
    case openDirectory = 11
    case readDirectory = 12
    case realPath = 16
}

enum SFTPStatusCode: Equatable, Sendable {
    case ok
    case endOfFile
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case noConnection
    case connectionLost
    case operationUnsupported
    case unknown(UInt32)

    init(rawValue: UInt32) {
        self = switch rawValue {
        case 0: .ok
        case 1: .endOfFile
        case 2: .noSuchFile
        case 3: .permissionDenied
        case 4: .failure
        case 5: .badMessage
        case 6: .noConnection
        case 7: .connectionLost
        case 8: .operationUnsupported
        default: .unknown(rawValue)
        }
    }
}

struct SFTPExtension: Equatable, Sendable {
    let name: [UInt8]
    let data: [UInt8]
}

struct SFTPAttributes: Equatable, Sendable {
    static let empty = Self()

    let size: UInt64?
    let userID: UInt32?
    let groupID: UInt32?
    let permissions: UInt32?
    let accessTime: UInt32?
    let modificationTime: UInt32?

    init(
        size: UInt64? = nil,
        userID: UInt32? = nil,
        groupID: UInt32? = nil,
        permissions: UInt32? = nil,
        accessTime: UInt32? = nil,
        modificationTime: UInt32? = nil
    ) {
        self.size = size
        self.userID = userID
        self.groupID = groupID
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }
}

struct SFTPName: Equatable, Sendable {
    let rawFilename: [UInt8]
    let attributes: SFTPAttributes
}

enum SFTPResponse: Equatable, Sendable {
    case version(UInt32, extensions: [SFTPExtension])
    case status(id: UInt32, code: SFTPStatusCode, message: [UInt8], language: [UInt8])
    case handle(id: UInt32, value: [UInt8])
    case names(id: UInt32, values: [SFTPName])
    case attributes(id: UInt32, value: SFTPAttributes)
}

enum SFTPProtocolError: Error, Equatable, Sendable {
    case truncatedLengthPrefix(actual: Int)
    case invalidPacketLength(UInt32)
    case packetTooLarge(maximum: Int, actual: Int)
    case truncatedPacket(expected: Int, actual: Int)
    case trailingPacketBytes(Int)
    case unexpectedPacketType(UInt8)
    case unsupportedVersion(UInt32)
    case requestIDForbiddenForVersion
    case missingExpectedRequestID
    case requestIDMismatch(expected: UInt32, actual: UInt32)
    case truncatedValue(expected: Int, remaining: Int)
    case stringTooLong(maximum: Int, actual: Int)
    case pathTooLong(maximum: Int, actual: Int)
    case handleTooLong(maximum: Int, actual: Int)
    case tooManyNames(maximum: Int, actual: Int)
    case tooManyExtensions(maximum: Int, actual: Int)
    case unsupportedAttributeFlags(UInt32)
    case trailingPayloadBytes(Int)
    case invalidRequestType(UInt8)
    case invalidIntegerConversion
}

struct SFTPCodecLimits: Equatable, Sendable {
    static let production = Self()

    let maximumPacketByteCount: Int
    let maximumPathByteCount: Int
    let maximumFilenameByteCount: Int
    let maximumHandleByteCount: Int
    let maximumNameCount: Int
    let maximumExtensionCount: Int

    init(
        maximumPacketByteCount: Int = 1_024 * 1_024,
        maximumPathByteCount: Int = RemotePath.maximumRawByteCount,
        maximumFilenameByteCount: Int = RemotePathComponent.maximumRawByteCount,
        maximumHandleByteCount: Int = 256,
        maximumNameCount: Int = RemoteDirectoryListing.maximumEntryCount,
        maximumExtensionCount: Int = 256
    ) {
        self.maximumPacketByteCount = maximumPacketByteCount
        self.maximumPathByteCount = maximumPathByteCount
        self.maximumFilenameByteCount = maximumFilenameByteCount
        self.maximumHandleByteCount = maximumHandleByteCount
        self.maximumNameCount = maximumNameCount
        self.maximumExtensionCount = maximumExtensionCount
    }
}
