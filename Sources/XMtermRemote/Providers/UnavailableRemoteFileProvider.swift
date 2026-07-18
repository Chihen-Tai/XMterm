public struct UnavailableRemoteFileProvider: RemoteFileProvider, RemoteFileCapabilityProvider {
    public init() {}

    public var capabilities: RemoteFileCapabilities {
        get async { .unavailable }
    }

    public func resolveInitialDirectory() async throws -> RemotePath {
        throw Self.unavailableError
    }

    public func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        throw Self.unavailableError
    }

    public func cancelAll() async {}

    public func close() async {}

    private static let unavailableError = RemoteFileError(
        category: .transportUnavailable,
        userFacingMessage: "Remote files require the reviewed structured OpenSSH SFTP adapter; that transport is not available in this build."
    )
}
