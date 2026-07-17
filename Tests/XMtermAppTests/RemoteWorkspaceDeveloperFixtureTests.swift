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
        let provider = RemoteWorkspaceDeveloperFixture.provider(environment: [:])
        #expect(provider is UnavailableRemoteFileProvider)
    }

    @Test("[FILE-STATE-001] the explicit environment value opts into the simulated provider")
    func explicitEnvironmentValueEnablesSimulatedProvider() {
        let environment = [
            RemoteWorkspaceDeveloperFixture.environmentKey:
                RemoteWorkspaceDeveloperFixture.simulatedValue
        ]
        #expect(RemoteWorkspaceDeveloperFixture.isEnabled(environment: environment))
        let provider = RemoteWorkspaceDeveloperFixture.provider(environment: environment)
        #expect(provider is InMemoryRemoteFileProvider)
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
