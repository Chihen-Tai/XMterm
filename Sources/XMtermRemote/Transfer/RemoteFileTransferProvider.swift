import Foundation

public enum RemoteFileTransferLimits {
    public static let maximumChunkByteCount = 64 * 1_024
}

public protocol RemoteReadableFile: Sendable {
    /// Returns at most `maximumBytes`, or `nil` after the server reports EOF.
    func read(maximumBytes: Int) async throws -> Data?
    func close() async throws
}

public protocol RemoteWritableFile: Sendable {
    func write(_ data: Data) async throws
    func close() async throws
}

public protocol RemoteFileTransferProvider: RemoteFileMutationProvider {
    func openFileForReading(_ path: RemotePath) async throws -> any RemoteReadableFile
    /// Exclusively creates a new staging file. It never opens, truncates, or
    /// appends to an existing destination.
    func openFileForWriting(_ path: RemotePath) async throws -> any RemoteWritableFile
    func cancelAll() async
    func close() async
}

public protocol RemoteTransferProviderFactory: Sendable {
    func makeProvider() async throws -> any RemoteFileTransferProvider
}
