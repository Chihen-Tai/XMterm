import Foundation

public struct RemoteTransferProductionWorkerFactory: RemoteTransferWorkerFactory {
    private let resolver: RemoteTransferEndpointProviderResolver
    private let localStaging: any LocalTransferStaging

    public init(
        endpointProviderFactory: any RemoteTransferEndpointProviderFactory,
        localStaging: any LocalTransferStaging
    ) {
        resolver = RemoteTransferEndpointProviderResolver(factory: endpointProviderFactory)
        self.localStaging = localStaging
    }

    public func makeWorker(
        for context: RemoteTransferWorkerContext
    ) async throws -> any RemoteTransferWorker {
        try RemoteTransferProductionWorker(
            context: context,
            resolver: resolver,
            localStaging: localStaging
        )
    }
}
