import XMtermCore

public struct OpenSSHSFTPTransferProviderFactory: RemoteTransferProviderFactory {
    private let profile: SSHSessionProfile

    public init(profile: SSHSessionProfile) {
        self.profile = profile
    }

    public func makeProvider() async throws -> any RemoteFileTransferProvider {
        try OpenSSHSFTPRemoteFileProvider(profile: profile)
    }
}
