enum OpenSSHSFTPFailure: Error, Equatable, Sendable {
    case authenticationRequired
    case hostKeyVerificationFailed
    case interactiveAuthenticationUnsupported
    case permissionDenied
    case pathNotFound
    case unsupportedProtocol
    case cancelled
    case timeout
    case malformedResponse
    case transportUnavailable
    case limitExceeded
    case providerFailure
    case unknown

    var remoteFileError: RemoteFileError {
        RemoteFileError(category: category)
    }

    private var category: RemoteFileError.Category {
        switch self {
        case .authenticationRequired: .authenticationRequired
        case .hostKeyVerificationFailed: .hostKeyVerificationFailed
        case .interactiveAuthenticationUnsupported: .interactiveAuthenticationUnsupported
        case .permissionDenied: .permissionDenied
        case .pathNotFound: .pathNotFound
        case .unsupportedProtocol: .unsupportedProtocol
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .malformedResponse: .malformedResponse
        case .transportUnavailable: .transportUnavailable
        case .limitExceeded: .limitExceeded
        case .providerFailure: .providerFailure
        case .unknown: .unknown
        }
    }
}
