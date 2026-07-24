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

public protocol RemoteTransferEndpointProvider: RemoteFileMutationProvider {
    /// Returns exactly the immediate children reported for `path`. Providers do
    /// not recurse; bounded traversal belongs to the transfer worker.
    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing
    func openFileForReading(_ path: RemotePath) async throws -> any RemoteReadableFile
    /// Exclusively creates a new staging file. It never opens, truncates, or
    /// appends to an existing destination.
    func openFileForWriting(_ path: RemotePath) async throws -> any RemoteWritableFile
    func cancelAll() async
    func close() async
}

public protocol RemoteTransferEndpointProviderFactory: Sendable {
    /// Creates a fresh provider/channel from one immutable execution snapshot.
    func makeProvider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) async throws -> any RemoteTransferEndpointProvider
}

@available(*, deprecated, renamed: "RemoteTransferEndpointProvider")
public typealias RemoteFileTransferProvider = RemoteTransferEndpointProvider

package struct UnavailableRemoteTransferWorkerFactory: RemoteTransferWorkerFactory {
    package init() {}

    package func makeWorker(
        for context: RemoteTransferWorkerContext
    ) async throws -> any RemoteTransferWorker {
        throw RemoteFileError(
            category: .transportUnavailable,
            userFacingMessage: "Remote transfer execution is not available until the reviewed streaming workers are installed."
        )
    }
}

package struct InMemoryRemoteTransferEndpointProviderFactory:
    RemoteTransferEndpointProviderFactory
{
    package typealias ProviderBuilder = @Sendable () throws -> InMemoryRemoteFileProvider

    private let providerBuilder: ProviderBuilder
    private let factoryID: UUID

    package init(providerBuilder: @escaping ProviderBuilder) {
        self.providerBuilder = providerBuilder
        self.factoryID = UUID()
    }

    package func endpointSnapshot(
        owner: RemoteTransferOwnerIdentity,
        displayName: String,
        id: UUID = UUID()
    ) throws -> RemoteTransferEndpointSnapshot {
        try RemoteTransferEndpointSnapshot(
            id: id,
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText(displayName),
                kind: .simulated
            ),
            trustedConnectionMaterial: InMemoryRemoteTransferTrustedConnectionMaterial(
                factoryID: factoryID
            )
        )
    }

    package func makeProvider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) async throws -> any RemoteTransferEndpointProvider {
        guard endpoint.summary.kind == .simulated,
              let material = endpoint.trustedConnectionMaterial
                as? InMemoryRemoteTransferTrustedConnectionMaterial,
              material.factoryID == factoryID else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return try providerBuilder()
    }
}

private struct InMemoryRemoteTransferTrustedConnectionMaterial:
    RemoteTransferTrustedConnectionMaterial
{
    let factoryID: UUID
    let retainedByteCount = MemoryLayout<UUID>.size
}
