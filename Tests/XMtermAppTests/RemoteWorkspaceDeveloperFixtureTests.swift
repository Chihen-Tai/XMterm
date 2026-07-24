import Foundation
import Testing
import XMtermCore
import XMtermRemote
@testable import XMtermApp

@Suite("Remote workspace developer fixture")
struct RemoteWorkspaceDeveloperFixtureTests {
    @Test("[FILE-STATE-001] shipping composition stays honestly unavailable by default")
    func defaultEnvironmentUsesUnavailableProvider() {
        #expect(!RemoteWorkspaceDeveloperFixture.isEnabled(environment: [:]))
        #expect(
            !RemoteWorkspaceDeveloperFixture.isEnabled(
                environment: [RemoteWorkspaceDeveloperFixture.environmentKey: "1"]
            )
        )

        let defaultComposition = RemoteWorkspaceDeveloperFixture.composition(
            environment: [:],
            isDeveloperBuild: true
        )
        #expect(defaultComposition.provider is UnavailableRemoteFileProvider)
        #expect(defaultComposition.mode == .unavailable)

        let unrelatedComposition = RemoteWorkspaceDeveloperFixture.composition(
            environment: [RemoteWorkspaceDeveloperFixture.environmentKey: "1"],
            isDeveloperBuild: true
        )
        #expect(unrelatedComposition.provider is UnavailableRemoteFileProvider)
        #expect(unrelatedComposition.mode == .unavailable)
    }

    @Test("[FILE-STATE-001] the exact environment value opts into the simulated provider in developer builds")
    func explicitEnvironmentValueEnablesSimulatedProviderInDeveloperBuilds() {
        let environment = [
            RemoteWorkspaceDeveloperFixture.environmentKey:
                RemoteWorkspaceDeveloperFixture.simulatedValue
        ]
        #expect(RemoteWorkspaceDeveloperFixture.isEnabled(environment: environment))

        let composition = RemoteWorkspaceDeveloperFixture.composition(
            environment: environment,
            isDeveloperBuild: true
        )
        #expect(composition.provider is InMemoryRemoteFileProvider)
        #expect(composition.mode == .simulatedDeveloperFixture)
    }

    @Test("[FILE-STATE-001] release composition fails closed even with the exact environment value")
    func releaseCompositionCannotActivateSimulation() {
        let environment = [
            RemoteWorkspaceDeveloperFixture.environmentKey:
                RemoteWorkspaceDeveloperFixture.simulatedValue
        ]

        let composition = RemoteWorkspaceDeveloperFixture.composition(
            environment: environment,
            isDeveloperBuild: false
        )
        #expect(composition.provider is UnavailableRemoteFileProvider)
        #expect(composition.mode == .unavailable)
    }

    #if !DEBUG
    @Test("[FILE-STATE-001] release build default composition fails closed with the exact environment value")
    func releaseBuildDefaultCompositionCannotActivateSimulation() {
        let environment = [
            RemoteWorkspaceDeveloperFixture.environmentKey:
                RemoteWorkspaceDeveloperFixture.simulatedValue
        ]

        let composition = RemoteWorkspaceDeveloperFixture.composition(
            environment: environment
        )
        #expect(composition.provider is UnavailableRemoteFileProvider)
        #expect(composition.mode == .unavailable)
    }
    #endif

    @Test("[FILE-STATE-001] untrusted capability text cannot flip a workspace into simulated mode")
    @MainActor
    func untrustedCapabilityTextCannotCreateSimulatedMode() async throws {
        let work = try RemotePath(rawBytes: Array("/work".utf8))
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: work,
            directoryGraph: [
                work: .init(
                    entries: [],
                    providerCapabilityNotes: "Simulated listing SIMULATED developer fixture"
                )
            ]
        )
        let workspace = RemoteWorkspace(provider: provider)
        #expect(workspace.providerMode == .packageTest)

        workspace.start()
        for _ in 0..<300 {
            if workspace.availability == .available { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.availability == .available)
        #expect(workspace.providerMode == .packageTest)

        let unavailableWorkspace = RemoteWorkspace(
            composition: .unavailable()
        )
        #expect(unavailableWorkspace.providerMode == .unavailable)
    }

    @Test("[FILE-STATE-001] package provider convenience init remains explicitly test-only")
    @MainActor
    func packageProviderConvenienceInitRemainsExplicitlyTestOnly() throws {
        let work = try RemotePath(rawBytes: Array("/work".utf8))
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: work,
            directoryGraph: [work: .init(entries: [])]
        )

        let workspace = RemoteWorkspace(provider: provider)

        #expect(workspace.providerMode == .packageTest)
    }

    @Test("[FILE-STATE-001] typed simulated developer fixture composition is simulated")
    @MainActor
    func typedSimulatedDeveloperFixtureCompositionIsSimulated() throws {
        let provider = try RemoteWorkspaceDeveloperFixture.simulatedProvider()
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let endpointProviderFactory = InMemoryRemoteTransferEndpointProviderFactory {
            try RemoteWorkspaceDeveloperFixture.simulatedProvider()
        }
        let composition = try RemoteProviderComposition.simulatedDeveloperFixture(
            provider,
            owner: owner,
            endpointProviderFactory: endpointProviderFactory,
            displayName: "Simulated fixture"
        )
        #expect(composition.provider is InMemoryRemoteFileProvider)
        #expect(composition.mode == .simulatedDeveloperFixture)
        #expect(composition.transferOwner == owner)
        #expect(composition.transferEndpoint != nil)
        #expect(composition.transferEndpointProviderFactory != nil)

        let workspace = RemoteWorkspace(composition: composition)

        #expect(workspace.providerMode == .simulatedDeveloperFixture)
    }

    @Test("[FILE-STATE-001] typed unavailable composition is unavailable")
    @MainActor
    func typedUnavailableCompositionIsUnavailable() {
        let composition = RemoteProviderComposition.unavailable()
        #expect(composition.provider is UnavailableRemoteFileProvider)
        #expect(composition.mode == .unavailable)

        let workspace = RemoteWorkspace(composition: composition)

        #expect(workspace.providerMode == .unavailable)
    }

    @Test("[FILE-STATE-001, FILE-PERF-001] the simulated graph is deterministic, labeled, and bounded")
    func simulatedGraphIsDeterministicLabeledAndBounded() async throws {
        let provider = try RemoteWorkspaceDeveloperFixture.simulatedProvider()

        let initialDirectory = try await provider.resolveInitialDirectory()
        #expect(initialDirectory.losslessString == "/simulated")

        let initialListing = try await provider.listDirectory(initialDirectory)
        #expect(initialListing.providerCapabilityNotes?.contains("Simulated") == true)
        #expect(!initialListing.entries.isEmpty)

        let largePath = try RemotePath(rawBytes: Array("/simulated/large".utf8))
        let largeListing = try await provider.listDirectory(largePath)
        #expect(largeListing.entries.count == 1_000)
        #expect(largeListing.providerCapabilityNotes?.contains("Simulated") == true)

        let emptyPath = try RemotePath(rawBytes: Array("/simulated/empty".utf8))
        let emptyListing = try await provider.listDirectory(emptyPath)
        #expect(emptyListing.entries.isEmpty)

        let deniedPath = try RemotePath(rawBytes: Array("/simulated/denied".utf8))
        await #expect(throws: RemoteFileError(category: .permissionDenied)) {
            _ = try await provider.listDirectory(deniedPath)
        }

        let secondProvider = try RemoteWorkspaceDeveloperFixture.simulatedProvider()
        let secondInitial = try await secondProvider.resolveInitialDirectory()
        let secondListing = try await secondProvider.listDirectory(secondInitial)
        #expect(secondListing == initialListing)
    }

    @Test("[SESS-011, FILE-XFER-001] simulated workspace worker mutations are visible through the browsing provider")
    func simulatedWorkspaceWorkerMutationSharesBrowsingStorage() async throws {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let environment = [
            RemoteWorkspaceDeveloperFixture.environmentKey:
                RemoteWorkspaceDeveloperFixture.simulatedValue
        ]
        let composition = RemoteWorkspaceDeveloperFixture.composition(
            owner: owner,
            displayName: "Simulated transfer endpoint",
            environment: environment,
            isDeveloperBuild: true
        )
        let endpoint = try #require(composition.transferEndpoint)
        let target = try path("/simulated/home/shared-worker-created.txt")
        let requestedItem = RemoteTransferRequestedItem(
            logicalKey: RemoteTransferLogicalItemKey(),
            source: .remote(endpoint: endpoint, path: target)
        )
        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .createFile,
            requestedItems: [requestedItem],
            destination: .none,
            collisionPolicy: .ask,
            metadataPolicy: .notApplicable,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )
        let context = RemoteTransferWorkerContext(
            request: request,
            attempt: try RemoteTransferAttemptIdentity(id: UUID(), generation: 1),
            items: [
                RemoteTransferAttemptItem(
                    logicalItemKey: requestedItem.logicalKey,
                    attemptItemID: RemoteTransferAttemptItemID()
                )
            ],
            checkpointManifest: .empty,
            resolvedCollision: nil,
            applyToAllResolution: nil,
            requiresDestinationRevalidation: false
        )
        let worker = try await composition.transferWorkerFactory.makeWorker(for: context)

        let outcome = await worker.run { _ in }
        let listing = try await composition.provider.listDirectory(try path("/simulated/home"))

        #expect(outcome.disposition == .completed)
        #expect(listing.entries.map(\.path).contains(target))
    }

    private func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}
