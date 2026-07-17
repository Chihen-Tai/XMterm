public protocol RemoteFileProvider: Sendable {
    func resolveInitialDirectory() async throws -> RemotePath
    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing
    func cancelAll() async
    func close() async
}
