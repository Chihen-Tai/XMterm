import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote transfer engine")
struct RemoteTransferEngineTests {
    @Test("[FILE-XFER-001] jobs start in FIFO order with no more than two active workers")
    func fifoAndTwoWorkerBound() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobs = try await enqueueJobs(count: 3, on: engine)

        await eventually { await controller.startedJobIDs().count == 2 }
        #expect(await controller.startedJobIDs() == Array(jobs.prefix(2)))
        #expect(await controller.maximumActiveCount() == 2)

        await controller.finish(jobID: jobs[0], with: .completed(completedItems: []))
        await eventually { await controller.startedJobIDs().count == 3 }
        #expect(await controller.startedJobIDs() == jobs)
        #expect(await controller.maximumActiveCount() == 2)
    }

    @Test("[APP-008, FILE-XFER-001] queue admission is bounded to 1,000 nonterminal jobs")
    func queueCapacityIsBounded() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))

        _ = try await enqueueJobs(count: RemoteTransferEngine.maximumNonterminalJobCount, on: engine)
        await #expect(throws: RemoteTransferEngineError.queueCapacityExceeded) {
            try await engine.enqueue(request())
        }
        #expect((await engine.snapshots()).filter { !$0.state.isTerminal }.count == 1_000)
    }

    @Test("[APP-007] terminal record retention keeps the latest 500 plus every nonterminal job")
    func terminalRetentionIsBounded() async throws {
        let engine = RemoteTransferEngine(workerFactory: ImmediateTransferWorkerFactory())
        let jobs = try await enqueueJobs(count: 503, on: engine)

        await eventually(limit: 20_000) {
            let snapshots = await engine.snapshots()
            return snapshots.allSatisfy(\.state.isTerminal)
                && snapshots.count == RemoteTransferEngine.maximumTerminalRecordCount
        }
        let retainedIDs = Set((await engine.snapshots()).map(\.id))
        #expect(!retainedIDs.contains(jobs[0]))
        #expect(!retainedIDs.contains(jobs[1]))
        #expect(!retainedIDs.contains(jobs[2]))
        #expect(retainedIDs.contains(jobs.last!))
    }

    @Test("[APP-007, FILE-XFER-003] counters are monotonic and phase edges publish immediately")
    @MainActor
    func progressIsMonotonicAndByteOnlyPublicationIsCoalesced() async throws {
        let clock = ManualTransferClock()
        let recorder = TransferPublicationRecorder()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller),
            clock: clock,
            publication: { snapshots in recorder.record(snapshots) }
        )
        let jobID = try await engine.enqueue(request(itemCount: 2))
        await eventually { await controller.startedJobIDs() == [jobID] }

        let beforePhase = recorder.publicationCount
        await controller.emit(jobID: jobID, .phase(.transferring))
        #expect(recorder.publicationCount == beforePhase + 1)

        let beforeBytes = recorder.publicationCount
        await controller.emit(
            jobID: jobID,
            .progress(bytesCompleted: 10, bytesTotal: 100, itemsCompleted: 0, itemsTotal: 2)
        )
        let afterTotalsEdge = recorder.publicationCount
        #expect(afterTotalsEdge == beforeBytes + 1)
        await controller.emit(
            jobID: jobID,
            .progress(bytesCompleted: 20, bytesTotal: 100, itemsCompleted: 0, itemsTotal: 2)
        )
        #expect(recorder.publicationCount == afterTotalsEdge)
        await clock.advance(nanoseconds: 100_000_000)
        await controller.emit(
            jobID: jobID,
            .progress(bytesCompleted: 30, bytesTotal: 100, itemsCompleted: 0, itemsTotal: 2)
        )
        #expect(recorder.publicationCount == afterTotalsEdge + 1)

        await controller.emit(
            jobID: jobID,
            .progress(bytesCompleted: 5, bytesTotal: 50, itemsCompleted: 1, itemsTotal: 1)
        )
        await controller.emit(jobID: jobID, .phase(.verifying))
        let snapshot = try #require((await engine.snapshots()).first { $0.id == jobID })
        #expect(snapshot.bytesCompleted == 30)
        #expect(snapshot.bytesTotal == 100)
        #expect(snapshot.itemsCompleted == 1)
        #expect(snapshot.itemsTotal == 2)
        #expect(snapshot.runningPhase == .verifying)
    }

    @Test("[APP-008] a failed job does not corrupt or stop another job")
    func jobFailuresAreIsolated() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobs = try await enqueueJobs(count: 2, on: engine)
        let expected = RemoteFileError(category: .permissionDenied)

        await eventually { await controller.startedJobIDs().count == 2 }
        await controller.finish(
            jobID: jobs[0],
            with: .failed(error: expected, itemFailures: [], completedItems: [])
        )
        await controller.finish(jobID: jobs[1], with: .completed(completedItems: []))
        await eventually { (await engine.snapshots()).allSatisfy(\.state.isTerminal) }

        let snapshots = Dictionary(uniqueKeysWithValues: (await engine.snapshots()).map { ($0.id, $0) })
        #expect(snapshots[jobs[0]]?.state == .failed(expected))
        #expect(snapshots[jobs[1]]?.state == .completed)
    }

    @Test("[FILE-XFER-001] conflict releases its slot and resolution requeues the same attempt in original order")
    func conflictSuspendsWithoutOwningWorker() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let collisionKey = RemoteTransferLogicalItemKey()
        let firstJob = try await engine.enqueue(
            RemoteTransferRequest(logicalItemKeys: [collisionKey])
        )
        let jobs = [firstJob] + (try await enqueueJobs(count: 2, on: engine))
        await eventually { await controller.startedJobIDs().count == 2 }
        let attemptID = try #require((await engine.snapshots()).first { $0.id == jobs[0] }?.attemptID)
        let collision = RemoteTransferCollision(
            logicalItemKey: collisionKey,
            destination: try remotePath("/destination")
        )

        await controller.finish(jobID: jobs[0], with: .conflict(collision: collision, completedItems: []))
        await eventually { await controller.startedJobIDs().count == 3 }
        #expect(await controller.startedJobIDs() == jobs)
        #expect((await engine.snapshots()).first { $0.id == jobs[0] }?.state == .conflict)

        try await engine.resolveCollision(
            jobID: jobs[0],
            resolution: RemoteTransferCollisionResolution(decision: .replace, applyToAll: false)
        )
        await controller.finish(jobID: jobs[1], with: .completed(completedItems: []))
        await eventually { await controller.startedContexts().count == 4 }
        let resumed = (await controller.startedContexts()).last
        #expect(resumed?.jobID == jobs[0])
        #expect(resumed?.attemptID == attemptID)
        #expect(resumed?.collisionResolution?.decision == .replace)
        #expect(resumed?.requiresDestinationRevalidation == true)
    }

    @Test("[APP-008, FILE-XFER-003] cancellation publishes cancelling and settles only after worker cleanup")
    func cancellationWaitsForWorkerSettlement() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobID = try await engine.enqueue(request())
        await eventually { await controller.startedJobIDs() == [jobID] }

        let cancellation = Task { await engine.cancel(jobID: jobID) }
        await eventually {
            (await engine.snapshots()).first { $0.id == jobID }?.state == .cancelling
        }
        #expect(!cancellation.isCancelled)
        #expect((await engine.snapshots()).first { $0.id == jobID }?.state == .cancelling)

        await controller.finish(jobID: jobID, with: .cancelled(completedItems: []))
        await cancellation.value
        #expect((await engine.snapshots()).first { $0.id == jobID }?.state == .cancelled)
    }

    @Test("[FILE-XFER-003] retry preserves job identity, changes attempt identity, and excludes committed items")
    func retryUsesNewAttemptAndExcludesCommittedItems() async throws {
        let firstKey = RemoteTransferLogicalItemKey()
        let secondKey = RemoteTransferLogicalItemKey()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobID = try await engine.enqueue(RemoteTransferRequest(logicalItemKeys: [firstKey, secondKey]))
        await eventually { await controller.startedJobIDs() == [jobID] }
        let firstAttempt = try #require((await engine.snapshots()).first?.attemptID)
        let failure = RemoteTransferItemFailure(logicalItemKey: secondKey, error: .init(category: .timeout))

        await controller.finish(
            jobID: jobID,
            with: .failed(
                error: .init(category: .timeout),
                itemFailures: [failure],
                completedItems: [firstKey]
            )
        )
        await eventually { (await engine.snapshots()).first?.state.isTerminal == true }
        try await engine.retry(jobID: jobID)
        await eventually { await controller.startedContexts().count == 2 }

        let retry = try #require((await controller.startedContexts()).last)
        #expect(retry.jobID == jobID)
        #expect(retry.attemptID != firstAttempt)
        #expect(retry.items.map(\.logicalItemKey) == [secondKey])
        #expect(Set(retry.excludedCompletedItems) == [firstKey])
        #expect(Set(retry.items.map(\.attemptItemID)).count == 1)
    }

    @Test("[FILE-XFER-003] stale events and completions from an older attempt are ignored")
    func staleAttemptCallbacksAreIgnored() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobID = try await engine.enqueue(request())
        await eventually { await controller.startedContexts().count == 1 }
        let oldContext = try #require((await controller.startedContexts()).first)
        await controller.finish(
            jobID: jobID,
            with: .failed(error: .init(category: .timeout), itemFailures: [], completedItems: [])
        )
        await eventually { (await engine.snapshots()).first?.state.isTerminal == true }
        try await engine.retry(jobID: jobID)
        await eventually { await controller.startedContexts().count == 2 }

        await engine.receive(
            .progress(bytesCompleted: 999, bytesTotal: 999, itemsCompleted: 9, itemsTotal: 9),
            jobID: jobID,
            attemptID: oldContext.attemptID
        )
        await engine.finish(
            .completed(completedItems: []),
            jobID: jobID,
            attemptID: oldContext.attemptID
        )
        let snapshot = try #require((await engine.snapshots()).first)
        #expect(snapshot.attemptID != oldContext.attemptID)
        #expect(snapshot.bytesCompleted == 0)
        #expect(snapshot.state != .completed)
    }

    @Test("[APP-008] cancellation cannot be overwritten while an injected clock is suspended")
    func cancellationWinsClockReentrancyRace() async throws {
        let clock = BlockingTransferClock()
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ControlledTransferWorkerFactory(controller: controller),
            clock: clock
        )
        let jobID = try await engine.enqueue(request())
        await eventually { await controller.startedJobIDs() == [jobID] }
        let progress = Task {
            await controller.emit(
                jobID: jobID,
                .progress(bytesCompleted: 1, bytesTotal: nil, itemsCompleted: 0, itemsTotal: nil)
            )
        }
        await clock.waitUntilRequested()

        let cancellation = Task { await engine.cancel(jobID: jobID) }
        await eventually { (await engine.snapshots()).first?.state == .cancelling }
        await clock.release()
        await progress.value
        #expect((await engine.snapshots()).first?.state == .cancelling)

        await controller.finish(jobID: jobID, with: .cancelled(completedItems: []))
        await cancellation.value
        #expect((await engine.snapshots()).first?.state == .cancelled)
    }

    @Test("[APP-008] cancelling a queued job never creates a worker")
    func queuedCancellationDoesNotStartWorker() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobs = try await enqueueJobs(count: 3, on: engine)
        await eventually { await controller.startedJobIDs().count == 2 }

        await engine.cancel(jobID: jobs[2])
        #expect((await engine.snapshots()).first { $0.id == jobs[2] }?.state == .cancelled)
        await controller.finish(jobID: jobs[0], with: .completed(completedItems: []))
        await Task.yield()
        #expect(await controller.startedJobIDs() == Array(jobs.prefix(2)))
    }

    @Test("[APP-008, SESS-011] concurrent shutdown callers settle active and queued jobs exactly once")
    func concurrentShutdownSettlesEveryOwnedJob() async throws {
        let controller = ControlledTransferWorkerController()
        let engine = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: controller))
        let jobs = try await enqueueJobs(count: 3, on: engine)
        await eventually { await controller.startedJobIDs().count == 2 }

        let firstClose = Task { await engine.cancelAllAndSettle() }
        let secondClose = Task { await engine.cancelAllAndSettle() }
        await eventually {
            (await engine.snapshots()).allSatisfy { $0.state == .cancelling }
        }
        await controller.finish(jobID: jobs[0], with: .cancelled(completedItems: []))
        await controller.finish(jobID: jobs[1], with: .cancelled(completedItems: []))
        await firstClose.value
        await secondClose.value

        #expect((await engine.snapshots()).map(\.state) == [.cancelled, .cancelled, .cancelled])
        await #expect(throws: RemoteTransferEngineError.invalidState) {
            try await engine.enqueue(request())
        }
    }

    @Test("[FILE-XFER-001, SESS-011] concurrency stress preserves FIFO and the two-worker bound")
    func concurrencyStress() async throws {
        let probe = TransferConcurrencyProbe()
        let engine = RemoteTransferEngine(workerFactory: YieldingTransferWorkerFactory(probe: probe))
        let jobs = try await enqueueJobs(count: 200, on: engine)

        await eventually(limit: 50_000) {
            let snapshots = await engine.snapshots()
            return snapshots.count == jobs.count && snapshots.allSatisfy(\.state.isTerminal)
        }
        #expect(await probe.startedJobIDs() == jobs)
        let maximumActive = await probe.maximumActiveCount()
        #expect(maximumActive == 2)
    }

    @Test("[APP-007] main-actor coordinator publishes immutable engine snapshots")
    @MainActor
    func coordinatorPublishesSnapshots() async throws {
        let controller = ControlledTransferWorkerController()
        let coordinator = RemoteTransferCoordinator(
            workerFactory: ControlledTransferWorkerFactory(controller: controller)
        )
        let jobID = try await coordinator.enqueue(request())
        await eventuallyOnMainActor {
            coordinator.jobs.first { $0.id == jobID }?.state == .preparing
        }

        await controller.finish(jobID: jobID, with: .completed(completedItems: []))
        await eventuallyOnMainActor {
            coordinator.jobs.first { $0.id == jobID }?.state == .completed
        }
        #expect(coordinator.jobs.count == 1)
    }

    @Test("[SESS-011] two engines have independent queues, limits, failures, and cancellation")
    func enginesAreIsolated() async throws {
        let firstController = ControlledTransferWorkerController()
        let secondController = ControlledTransferWorkerController()
        let first = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: firstController))
        let second = RemoteTransferEngine(workerFactory: ControlledTransferWorkerFactory(controller: secondController))
        let firstJob = try await first.enqueue(request())
        let secondJob = try await second.enqueue(request())
        await eventually {
            let firstStarted = await firstController.startedJobIDs()
            let secondStarted = await secondController.startedJobIDs()
            return firstStarted == [firstJob] && secondStarted == [secondJob]
        }

        let cancellation = Task { await first.cancel(jobID: firstJob) }
        await firstController.finish(jobID: firstJob, with: .cancelled(completedItems: []))
        await cancellation.value
        #expect((await first.snapshots()).first?.state == .cancelled)
        #expect((await second.snapshots()).first?.state == .preparing)

        await secondController.finish(jobID: secondJob, with: .completed(completedItems: []))
        await eventually { (await second.snapshots()).first?.state == .completed }
    }

    @Test("[FILE-XFER-001] Keep Both naming is deterministic and checks each candidate")
    func keepBothResolverUsesLosslessExtensionAndRawFallback() throws {
        let original = try RemotePathComponent(rawBytes: Array("report.txt".utf8))
        let existing = Set(["report copy.txt", "report copy 2.txt"])
        let candidate = try RemoteCollisionResolver.keepBothComponent(original: original) { component in
            !existing.contains(component.losslessString ?? "")
        }
        #expect(candidate.losslessString == "report copy 3.txt")

        let raw = try RemotePathComponent(rawBytes: [0xFF])
        let rawCandidate = try RemoteCollisionResolver.keepBothComponent(original: raw) { _ in true }
        #expect(rawCandidate.rawBytes == [0xFF] + Array(" copy".utf8))
    }

    private func enqueueJobs(count: Int, on engine: RemoteTransferEngine) async throws -> [UUID] {
        var identifiers: [UUID] = []
        identifiers.reserveCapacity(count)
        for _ in 0..<count {
            identifiers.append(try await engine.enqueue(request()))
        }
        return identifiers
    }

    private func request(itemCount: Int = 1) -> RemoteTransferRequest {
        RemoteTransferRequest(logicalItemKeys: (0..<itemCount).map { _ in RemoteTransferLogicalItemKey() })
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}

private actor ControlledTransferWorkerController {
    private var contexts: [RemoteTransferWorkerContext] = []
    private var activeJobs: Set<UUID> = []
    private var maximumActive = 0
    private var continuations: [UUID: CheckedContinuation<RemoteTransferWorkerOutcome, Never>] = [:]
    private var reporters: [UUID: @Sendable (RemoteTransferWorkerEvent) async -> Void] = [:]

    func run(
        context: RemoteTransferWorkerContext,
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        contexts.append(context)
        activeJobs.insert(context.jobID)
        maximumActive = max(maximumActive, activeJobs.count)
        reporters[context.jobID] = report
        return await withCheckedContinuation { continuation in
            continuations[context.jobID] = continuation
        }
    }

    func finish(jobID: UUID, with outcome: RemoteTransferWorkerOutcome) {
        activeJobs.remove(jobID)
        reporters.removeValue(forKey: jobID)
        continuations.removeValue(forKey: jobID)?.resume(returning: outcome)
    }

    func emit(jobID: UUID, _ event: RemoteTransferWorkerEvent) async {
        await reporters[jobID]?(event)
    }

    func startedJobIDs() -> [UUID] { contexts.map(\.jobID) }
    func startedContexts() -> [RemoteTransferWorkerContext] { contexts }
    func maximumActiveCount() -> Int { maximumActive }
}

private struct ControlledTransferWorkerFactory: RemoteTransferWorkerFactory {
    let controller: ControlledTransferWorkerController

    func makeWorker(for context: RemoteTransferWorkerContext) async throws -> any RemoteTransferWorker {
        ControlledTransferWorker(context: context, controller: controller)
    }
}

private struct ControlledTransferWorker: RemoteTransferWorker {
    let context: RemoteTransferWorkerContext
    let controller: ControlledTransferWorkerController

    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        await controller.run(context: context, report: report)
    }
}

private struct ImmediateTransferWorkerFactory: RemoteTransferWorkerFactory {
    func makeWorker(for context: RemoteTransferWorkerContext) async throws -> any RemoteTransferWorker {
        ImmediateTransferWorker(context: context)
    }
}

private struct ImmediateTransferWorker: RemoteTransferWorker {
    let context: RemoteTransferWorkerContext

    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        .completed(completedItems: Set(context.items.map(\.logicalItemKey)))
    }
}

private actor ManualTransferClock: RemoteTransferClock {
    private var value: UInt64 = 0
    func nowNanoseconds() -> UInt64 { value }
    func advance(nanoseconds: UInt64) { value += nanoseconds }
}

private actor BlockingTransferClock: RemoteTransferClock {
    private var continuation: CheckedContinuation<UInt64, Never>?
    private var requestObserved = false

    func nowNanoseconds() async -> UInt64 {
        requestObserved = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while !requestObserved {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume(returning: 0)
        continuation = nil
    }
}

private actor TransferConcurrencyProbe {
    private var activeCount = 0
    private var maximumActive = 0
    private var starts: [UUID] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enter(jobID: UUID) async {
        starts.append(jobID)
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        if activeCount == RemoteTransferEngine.maximumActiveWorkerCount {
            let waiters = entryWaiters
            entryWaiters = []
            waiters.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func leave() {
        activeCount -= 1
    }

    func startedJobIDs() -> [UUID] { starts }
    func maximumActiveCount() -> Int { maximumActive }
}

private struct YieldingTransferWorkerFactory: RemoteTransferWorkerFactory {
    let probe: TransferConcurrencyProbe

    func makeWorker(for context: RemoteTransferWorkerContext) async throws -> any RemoteTransferWorker {
        YieldingTransferWorker(context: context, probe: probe)
    }
}

private struct YieldingTransferWorker: RemoteTransferWorker {
    let context: RemoteTransferWorkerContext
    let probe: TransferConcurrencyProbe

    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        await probe.enter(jobID: context.jobID)
        for _ in 0..<3 {
            await Task.yield()
        }
        await probe.leave()
        return .completed(completedItems: Set(context.items.map(\.logicalItemKey)))
    }
}

@MainActor
private final class TransferPublicationRecorder {
    private(set) var publications: [[RemoteTransferJobSnapshot]] = []
    var publicationCount: Int { publications.count }
    func record(_ snapshots: [RemoteTransferJobSnapshot]) { publications.append(snapshots) }
}

private func eventually(
    limit: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<limit {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}

@MainActor
private func eventuallyOnMainActor(
    limit: Int = 2_000,
    _ condition: () -> Bool
) async {
    for _ in 0..<limit {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Main-actor condition did not become true")
}
