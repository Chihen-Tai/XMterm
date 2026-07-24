import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote transfer production collision guarantees")
struct RemoteTransferProductionCollisionTests {
    @Test("[FILE-XFER-002] unresolved destination collision returns conflict before staging")
    func unresolvedCollisionReturnsConflict() async throws {
        let fixture = try uploadFixture(
            supportsAtomicReplace: true,
            resolvedCollision: nil
        )

        let outcome = await fixture.worker.run { _ in }

        #expect(outcome.disposition == .conflict(
            RemoteTransferCollision(
                logicalItemKey: fixture.context.items[0].logicalItemKey,
                destination: fixture.destination
            )
        ))
        #expect(await fixture.provider.file(fixture.destination)?.0 == Data("old".utf8))
        #expect(outcome.checkpointManifest.cleanupEntries.isEmpty)
    }

    @Test("[FILE-XFER-002] one-shot resolution is consumed only for the exact revalidated collision")
    func mismatchedOneShotResolutionReturnsFreshConflict() async throws {
        let scenario = try ProductionWorkerScenario()
        let wrongDestination = try scenario.path("/workspace/other.bin")
        let provisional = RemoteTransferCollision(
            logicalItemKey: RemoteTransferLogicalItemKey(),
            destination: wrongDestination
        )
        let resolved = RemoteTransferResolvedCollision(
            collision: provisional,
            resolution: try RemoteTransferCollisionResolution(
                decision: .replace,
                applyToAll: false
            )
        )
        let fixture = try uploadFixture(
            scenario: scenario,
            supportsAtomicReplace: true,
            resolvedCollision: resolved
        )

        let outcome = await fixture.worker.run { _ in }

        guard case let .conflict(collision) = outcome.disposition else {
            Issue.record("Expected a fresh conflict")
            return
        }
        #expect(collision.destination == fixture.destination)
        #expect(collision.logicalItemKey == fixture.context.items[0].logicalItemKey)
        #expect(await fixture.provider.file(fixture.destination)?.0 == Data("old".utf8))
    }

    @Test("[FILE-XFER-002] atomic-only Replace re-enters conflict after capability downgrade")
    func atomicOnlyReplaceConflictsAfterDowngrade() async throws {
        let scenario = try ProductionWorkerScenario()
        let destination = try scenario.path("/workspace/upload.bin")
        let logicalKey = RemoteTransferLogicalItemKey()
        let collision = RemoteTransferCollision(
            logicalItemKey: logicalKey,
            destination: destination
        )
        let fixture = try uploadFixture(
            scenario: scenario,
            logicalKey: logicalKey,
            supportsAtomicReplace: false,
            resolvedCollision: RemoteTransferResolvedCollision(
                collision: collision,
                resolution: try RemoteTransferCollisionResolution(
                    decision: .replace,
                    applyToAll: false
                )
            )
        )

        let outcome = await fixture.worker.run { _ in }

        #expect(outcome.disposition == .conflict(collision))
        #expect(await fixture.provider.file(destination)?.0 == Data("old".utf8))
        let operations = await fixture.provider.recordedOperations()
        #expect(!operations.contains { operation in
            if case .openWrite = operation { return true }
            return false
        })
    }

    @Test("[FILE-XFER-002] explicitly accepted fallback uses backup-finalize-cleanup sequence")
    func explicitFallbackUsesTruthfulSequence() async throws {
        let scenario = try ProductionWorkerScenario()
        let destination = try scenario.path("/workspace/upload.bin")
        let logicalKey = RemoteTransferLogicalItemKey()
        let collision = RemoteTransferCollision(
            logicalItemKey: logicalKey,
            destination: destination
        )
        let fixture = try uploadFixture(
            scenario: scenario,
            logicalKey: logicalKey,
            supportsAtomicReplace: false,
            resolvedCollision: RemoteTransferResolvedCollision(
                collision: collision,
                resolution: try RemoteTransferCollisionResolution(
                    decision: .replace,
                    applyToAll: false,
                    replacementGuarantee: .explicitlyAcceptedNonAtomicFallback
                )
            )
        )

        let outcome = await fixture.worker.run { _ in }

        #expect(outcome.disposition == .completed)
        #expect(await fixture.provider.file(destination)?.0 == Data("new".utf8))
        #expect(outcome.checkpointManifest.cleanupEntries.isEmpty)
        let operations = await fixture.provider.recordedOperations()
        let renames = operations.compactMap { operation -> ProductionWorkerEndpointProvider.Operation? in
            if case .rename = operation { return operation }
            return nil
        }
        #expect(renames.count == 2)
        #expect(renames[0] == .rename(destination, fixture.backup, false))
        #expect(renames[1] == .rename(fixture.staging, destination, false))
        #expect(operations.contains(.removeFile(fixture.backup)))
    }

    private func uploadFixture(
        scenario: ProductionWorkerScenario? = nil,
        logicalKey: RemoteTransferLogicalItemKey? = nil,
        supportsAtomicReplace: Bool,
        resolvedCollision: RemoteTransferResolvedCollision?
    ) throws -> UploadCollisionFixture {
        let scenario = try scenario ?? ProductionWorkerScenario()
        let directory = try scenario.path("/workspace")
        let destination = try scenario.path("/workspace/upload.bin")
        let sourceURL = URL(fileURLWithPath: "/fixture/upload.bin")
        let local = ProductionWorkerLocalStaging(
            sources: [sourceURL: (Data("new".utf8), 0o600)]
        )
        let provider = ProductionWorkerEndpointProvider(
            files: [destination: (Data("old".utf8), 0o640)],
            directories: [.root, directory],
            supportsAtomicReplace: supportsAtomicReplace
        )
        let providerFactory = ProductionWorkerEndpointFactory(
            providers: [scenario.destinationEndpoint.id: provider]
        )
        let identity = try scenario.localIdentity(sourceURL, size: 3)
        let baseContext = try scenario.context(
            kind: .upload,
            sources: [.local(identity)],
            destination: .remoteDirectory(
                endpoint: scenario.destinationEndpoint,
                path: directory
            ),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer
        )
        let selectedKey = logicalKey ?? baseContext.items[0].logicalItemKey
        let requested = RemoteTransferRequestedItem(
            logicalKey: selectedKey,
            source: .local(identity)
        )
        let request = try RemoteTransferRequest(
            id: baseContext.jobID,
            owner: scenario.owner,
            kind: .upload,
            requestedItems: [requested],
            destination: baseContext.request.destination,
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )
        let attemptItemID = RemoteTransferAttemptItemID()
        let context = RemoteTransferWorkerContext(
            request: request,
            attempt: baseContext.attempt,
            items: [
                RemoteTransferAttemptItem(
                    logicalItemKey: selectedKey,
                    attemptItemID: attemptItemID
                )
            ],
            checkpointManifest: .empty,
            resolvedCollision: resolvedCollision,
            applyToAllResolution: nil,
            requiresDestinationRevalidation: resolvedCollision != nil
        )
        let worker = try RemoteTransferProductionWorker(
            context: context,
            resolver: RemoteTransferEndpointProviderResolver(factory: providerFactory),
            localStaging: local
        )
        let staging = try directory.appending(
            RemotePathComponent(
                rawBytes: Array(
                    ".xmterm-partial-\(context.attempt.id.uuidString)-\(attemptItemID.rawValue.uuidString)".utf8
                )
            )
        )
        let backup = try directory.appending(
            RemotePathComponent(
                rawBytes: Array(
                    ".xmterm-backup-\(context.attempt.id.uuidString)-\(attemptItemID.rawValue.uuidString)".utf8
                )
            )
        )
        return UploadCollisionFixture(
            context: context,
            worker: worker,
            provider: provider,
            destination: destination,
            staging: staging,
            backup: backup
        )
    }
}

private struct UploadCollisionFixture {
    let context: RemoteTransferWorkerContext
    let worker: RemoteTransferProductionWorker
    let provider: ProductionWorkerEndpointProvider
    let destination: RemotePath
    let staging: RemotePath
    let backup: RemotePath
}
