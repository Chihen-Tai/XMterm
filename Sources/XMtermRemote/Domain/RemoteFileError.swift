public struct RemoteFileError: Error, Equatable, Sendable {
    public static let maximumUserFacingMessageByteCount = 64 * 1_024

    public enum Category: CaseIterable, Equatable, Hashable, Sendable {
        case authenticationRequired
        case permissionDenied
        case pathNotFound
        case notDirectory
        case disconnected
        case connectionRefused
        case timeout
        case cancelled
        case malformedResponse
        case unsupportedEntry
        case limitExceeded
        case transportUnavailable
        case providerFailure
        case unknown

        fileprivate var defaultUserFacingMessage: String {
            switch self {
            case .authenticationRequired: "Authentication is required."
            case .permissionDenied: "Permission was denied."
            case .pathNotFound: "The remote path was not found."
            case .notDirectory: "The remote path is not a directory."
            case .disconnected: "The remote connection was disconnected."
            case .connectionRefused: "The remote connection was refused."
            case .timeout: "The remote operation timed out."
            case .cancelled: "The remote operation was cancelled."
            case .malformedResponse: "The remote service returned a malformed response."
            case .unsupportedEntry: "The remote entry is unsupported."
            case .limitExceeded: "The remote response exceeded a safety limit."
            case .transportUnavailable: "Remote file transport is unavailable."
            case .providerFailure: "The remote file provider failed."
            case .unknown: "An unknown remote file error occurred."
            }
        }
    }

    public let category: Category
    public let userFacingMessage: String

    public init(
        category: Category,
        userFacingMessage: String? = nil
    ) {
        self.category = category
        self.userFacingMessage = RemoteUserFacingText.bounded(
            userFacingMessage ?? category.defaultUserFacingMessage,
            maximumByteCount: Self.maximumUserFacingMessageByteCount
        )
    }
}

enum RemoteUserFacingText {
    static func bounded(_ value: String, maximumByteCount: Int) -> String {
        RemoteUnicodeSafety.escaped(
            Array(value.unicodeScalars),
            maximumByteCount: maximumByteCount
        )
    }
}
