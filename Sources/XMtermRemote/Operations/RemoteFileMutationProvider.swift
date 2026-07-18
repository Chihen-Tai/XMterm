import Foundation

public struct RemoteFileAttributes: Equatable, Sendable {
    public let kind: RemoteFileEntry.Kind
    public let size: UInt64?
    public let permissions: UInt32?
    public let modificationDate: Date?

    public init(
        kind: RemoteFileEntry.Kind,
        size: UInt64? = nil,
        permissions: UInt32? = nil,
        modificationDate: Date? = nil
    ) {
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }
}

public protocol RemoteFileMutationProvider: RemoteFileCapabilityProvider {
    func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes
    func createFile(_ path: RemotePath) async throws
    func createDirectory(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath, replace: Bool) async throws
    func removeFile(_ path: RemotePath) async throws
    func removeDirectory(_ path: RemotePath) async throws
    func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws
}
