/// Trusted, composition-assigned classification of a workspace's provider.
///
/// The mode is set only by the app's own composition code when it constructs a
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
}
