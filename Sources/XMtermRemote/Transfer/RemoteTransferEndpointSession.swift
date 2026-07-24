import Foundation

package actor RemoteTransferEndpointSession {
    private let providers: [UUID: any RemoteTransferEndpointProvider]
    private var isSettled = false

    package init(providers: [UUID: any RemoteTransferEndpointProvider]) {
        self.providers = providers
    }

    package func provider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) throws -> any RemoteTransferEndpointProvider {
        guard !isSettled, let provider = providers[endpoint.id] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return provider
    }

    package func settle() async {
        guard !isSettled else { return }
        isSettled = true
        for provider in providers.values {
            await provider.cancelAll()
            await provider.close()
        }
    }
}
