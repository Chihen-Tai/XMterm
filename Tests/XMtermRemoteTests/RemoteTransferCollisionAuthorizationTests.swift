import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote transfer collision authorization", .serialized)
struct RemoteTransferCollisionAuthorizationTests {
    @Test("[FILE-XFER-001] one-shot resolution matches exact raw collision identity only")
    func oneShotResolutionMatchesExactCollisionOnly() throws {
        let key = RemoteTransferLogicalItemKey()
        let workA = try RemoteTransferWorkItemKey(
            topLevelKey: key,
            relativeRawComponents: [
                try RemotePathComponent(rawBytes: Array("child-a".utf8))
            ]
        )
        let workB = try RemoteTransferWorkItemKey(
            topLevelKey: key,
            relativeRawComponents: [
                try RemotePathComponent(rawBytes: Array("child-b".utf8))
            ]
        )
        let collisionA = RemoteTransferCollision(
            workItemKey: workA,
            destination: try authorizationPath("/destination/a")
        )
        let differentDestination = RemoteTransferCollision(
            workItemKey: workA,
            destination: try authorizationPath("/destination/b")
        )
        let differentWork = RemoteTransferCollision(
            workItemKey: workB,
            destination: collisionA.destination
        )
        let resolution = try RemoteTransferCollisionResolution(
            decision: .replace,
            applyToAll: false
        )
        let resolved = RemoteTransferResolvedCollision(
            collision: collisionA,
            resolution: resolution
        )

        #expect(resolved.resolution(ifRevalidated: collisionA) == resolution)
        #expect(resolved.resolution(ifRevalidated: differentDestination) == nil)
        #expect(resolved.resolution(ifRevalidated: differentWork) == nil)
    }

    @Test("[FILE-XFER-001] invalid apply-all and replacement guarantees are rejected")
    func resolutionValidationRejectsUnsafeCombinations() {
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try RemoteTransferCollisionResolution(
                decision: .cancel,
                applyToAll: true,
                replacementGuarantee: .notApplicable
            )
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try RemoteTransferCollisionResolution(
                decision: .skip,
                applyToAll: false,
                replacementGuarantee: .explicitlyAcceptedNonAtomicFallback
            )
        }
    }

    @Test("[FILE-XFER-001] engine requeues exact resolution and full apply-all policy")
    func enginePreservesBoundResolutionAndReplacementGuarantee() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller)
        )
        let key = RemoteTransferLogicalItemKey()
        let request = RemoteTransferRequest(logicalItemKeys: [key])
        let jobID = try await engine.enqueue(request)
        await authorizationEventually { await controller.startedContextCount() == 1 }
        let collision = RemoteTransferCollision(
            logicalItemKey: key,
            destination: try authorizationPath("/destination/existing")
        )
        await controller.finish(
            jobID: jobID,
            with: .conflict(
                collision: collision,
                completedItems: [],
                checkpointManifest: .empty
            )
        )
        await authorizationEventually { (await engine.snapshots()).first?.state == .conflict }
        let attempt = try #require((await engine.snapshots()).first?.attempt)
        let resolution = try RemoteTransferCollisionResolution(
            decision: .replace,
            applyToAll: true,
            replacementGuarantee: .explicitlyAcceptedNonAtomicFallback
        )

        try await engine.resolveCollision(
            jobID: jobID,
            attempt: attempt,
            resolution: resolution
        )
        await authorizationEventually { await controller.startedContextCount() == 2 }
        let resumed = try #require((await controller.startedContexts()).last)
        #expect(resumed.attempt == attempt)
        #expect(resumed.resolvedCollision?.collision == collision)
        #expect(resumed.applyToAllResolution == resolution)
        #expect(resumed.resolvedCollision?.resolution(ifRevalidated: collision) == resolution)
        let collisionB = RemoteTransferCollision(
            logicalItemKey: key,
            destination: try authorizationPath("/destination/different")
        )
        #expect(resumed.resolvedCollision?.resolution(ifRevalidated: collisionB) == nil)
        await engine.cancelAllAndSettle()
    }
}

private func authorizationPath(_ value: String) throws -> RemotePath {
    try RemotePath(rawBytes: Array(value.utf8))
}

private func authorizationEventually(
    limit: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<limit {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}
