import Foundation

public struct RemoteFileCapabilities: Equatable, Sendable {
    public let canList: Bool
    public let canMutate: Bool
    public let canTransfer: Bool
    /// The capability observed on the provider's current completed SFTP
    /// handshake. Callers must still recheck it on the operation path because a
    /// replacement channel may advertise a different extension set.
    public let supportsAtomicReplace: Bool

    public init(
        canList: Bool,
        canMutate: Bool,
        canTransfer: Bool,
        supportsAtomicReplace: Bool
    ) {
        self.canList = canList
        self.canMutate = canMutate
        self.canTransfer = canTransfer
        self.supportsAtomicReplace = supportsAtomicReplace
    }

    public static let unavailable = Self(
        canList: false,
        canMutate: false,
        canTransfer: false,
        supportsAtomicReplace: false
    )

    public static let readOnly = Self(
        canList: true,
        canMutate: false,
        canTransfer: false,
        supportsAtomicReplace: false
    )
}

public protocol RemoteFileCapabilityProvider: Sendable {
    var capabilities: RemoteFileCapabilities { get async }
}
