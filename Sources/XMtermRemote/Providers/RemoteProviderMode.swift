import XMtermCore

/// Trusted, composition-assigned classification of a workspace's provider.
///
/// The mode is set only by the trusted composition boundary when it constructs a
/// workspace. It is never derived from provider responses, capability-note text,
/// directory names, or any other remote-controlled value, so an arbitrary
/// provider cannot claim or discard the simulated-developer presentation.
public enum RemoteProviderMode: Equatable, Hashable, Sendable {
    /// A real transport provider. None ships until ADR 0007 is accepted.
    case production
    /// The honest shipping provider that reports transport unavailability.
    case unavailable
    /// The explicit opt-in deterministic in-memory developer fixture.
    case simulatedDeveloperFixture
    /// Package-only deterministic providers used by tests. App composition
    /// never constructs this mode, and it carries no production trust claim.
    case packageTest
}

/// Provider plus its trusted composition-assigned mode.
///
/// The raw pairing is private so callers cannot accidentally combine an
/// arbitrary provider with the simulated or unavailable presentation modes.
public struct RemoteProviderComposition: Sendable {
    package let provider: any RemoteFileProvider
    package let mode: RemoteProviderMode
    package let transferOwner: RemoteTransferOwnerIdentity
    package let transferEndpoint: RemoteTransferEndpointSnapshot?
    package let transferEndpointProviderFactory:
        (any RemoteTransferEndpointProviderFactory)?
    package let transferWorkerFactory: any RemoteTransferWorkerFactory

    private init(
        provider: any RemoteFileProvider,
        mode: RemoteProviderMode,
        transferOwner: RemoteTransferOwnerIdentity,
        transferEndpoint: RemoteTransferEndpointSnapshot?,
        transferEndpointProviderFactory: (any RemoteTransferEndpointProviderFactory)?,
        transferWorkerFactory: any RemoteTransferWorkerFactory
    ) {
        self.provider = provider
        self.mode = mode
        self.transferOwner = transferOwner
        self.transferEndpoint = transferEndpoint
        self.transferEndpointProviderFactory = transferEndpointProviderFactory
        self.transferWorkerFactory = transferWorkerFactory
    }

    package static func packageTest(
        _ provider: any RemoteFileProvider,
        owner: RemoteTransferOwnerIdentity,
        workerFactory: any RemoteTransferWorkerFactory = UnavailableRemoteTransferWorkerFactory()
    ) -> RemoteProviderComposition {
        RemoteProviderComposition(
            provider: provider,
            mode: .packageTest,
            transferOwner: owner,
            transferEndpoint: nil,
            transferEndpointProviderFactory: nil,
            transferWorkerFactory: workerFactory
        )
    }

    public static func unavailable() -> RemoteProviderComposition {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        return unavailable(owner: owner)
    }

    public static func unavailable(
        owner: RemoteTransferOwnerIdentity
    ) -> RemoteProviderComposition {
        RemoteProviderComposition(
            provider: UnavailableRemoteFileProvider(),
            mode: .unavailable,
            transferOwner: owner,
            transferEndpoint: nil,
            transferEndpointProviderFactory: nil,
            transferWorkerFactory: UnavailableRemoteTransferWorkerFactory()
        )
    }

    package static func production(
        profile: SSHSessionProfile,
        owner: RemoteTransferOwnerIdentity,
        displayName: String
    ) throws -> RemoteProviderComposition {
        let provider = try OpenSSHSFTPRemoteFileProvider(profile: profile)
        let endpointProviderFactory = OpenSSHSFTPTransferProviderFactory()
        let endpoint = try OpenSSHSFTPTransferProviderFactory.endpointSnapshot(
            profile: profile,
            owner: owner,
            displayName: displayName
        )
        return RemoteProviderComposition(
            provider: provider,
            mode: .production,
            transferOwner: owner,
            transferEndpoint: endpoint,
            transferEndpointProviderFactory: endpointProviderFactory,
            transferWorkerFactory: RemoteTransferProductionWorkerFactory(
                endpointProviderFactory: endpointProviderFactory,
                localStaging: DarwinLocalTransferStaging()
            )
        )
    }

    package static func simulatedDeveloperFixture(
        _ provider: InMemoryRemoteFileProvider,
        owner: RemoteTransferOwnerIdentity,
        endpointProviderFactory: InMemoryRemoteTransferEndpointProviderFactory,
        displayName: String
    ) throws -> RemoteProviderComposition {
        let endpoint = try endpointProviderFactory.endpointSnapshot(
            owner: owner,
            displayName: displayName
        )
        return RemoteProviderComposition(
            provider: provider,
            mode: .simulatedDeveloperFixture,
            transferOwner: owner,
            transferEndpoint: endpoint,
            transferEndpointProviderFactory: endpointProviderFactory,
            transferWorkerFactory: RemoteTransferProductionWorkerFactory(
                endpointProviderFactory: endpointProviderFactory,
                localStaging: DarwinLocalTransferStaging()
            )
        )
    }
}
