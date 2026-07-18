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

    private init(
        provider: any RemoteFileProvider,
        mode: RemoteProviderMode
    ) {
        self.provider = provider
        self.mode = mode
    }

    package static func packageTest(
        _ provider: any RemoteFileProvider
    ) -> RemoteProviderComposition {
        RemoteProviderComposition(provider: provider, mode: .packageTest)
    }

    public static func unavailable() -> RemoteProviderComposition {
        RemoteProviderComposition(
            provider: UnavailableRemoteFileProvider(),
            mode: .unavailable
        )
    }

    /// The production trust claim is available only for the concrete reviewed
    /// OpenSSH/SFTP provider; arbitrary protocol conformers cannot acquire it.
    public static func production(
        _ provider: OpenSSHSFTPRemoteFileProvider
    ) -> RemoteProviderComposition {
        RemoteProviderComposition(provider: provider, mode: .production)
    }

    package static func simulatedDeveloperFixture(
        _ provider: InMemoryRemoteFileProvider
    ) -> RemoteProviderComposition {
        RemoteProviderComposition(
            provider: provider,
            mode: .simulatedDeveloperFixture
        )
    }
}
