import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote transfer engine suspension races", .serialized)
struct RemoteTransferEngineRaceTests {
    @Test(
        "[APP-008] cancellation cannot be overwritten by a suspended worker event",
        arguments: [
            RemoteTransferWorkerEvent.phase(.verifying),
            RemoteTransferWorkerEvent.currentItem(
                try RemoteTransferPresentationText("suspended-item")
            ),
            RemoteTransferWorkerEvent.progress(
                bytesCompleted: 1,
                bytesTotal: nil,
                itemsCompleted: 0,
                itemsTotal: nil
            )
        ]
    )
    func cancellationWinsClockReentrancyRace(
        event: RemoteTransferWorkerEvent
    ) async throws {
        let clock = BlockingTransferClock()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller),
            clock: clock
        )
        let jobID = try await engine.enqueue(raceRequest())
        await raceEventually { await controller.startedJobIDs() == [jobID] }
        await controller.holdCancellationSettlement()
        await clock.armNextRequest()
        let suspendedEvent = Task {
            await controller.emit(jobID: jobID, event)
        }
        await clock.waitUntilRequested()

        let cancellation = Task { await engine.cancel(jobID: jobID) }
        await raceEventually { (await engine.snapshots()).first?.state == .cancelling }
        await clock.release()
        await suspendedEvent.value
        #expect((await engine.snapshots()).first?.state == .cancelling)

        await controller.finish(
            jobID: jobID,
            with: .cancelled(completedItems: [], checkpointManifest: .empty)
        )
        await cancellation.value
        #expect((await engine.snapshots()).first?.state == .cancelled)
    }

    @Test("[APP-008] a suspended completion cannot overwrite settled cancellation")
    func cancellationWinsSuspendedFinishRace() async throws {
        let clock = BlockingTransferClock()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller),
            clock: clock
        )
        let jobID = try await engine.enqueue(raceRequest())
        await raceEventually { await controller.startedJobIDs() == [jobID] }
        await clock.armNextRequest()
        await controller.finish(
            jobID: jobID,
            with: .completed(completedItems: [], checkpointManifest: .empty)
        )
        await clock.waitUntilRequested()

        await engine.cancel(jobID: jobID)
        #expect((await engine.snapshots()).first?.state == .cancelled)
        await clock.release()
        await raceEventually { (await engine.snapshots()).first?.state.isTerminal == true }
        #expect((await engine.snapshots()).first?.state == .cancelled)
    }

    @Test("[APP-008, FILE-XFER-001] suspended conflict resolution cannot revive cancellation")
    func cancellationWinsSuspendedConflictResolutionRace() async throws {
        let clock = BlockingTransferClock()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller),
            clock: clock
        )
        let request = raceRequest()
        let jobID = try await engine.enqueue(request)
        await raceEventually { await controller.startedJobIDs() == [jobID] }
        await controller.finish(
            jobID: jobID,
            with: .conflict(
                collision: RemoteTransferCollision(
                    logicalItemKey: request.logicalItemKeys[0],
                    destination: try RemotePath(rawBytes: Array("/tmp/existing".utf8))
                ),
                completedItems: [],
                checkpointManifest: .empty
            )
        )
        await raceEventually { (await engine.snapshots()).first?.state == .conflict }
        let attempt = try #require((await engine.snapshots()).first?.attempt)

        await clock.armNextRequest()
        let resolution = Task {
            try await engine.resolveCollision(
                jobID: jobID,
                attempt: attempt,
                resolution: try RemoteTransferCollisionResolution(
                    decision: .replace,
                    applyToAll: false
                )
            )
        }
        await clock.waitUntilRequested()
        await engine.cancel(jobID: jobID)
        #expect((await engine.snapshots()).first?.state == .cancelled)
        await clock.release()
        await #expect(throws: RemoteTransferEngineError.self) {
            try await resolution.value
        }
        #expect((await engine.snapshots()).first?.state == .cancelled)
        #expect(await controller.startedContextCount() == 1)
    }

    @Test("[APP-008, FILE-XFER-001] suspended queue pumps reserve no more than two slots")
    func suspendedPumpRevalidatesCapacityBeforeStartingWorker() async throws {
        let clock = BlockingTransferClock()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller),
            clock: clock
        )
        let first = try await engine.enqueue(raceRequest())
        let second = try await engine.enqueue(raceRequest())
        let suspended = try await engine.enqueue(raceRequest())
        await raceEventually { await controller.startedContextCount() == 2 }

        await clock.arm(afterImmediateRequests: 1)
        await controller.finish(
            jobID: first,
            with: .completed(completedItems: [], checkpointManifest: .empty)
        )
        await clock.waitUntilRequested()

        let later = try await engine.enqueue(raceRequest())
        await raceEventually { await controller.startedJobIDs().contains(later) }
        #expect(!(await controller.startedJobIDs()).contains(suspended))
        await clock.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(await controller.maximumActiveCount() <= 2)
        #expect(!(await controller.startedJobIDs()).contains(suspended))

        await controller.finish(
            jobID: second,
            with: .completed(completedItems: [], checkpointManifest: .empty)
        )
        await raceEventually { await controller.startedJobIDs().contains(suspended) }
        await engine.cancelAllAndSettle()
    }

    private func raceRequest() -> RemoteTransferRequest {
        RemoteTransferRequest(logicalItemKeys: [RemoteTransferLogicalItemKey()])
    }
}

private func raceEventually(
    limit: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<limit {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}
