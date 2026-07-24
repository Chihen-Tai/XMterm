import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote transfer production mutations")
struct RemoteTransferProductionMutationTests {
    @Test("[FILE-OPS-003] create-directory dispatches one typed nonrecursive mutation")
    func createDirectoryDispatchesTypedMutation() async throws {
        let scenario = try ProductionWorkerScenario()
        let target = try scenario.path("/workspace/new-folder")
        let provider = ProductionWorkerEndpointProvider(
            directories: [.root, try scenario.path("/workspace")]
        )
        let outcome = await run(
            scenario: scenario,
            provider: provider,
            context: try scenario.context(
                kind: .createDirectory,
                sources: [.remote(endpoint: scenario.sourceEndpoint, path: target)],
                destination: .none,
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .rejectTransfer
            )
        )

        #expect(outcome.disposition == .completed)
        #expect(await provider.recordedOperations().contains(.createDirectory(target)))
    }

    @Test("[FILE-OPS-002] rename uses the exact typed source and destination")
    func renameUsesExactPaths() async throws {
        let scenario = try ProductionWorkerScenario()
        let source = try scenario.path("/workspace/old.txt")
        let destination = try scenario.path("/workspace/new.txt")
        let provider = ProductionWorkerEndpointProvider(
            files: [source: (Data("old".utf8), 0o600)],
            directories: [.root, try scenario.path("/workspace")]
        )
        let outcome = await run(
            scenario: scenario,
            provider: provider,
            context: try scenario.context(
                kind: .rename,
                sources: [.remote(endpoint: scenario.sourceEndpoint, path: source)],
                destination: .remotePath(
                    endpoint: scenario.sourceEndpoint,
                    path: destination
                ),
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity
            )
        )

        #expect(outcome.disposition == .completed)
        #expect(await provider.file(destination)?.0 == Data("old".utf8))
        #expect(await provider.recordedOperations().contains(
            .rename(source, destination, false)
        ))
    }

    @Test("[FILE-OPS-002] same-endpoint move is a direct rename without streaming")
    func moveIsDirectRename() async throws {
        let scenario = try ProductionWorkerScenario()
        let source = try scenario.path("/workspace/old.txt")
        let destinationDirectory = try scenario.path("/archive")
        let destination = try scenario.path("/archive/old.txt")
        let provider = ProductionWorkerEndpointProvider(
            files: [source: (Data("old".utf8), 0o600)],
            directories: [.root, try scenario.path("/workspace"), destinationDirectory]
        )
        let outcome = await run(
            scenario: scenario,
            provider: provider,
            context: try scenario.context(
                kind: .remoteMove,
                sources: [.remote(endpoint: scenario.sourceEndpoint, path: source)],
                destination: .remoteDirectory(
                    endpoint: scenario.sourceEndpoint,
                    path: destinationDirectory
                ),
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity
            )
        )

        #expect(outcome.disposition == .completed)
        #expect(await provider.file(destination)?.0 == Data("old".utf8))
        let operations = await provider.recordedOperations()
        #expect(operations.contains(.rename(source, destination, false)))
        #expect(!operations.contains { operation in
            if case .openRead = operation { return true }
            return false
        })
    }

    @Test("[FILE-OPS-003] delete selects remove-file for regular entries")
    func deleteRegularUsesRemoveFile() async throws {
        let scenario = try ProductionWorkerScenario()
        let target = try scenario.path("/workspace/file.txt")
        let provider = ProductionWorkerEndpointProvider(
            files: [target: (Data(), 0o600)],
            directories: [.root, try scenario.path("/workspace")]
        )
        let outcome = await run(
            scenario: scenario,
            provider: provider,
            context: try scenario.context(
                kind: .delete,
                sources: [.remote(endpoint: scenario.sourceEndpoint, path: target)],
                destination: .none,
                collisionPolicy: .notApplicable,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity
            )
        )

        #expect(outcome.disposition == .completed)
        #expect(await provider.recordedOperations().contains(.removeFile(target)))
    }

    @Test("[FILE-OPS-003] delete selects rmdir for an empty directory")
    func deleteDirectoryUsesRemoveDirectory() async throws {
        let scenario = try ProductionWorkerScenario()
        let target = try scenario.path("/workspace/empty")
        let provider = ProductionWorkerEndpointProvider(
            directories: [.root, try scenario.path("/workspace"), target]
        )
        let outcome = await run(
            scenario: scenario,
            provider: provider,
            context: try scenario.context(
                kind: .delete,
                sources: [.remote(endpoint: scenario.sourceEndpoint, path: target)],
                destination: .none,
                collisionPolicy: .notApplicable,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity
            )
        )

        #expect(outcome.disposition == .completed)
        #expect(await provider.recordedOperations().contains(.removeDirectory(target)))
    }

    @Test("[FILE-XFER-003] Task 4 refuses nonrecursive directory copy")
    func directoryCopyFailsClosedWithoutEnumeration() async throws {
        let scenario = try ProductionWorkerScenario()
        let source = try scenario.path("/workspace/folder")
        let destinationDirectory = try scenario.path("/archive")
        let provider = ProductionWorkerEndpointProvider(
            directories: [.root, try scenario.path("/workspace"), source, destinationDirectory]
        )
        let outcome = await run(
            scenario: scenario,
            provider: provider,
            context: try scenario.context(
                kind: .remoteCopy,
                sources: [.remote(endpoint: scenario.sourceEndpoint, path: source)],
                destination: .remoteDirectory(
                    endpoint: scenario.sourceEndpoint,
                    path: destinationDirectory
                ),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer
            )
        )

        guard case let .failed(error, _) = outcome.disposition else {
            Issue.record("Expected directory copy to fail")
            return
        }
        #expect(error.category == .unsupportedEntry)
        let operations = await provider.recordedOperations()
        #expect(!operations.contains { operation in
            if case .openRead = operation { return true }
            return false
        })
    }

    private func run(
        scenario: ProductionWorkerScenario,
        provider: ProductionWorkerEndpointProvider,
        context: RemoteTransferWorkerContext
    ) async -> RemoteTransferWorkerOutcome {
        let factory = ProductionWorkerEndpointFactory(
            providers: [scenario.sourceEndpoint.id: provider]
        )
        do {
            let worker = try await RemoteTransferProductionWorkerFactory(
                endpointProviderFactory: factory,
                localStaging: ProductionWorkerLocalStaging()
            ).makeWorker(for: context)
            return await worker.run { _ in }
        } catch let error as RemoteFileError {
            return .failed(
                error: error,
                itemFailures: [],
                completedItems: [],
                checkpointManifest: context.checkpointManifest
            )
        } catch {
            return .failed(
                error: RemoteFileError(category: .providerFailure),
                itemFailures: [],
                completedItems: [],
                checkpointManifest: context.checkpointManifest
            )
        }
    }
}
