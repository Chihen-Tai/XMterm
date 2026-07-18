import Testing
import XMtermCore
import XMtermRemote
@testable import XMtermApp

@Suite("Production Remote Workspace composition")
struct RemoteWorkspaceProductionCompositionTests {
    private let relay: SSHSessionProfile = .direct(
        host: "140.109.226.155",
        port: 54_426,
        user: "allen921103",
        identityFilePath: nil
    )

    @Test("[SESS-011, FILE-WORKSPACE-001] default SSH composition is the concrete production provider")
    func defaultSSHCompositionIsProduction() {
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: relay,
            environment: [:],
            isDeveloperBuild: true
        )

        #expect(composition.mode == .production)
        #expect(composition.provider is OpenSSHSFTPRemoteFileProvider)
    }

    @Test("[FILE-STATE-001] release ignores simulated injection and still uses production")
    func releaseSimulationInjectionFailsClosedToProduction() {
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: relay,
            environment: [
                RemoteWorkspaceDeveloperFixture.environmentKey:
                    RemoteWorkspaceDeveloperFixture.simulatedValue
            ],
            isDeveloperBuild: false
        )

        #expect(composition.mode == .production)
        #expect(composition.provider is OpenSSHSFTPRemoteFileProvider)
    }

    @Test("[FILE-STATE-001] exact debug opt-in remains visibly simulated")
    func debugSimulationRemainsExplicit() {
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: relay,
            environment: [
                RemoteWorkspaceDeveloperFixture.environmentKey:
                    RemoteWorkspaceDeveloperFixture.simulatedValue
            ],
            isDeveloperBuild: true
        )

        #expect(composition.mode == .simulatedDeveloperFixture)
        #expect(composition.provider is InMemoryRemoteFileProvider)
    }

    @Test("[SESS-004, FILE-STATE-001] invalid target fails closed without claiming production")
    func invalidTargetFailsClosed() {
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: .configAlias(alias: "-oUnsafe"),
            environment: [:],
            isDeveloperBuild: false
        )

        #expect(composition.mode == .unavailable)
        #expect(composition.provider is UnavailableRemoteFileProvider)
    }

    @Test("[FILE-STATE-001] production trust constructor accepts only the concrete provider type")
    @MainActor
    func concreteProviderCreatesProductionWorkspace() throws {
        let provider = try OpenSSHSFTPRemoteFileProvider(profile: relay)
        let composition = RemoteProviderComposition.production(provider)
        let workspace = RemoteWorkspace(composition: composition)

        #expect(composition.mode == .production)
        #expect(composition.provider is OpenSSHSFTPRemoteFileProvider)
        #expect(workspace.providerMode == .production)
    }
}
