import Foundation
import Testing
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

    @Test("[FILE-STATE-001] the compile-time developer flag matches this test build configuration")
    func compileTimeDeveloperFlagIsExplicit() {
        // The test target builds in debug configuration; the release
        // warnings-as-errors build compiles the false branch of the same
        // compile-time boundary, so release composition cannot honor the
        // environment value.
        #expect(RemoteWorkspaceDeveloperFixture.isDeveloperBuild)
    }

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
        #expect(workspace.providerMode == .production)

        workspace.start()
        for _ in 0..<300 {
            if workspace.availability == .available { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.availability == .available)
        #expect(workspace.providerMode == .production)

        let unavailableWorkspace = RemoteWorkspace(
            provider: UnavailableRemoteFileProvider(),
            providerMode: .unavailable
        )
        #expect(unavailableWorkspace.providerMode == .unavailable)
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
}
