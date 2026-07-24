import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote transfer production worker contract")
struct RemoteTransferProductionWorkerContractTests {
    @Test("[FILE-XFER-002] Replace defaults to an atomic-only guarantee")
    func replaceDefaultsToAtomicOnly() throws {
        let resolution = try RemoteTransferCollisionResolution(
            decision: .replace,
            applyToAll: false
        )

        #expect(resolution.replacementGuarantee == .atomicOnly)
    }

    @Test("[FILE-XFER-002] Non-atomic acceptance is valid only for Replace")
    func nonAtomicAcceptanceRequiresReplace() {
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try RemoteTransferCollisionResolution(
                decision: .skip,
                applyToAll: false,
                replacementGuarantee: .explicitlyAcceptedNonAtomicFallback
            )
        }
    }

    @Test("[FILE-OPS-003, FILE-XFER-004] create-file uses one immutable endpoint session and commits only after settlement")
    func createFileUsesOneEndpointAndSettlesIt() async throws {
        let fixture = try ProductionWorkerFixture()
        let path = try fixture.path("/workspace/new.txt")
        let context = try fixture.context(
            kind: .createFile,
            sources: [.remote(endpoint: fixture.endpoint, path: path)],
            destination: .none,
            collisionPolicy: .ask,
            metadataPolicy: .notApplicable,
            symlinkPolicy: .rejectTransfer
        )
        let provider = RecordingTransferEndpointProvider()
        let providerFactory = RecordingTransferEndpointProviderFactory(
            providers: [fixture.endpoint.id: provider]
        )
        let factory = RemoteTransferProductionWorkerFactory(
            endpointProviderFactory: providerFactory,
            localStaging: RecordingLocalTransferStaging()
        )

        let worker = try await factory.makeWorker(for: context)
        let outcome = await worker.run { _ in }

        #expect(outcome.disposition == .completed)
        #expect(outcome.completedItems == [context.items[0].logicalItemKey])
        #expect(outcome.checkpointManifest.checkpoints == [
            RemoteTransferCheckpoint(
                key: try RemoteTransferWorkItemKey(
                    topLevelKey: context.items[0].logicalItemKey,
                    relativeRawComponents: []
                ),
                disposition: .committed
            )
        ])
        #expect(outcome.checkpointManifest.cleanupEntries.isEmpty)
        #expect(await providerFactory.requestedEndpointIDs() == [fixture.endpoint.id])
        #expect(await provider.recordedOperations() == [.createFile(path)])
        #expect(await provider.cancelCount() == 1)
        #expect(await provider.closeCount() == 1)
    }
}

private struct ProductionWorkerFixture {
    let owner: RemoteTransferOwnerIdentity
    let endpoint: RemoteTransferEndpointSnapshot

    init() throws {
        owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        endpoint = try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText("Fixture"),
                kind: .simulated
            ),
            trustedConnectionMaterial: ProductionWorkerTestMaterial()
        )
    }

    func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    func context(
        kind: RemoteTransferJobKind,
        sources: [RemoteTransferItemSource],
        destination: RemoteTransferDestination,
        collisionPolicy: RemoteTransferCollisionPolicy,
        metadataPolicy: RemoteTransferMetadataPolicy,
        symlinkPolicy: RemoteTransferSymlinkPolicy
    ) throws -> RemoteTransferWorkerContext {
        let requestedItems = sources.map {
            RemoteTransferRequestedItem(
                logicalKey: RemoteTransferLogicalItemKey(),
                source: $0
            )
        }
        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: kind,
            requestedItems: requestedItems,
            destination: destination,
            collisionPolicy: collisionPolicy,
            metadataPolicy: metadataPolicy,
            symlinkPolicy: symlinkPolicy,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )
        let attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)
        return RemoteTransferWorkerContext(
            request: request,
            attempt: attempt,
            items: requestedItems.map {
                RemoteTransferAttemptItem(
                    logicalItemKey: $0.logicalKey,
                    attemptItemID: RemoteTransferAttemptItemID()
                )
            },
            checkpointManifest: .empty,
            resolvedCollision: nil,
            applyToAllResolution: nil,
            requiresDestinationRevalidation: false
        )
    }
}

private struct ProductionWorkerTestMaterial: RemoteTransferTrustedConnectionMaterial {
    let retainedByteCount = 0
}

private actor RecordingTransferEndpointProviderFactory: RemoteTransferEndpointProviderFactory {
    private let providers: [UUID: any RemoteTransferEndpointProvider]
    private var requestedIDs: [UUID] = []

    init(providers: [UUID: any RemoteTransferEndpointProvider]) {
        self.providers = providers
    }

    func makeProvider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) async throws -> any RemoteTransferEndpointProvider {
        requestedIDs.append(endpoint.id)
        guard let provider = providers[endpoint.id] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return provider
    }

    func requestedEndpointIDs() -> [UUID] { requestedIDs }
}

private actor RecordingTransferEndpointProvider: RemoteTransferEndpointProvider {
    enum Operation: Equatable {
        case createFile(RemotePath)
    }

    private var operations: [Operation] = []
    private var cancellations = 0
    private var closes = 0

    var capabilities: RemoteFileCapabilities {
        RemoteFileCapabilities(
            canList: true,
            canMutate: true,
            canTransfer: true,
            supportsAtomicReplace: true
        )
    }

    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        try RemoteDirectoryListing(directory: path, entries: [])
    }

    func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes {
        throw RemoteFileError(category: .pathNotFound)
    }

    func createFile(_ path: RemotePath) async throws {
        operations.append(.createFile(path))
    }

    func createDirectory(_ path: RemotePath) async throws {}

    func rename(
        _ source: RemotePath,
        to destination: RemotePath,
        replace: Bool
    ) async throws {}

    func removeFile(_ path: RemotePath) async throws {}
    func removeDirectory(_ path: RemotePath) async throws {}
    func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws {}

    func openFileForReading(_ path: RemotePath) async throws -> any RemoteReadableFile {
        throw RemoteFileError(category: .invalidOperation)
    }

    func openFileForWriting(_ path: RemotePath) async throws -> any RemoteWritableFile {
        throw RemoteFileError(category: .invalidOperation)
    }

    func cancelAll() async { cancellations += 1 }
    func close() async { closes += 1 }

    func recordedOperations() -> [Operation] { operations }
    func cancelCount() -> Int { cancellations }
    func closeCount() -> Int { closes }
}

private actor RecordingLocalTransferStaging: LocalTransferStaging {
    func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalName: RemotePathComponent,
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        throw RemoteFileError(category: .invalidOperation)
    }

    func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalNameRawBytes: [UInt8],
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        throw RemoteFileError(category: .invalidOperation)
    }

    func write(_ data: Data, to staged: LocalTransferStagedDownload) async throws {}

    func publish(
        _ staged: LocalTransferStagedDownload,
        expectedByteCount: UInt64,
        mode: mode_t
    ) async throws {}

    func cleanup(_ staged: LocalTransferStagedDownload) async throws {}

    func openValidatedSource(
        _ identity: RemoteTransferLocalFileIdentity
    ) async throws -> LocalTransferOpenedSource {
        throw RemoteFileError(category: .invalidOperation)
    }

    func read(
        _ source: LocalTransferOpenedSource,
        maximumBytes: Int
    ) async throws -> Data? {
        throw RemoteFileError(category: .invalidOperation)
    }

    func closeSource(_ source: LocalTransferOpenedSource) async throws {}
}
