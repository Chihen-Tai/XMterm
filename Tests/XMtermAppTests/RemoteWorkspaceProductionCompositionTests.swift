import Foundation
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
    func defaultSSHCompositionIsProduction() throws {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: relay,
            owner: owner,
            displayName: "Relay fixture",
            environment: [:],
            isDeveloperBuild: true
        )

        #expect(composition.mode == .production)
        #expect(composition.provider is OpenSSHSFTPRemoteFileProvider)
        #expect(composition.transferOwner == owner)
        #expect(composition.transferEndpoint?.owner == owner)
        #expect(composition.transferEndpoint?.summary.kind == .openSSH)
        #expect(composition.transferEndpointProviderFactory != nil)
        #expect(
            composition.transferWorkerFactory
                is RemoteTransferProductionWorkerFactory
        )
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
    func debugSimulationRemainsExplicit() async throws {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: relay,
            owner: owner,
            displayName: "Simulated fixture",
            environment: [
                RemoteWorkspaceDeveloperFixture.environmentKey:
                    RemoteWorkspaceDeveloperFixture.simulatedValue
            ],
            isDeveloperBuild: true
        )

        #expect(composition.mode == .simulatedDeveloperFixture)
        #expect(composition.provider is InMemoryRemoteFileProvider)
        #expect(composition.transferOwner == owner)
        let endpoint = try #require(composition.transferEndpoint)
        let factory = try #require(composition.transferEndpointProviderFactory)
        #expect(endpoint.owner == owner)
        #expect(endpoint.summary.kind == .simulated)
        #expect(
            composition.transferWorkerFactory
                is RemoteTransferProductionWorkerFactory
        )
        let first = try await factory.makeProvider(for: endpoint)
        let second = try await factory.makeProvider(for: endpoint)
        #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
        await first.close()
        await second.close()
    }

    @Test("[SESS-004, FILE-STATE-001] invalid target fails closed without claiming production")
    func invalidTargetFailsClosed() {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let composition = RemoteWorkspaceProductionComposition.composition(
            for: .configAlias(alias: "-oUnsafe"),
            owner: owner,
            environment: [:],
            isDeveloperBuild: false
        )

        #expect(composition.mode == .unavailable)
        #expect(composition.provider is UnavailableRemoteFileProvider)
        #expect(composition.transferOwner == owner)
        #expect(composition.transferEndpoint == nil)
        #expect(composition.transferEndpointProviderFactory == nil)
        #expect(
            composition.transferWorkerFactory
                is UnavailableRemoteTransferWorkerFactory
        )
    }

    @Test("[FILE-STATE-001] production trust constructor supplies the complete transfer endpoint contract")
    @MainActor
    func concreteProviderCreatesProductionWorkspace() throws {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let composition = try RemoteProviderComposition.production(
            profile: relay,
            owner: owner,
            displayName: "Relay"
        )
        let workspace = RemoteWorkspace(composition: composition)

        #expect(composition.mode == .production)
        #expect(composition.provider is OpenSSHSFTPRemoteFileProvider)
        #expect(composition.transferOwner == owner)
        #expect(composition.transferEndpoint != nil)
        #expect(composition.transferEndpointProviderFactory != nil)
        #expect(
            composition.transferWorkerFactory
                is RemoteTransferProductionWorkerFactory
        )
        #expect(workspace.providerMode == .production)
    }
}
