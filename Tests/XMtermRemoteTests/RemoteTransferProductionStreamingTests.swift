import Darwin
import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote transfer production streaming")
struct RemoteTransferProductionStreamingTests {
    @Test(
        "[FILE-XFER-001, FILE-XFER-002, FILE-META-001] upload streams bounded chunks through same-directory staging",
        arguments: [0, 7, 65_536, 65_537, 131_089]
    )
    func uploadStreamsBoundedChunks(byteCount: Int) async throws {
        let scenario = try ProductionWorkerScenario()
        let directory = try scenario.path("/workspace")
        let destination = try scenario.path("/workspace/upload.bin")
        let sourceURL = URL(fileURLWithPath: "/fixture/upload.bin")
        let data = fixtureData(byteCount)
        let local = ProductionWorkerLocalStaging(sources: [sourceURL: (data, 0o751)])
        let provider = ProductionWorkerEndpointProvider(directories: [.root, directory])
        let providerFactory = ProductionWorkerEndpointFactory(
            providers: [scenario.destinationEndpoint.id: provider]
        )
        let sourceIdentity = try scenario.localIdentity(
            sourceURL,
            size: UInt64(byteCount)
        )
        let context = try scenario.context(
            kind: .upload,
            sources: [.local(sourceIdentity)],
            destination: .remoteDirectory(
                endpoint: scenario.destinationEndpoint,
                path: directory
            ),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer
        )
        let worker = try await RemoteTransferProductionWorkerFactory(
            endpointProviderFactory: providerFactory,
            localStaging: local
        ).makeWorker(for: context)

        let outcome = await worker.run { _ in }

        #expect(outcome.disposition == .completed)
        #expect(await provider.file(destination)?.0 == data)
        #expect(await provider.file(destination)?.1 == 0o751)
        let writeSizes = await provider.recordedOperations().compactMap { operation in
            if case let .write(_, byteCount) = operation { return byteCount }
            return nil
        }
        #expect(writeSizes.allSatisfy { $0 <= RemoteFileTransferLimits.maximumChunkByteCount })
        #expect(writeSizes.reduce(0, +) == byteCount)
        #expect(await local.maximumReadRequests().allSatisfy {
            $0 == RemoteFileTransferLimits.maximumChunkByteCount
        })
        #expect(outcome.checkpointManifest.cleanupEntries.isEmpty)
    }

    @Test(
        "[FILE-XFER-001, FILE-XFER-002, FILE-META-001] download streams bounded chunks into atomic local staging",
        arguments: [0, 11, 65_536, 65_537, 131_089]
    )
    func downloadStreamsBoundedChunks(byteCount: Int) async throws {
        let scenario = try ProductionWorkerScenario()
        let source = try scenario.path("/workspace/download.bin")
        let data = fixtureData(byteCount)
        let provider = ProductionWorkerEndpointProvider(
            files: [source: (data, 0o740)],
            directories: [.root, try scenario.path("/workspace")]
        )
        let providerFactory = ProductionWorkerEndpointFactory(
            providers: [scenario.sourceEndpoint.id: provider]
        )
        let destinationURL = URL(fileURLWithPath: "/fixture/downloads")
        let destinationIdentity = try scenario.localIdentity(
            destinationURL,
            kind: .directory
        )
        let local = ProductionWorkerLocalStaging()
        let context = try scenario.context(
            kind: .download,
            sources: [.remote(endpoint: scenario.sourceEndpoint, path: source)],
            destination: .localDirectory(destinationIdentity),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer
        )
        let worker = try await RemoteTransferProductionWorkerFactory(
            endpointProviderFactory: providerFactory,
            localStaging: local
        ).makeWorker(for: context)

        let outcome = await worker.run { _ in }

        let finalURL = destinationURL.appending(path: "download.bin")
        #expect(outcome.disposition == .completed)
        #expect(await local.published(finalURL)?.0 == data)
        #expect(await local.published(finalURL)?.1 == mode_t(0o740))
        let readMaximums = await provider.recordedOperations().compactMap { operation in
            if case let .read(_, maximum) = operation { return maximum }
            return nil
        }
        #expect(readMaximums.allSatisfy {
            $0 == RemoteFileTransferLimits.maximumChunkByteCount
        })
        #expect(await local.activeStagingCount() == 0)
        #expect(outcome.checkpointManifest.cleanupEntries.isEmpty)
    }

    @Test("[FILE-XFER-004] cross-endpoint copy uses exactly two settled providers and no whole-file buffer")
    func crossEndpointCopyUsesTwoProviders() async throws {
        let scenario = try ProductionWorkerScenario()
        let source = try scenario.path("/source/item.bin")
        let destinationDirectory = try scenario.path("/destination")
        let destination = try scenario.path("/destination/item.bin")
        let data = fixtureData(65_537)
        let sourceProvider = ProductionWorkerEndpointProvider(
            files: [source: (data, 0o711)],
            directories: [.root, try scenario.path("/source")]
        )
        let destinationProvider = ProductionWorkerEndpointProvider(
            directories: [.root, destinationDirectory]
        )
        let providerFactory = ProductionWorkerEndpointFactory(
            providers: [
                scenario.sourceEndpoint.id: sourceProvider,
                scenario.destinationEndpoint.id: destinationProvider
            ]
        )
        let local = ProductionWorkerLocalStaging()
        let sourceOwner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let crossSource = try RemoteTransferEndpointSnapshot(
            id: scenario.sourceEndpoint.id,
            owner: sourceOwner,
            summary: scenario.sourceEndpoint.summary,
            trustedConnectionMaterial: ProductionWorkerSupportMaterial()
        )
        let context = try scenario.context(
            kind: .remoteCopy,
            sources: [.remote(endpoint: crossSource, path: source)],
            destination: .remoteDirectory(
                endpoint: scenario.destinationEndpoint,
                path: destinationDirectory
            ),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            crossRuntimePolicy: .destinationOwnedCopy(sourceOwner: sourceOwner)
        )
        let worker = try await RemoteTransferProductionWorkerFactory(
            endpointProviderFactory: providerFactory,
            localStaging: local
        ).makeWorker(for: context)

        let outcome = await worker.run { _ in }

        #expect(outcome.disposition == .completed)
        #expect(await destinationProvider.file(destination)?.0 == data)
        #expect(await providerFactory.requests() == [crossSource.id, scenario.destinationEndpoint.id])
        #expect(await sourceProvider.recordedOperations().suffix(2) == [.cancelAll, .close])
        #expect(await destinationProvider.recordedOperations().suffix(2) == [.cancelAll, .close])
    }

    private func fixtureData(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }
}
