import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote transfer endpoint provider contract")
struct RemoteTransferEndpointProviderContractTests {
    @Test("[FILE-PERF-001, FILE-XFER-004] endpoint provider lists exactly one structured directory")
    func structuredOneDirectoryListingIsPartOfTheEndpointContract() async throws {
        let root = try endpointTestPath("/workspace")
        let child = try RemoteFileEntry(
            path: endpointTestPath("/workspace/file.txt"),
            kind: .regular,
            size: 4
        )
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: [root: .init(entries: [child])],
            fileContents: [child.path: Data("data".utf8)]
        )
        let endpointProvider: any RemoteTransferEndpointProvider = provider

        let listing = try await endpointProvider.listDirectory(root)
        let attributes = try await endpointProvider.lstat(child.path)
        let reader = try await endpointProvider.openFileForReading(child.path)

        #expect(listing.directory == root)
        #expect(listing.entries == [child])
        #expect(attributes.kind == .regular)
        #expect(try await reader.read(maximumBytes: 64) == Data("data".utf8))
        try await reader.close()
        await endpointProvider.close()
    }
}

@Suite("Remote transfer endpoint provider factory")
struct RemoteTransferEndpointProviderFactoryTests {
    @Test("[SESS-006, SESS-011] in-memory factory returns fresh providers over shared fixture storage")
    func inMemoryFactoryCreatesDistinctProvidersSharingMutations() async throws {
        let root = try endpointTestPath("/workspace")
        let created = try endpointTestPath("/workspace/new.txt")
        let directoryGraph: [RemotePath: InMemoryRemoteFileProvider.Directory] = [
            root: .init(entries: [])
        ]
        let factory = InMemoryRemoteTransferEndpointProviderFactory {
            InMemoryRemoteFileProvider(
                initialDirectory: root,
                directoryGraph: directoryGraph
            )
        }
        let endpoint = try factory.endpointSnapshot(
            owner: owner(
                runtime: "55555555-5555-5555-5555-555555555555",
                workspace: "66666666-6666-6666-6666-666666666666"
            ),
            displayName: "Shared fixture"
        )

        let first = try await factory.makeProvider(for: endpoint)
        let second = try await factory.makeProvider(for: endpoint)

        #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
        try await first.createFile(created)
        let secondListing = try await second.listDirectory(root)
        #expect(secondListing.entries.map(\.path) == [created])

        await first.close()
        await second.close()
    }

    @Test("[SESS-011, FILE-XFER-004] in-memory provider close and cancel state stays channel-local")
    func inMemoryProviderCloseAndCancelDoNotPoisonSiblingProvider() async throws {
        let root = try endpointTestPath("/workspace")
        let createdBeforeClose = try endpointTestPath("/workspace/created-before-close.txt")
        let createdAfterClose = try endpointTestPath("/workspace/created-after-close.txt")
        let directoryGraph: [RemotePath: InMemoryRemoteFileProvider.Directory] = [
            root: .init(entries: [])
        ]
        let factory = InMemoryRemoteTransferEndpointProviderFactory {
            InMemoryRemoteFileProvider(
                initialDirectory: root,
                directoryGraph: directoryGraph,
                latency: .milliseconds(100)
            )
        }
        let endpoint = try factory.endpointSnapshot(
            owner: owner(
                runtime: "77777777-7777-7777-7777-777777777777",
                workspace: "88888888-8888-8888-8888-888888888888"
            ),
            displayName: "Shared fixture"
        )

        let first = try await factory.makeProvider(for: endpoint)
        let second = try await factory.makeProvider(for: endpoint)

        try await first.createFile(createdBeforeClose)
        await first.cancelAll()
        await first.close()
        try await second.createFile(createdAfterClose)
        let listing = try await second.listDirectory(root)

        #expect(Set(listing.entries.map(\.path)) == [createdBeforeClose, createdAfterClose])
        await second.close()
    }

    @Test("[SESS-004, SESS-006] OpenSSH factory accepts only its trusted immutable material")
    func openSSHFactoryRejectsUntrustedAndMismatchedEndpoints() async throws {
        let owner = owner(
            runtime: "11111111-1111-1111-1111-111111111111",
            workspace: "22222222-2222-2222-2222-222222222222"
        )
        let profile: SSHSessionProfile = .configAlias(alias: "fixture-host")
        let trusted = try OpenSSHSFTPTransferProviderFactory.endpointSnapshot(
            profile: profile,
            owner: owner,
            displayName: "Fixture SSH"
        )
        let factory = OpenSSHSFTPTransferProviderFactory()
        let provider = try await factory.makeProvider(for: trusted)
        #expect(provider is OpenSSHSFTPRemoteFileProvider)
        await provider.close()

        let fake = try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: owner,
            summary: .init(
                displayName: RemoteTransferPresentationText("Untrusted"),
                kind: .openSSH
            ),
            trustedConnectionMaterial: EndpointFactoryTestMaterial()
        )
        await #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try await factory.makeProvider(for: fake)
        }

        let wrongKind = try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: owner,
            summary: .init(
                displayName: RemoteTransferPresentationText("Wrong kind"),
                kind: .packageTest
            ),
            trustedConnectionMaterial: OpenSSHRemoteTransferTrustedConnectionMaterial(
                profile: profile
            )
        )
        await #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try await factory.makeProvider(for: wrongKind)
        }
    }

    @Test("[SESS-006, SESS-011] each OpenSSH factory call creates a fresh endpoint channel")
    func openSSHFactoryCreatesDistinctProviders() async throws {
        let owner = owner(
            runtime: "33333333-3333-3333-3333-333333333333",
            workspace: "44444444-4444-4444-4444-444444444444"
        )
        let endpoint = try OpenSSHSFTPTransferProviderFactory.endpointSnapshot(
            profile: .configAlias(alias: "fixture-host"),
            owner: owner,
            displayName: "Fixture SSH"
        )
        let factory = OpenSSHSFTPTransferProviderFactory()

        let first = try await factory.makeProvider(for: endpoint)
        let second = try await factory.makeProvider(for: endpoint)

        #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
        await first.close()
        await second.close()
    }

    @Test("[APP-008] OpenSSH material retains the profile value and structurally accounts its bytes")
    func openSSHMaterialIsImmutableAndStructurallyBounded() throws {
        let profile: SSHSessionProfile = .direct(
            host: "example.test",
            port: 22,
            user: "alice",
            identityFilePath: "/Users/alice/.ssh/id_fixture"
        )
        let material = try OpenSSHRemoteTransferTrustedConnectionMaterial(profile: profile)

        #expect(material.profile == profile)
        #expect(
            material.retainedByteCount
                == "example.test".utf8.count
                + "alice".utf8.count
                + "/Users/alice/.ssh/id_fixture".utf8.count
        )
    }

    private func owner(runtime: String, workspace: String) -> RemoteTransferOwnerIdentity {
        RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(rawValue: UUID(uuidString: runtime)!),
            workspaceID: RemoteWorkspaceID(rawValue: UUID(uuidString: workspace)!)
        )
    }
}

private struct EndpointFactoryTestMaterial: RemoteTransferTrustedConnectionMaterial {
    let retainedByteCount = 0
}

private func endpointTestPath(_ value: String) throws -> RemotePath {
    try RemotePath(rawBytes: Array(value.utf8))
}
