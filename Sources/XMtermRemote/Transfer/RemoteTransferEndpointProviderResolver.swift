import Foundation

package struct RemoteTransferEndpointProviderResolver: Sendable {
    private let factory: any RemoteTransferEndpointProviderFactory

    package init(factory: any RemoteTransferEndpointProviderFactory) {
        self.factory = factory
    }

    package func acquire(
        for request: RemoteTransferRequest
    ) async throws -> RemoteTransferEndpointSession {
        let endpoints = try Self.uniqueEndpoints(in: request)
        var providers: [UUID: any RemoteTransferEndpointProvider] = [:]
        do {
            for endpoint in endpoints {
                providers[endpoint.id] = try await factory.makeProvider(for: endpoint)
            }
            return RemoteTransferEndpointSession(providers: providers)
        } catch {
            for provider in providers.values {
                await provider.cancelAll()
                await provider.close()
            }
            throw error
        }
    }

    private static func uniqueEndpoints(
        in request: RemoteTransferRequest
    ) throws -> [RemoteTransferEndpointSnapshot] {
        let sources = request.requestedItems.compactMap { $0.source.remoteEndpoint }
        let destination = request.destination.remoteEndpoint.map { [$0] } ?? []
        var seen: Set<UUID> = []
        let endpoints = (sources + destination).filter { seen.insert($0.id).inserted }
        guard !endpoints.isEmpty, endpoints.count <= 2 else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return endpoints
    }
}
