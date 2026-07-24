import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote transfer engine repaired contract", .serialized)
struct RemoteTransferEngineContractTests {
    @Test("[APP-008, FILE-XFER-001] item totals and current item share the 10 Hz progress cadence")
    @MainActor
    func allOrdinaryProgressIsCoalescedToTenHertz() async throws {
        let clock = ContractTransferClock(now: 1_000)
        let recorder = ContractPublicationRecorder()
        let controller = ContractWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller),
            clock: clock,
            publication: { snapshots in recorder.record(snapshots) }
        )
        let jobID = try await engine.enqueue(contractRequest())
        await contractEventually { await controller.contexts().count == 1 }

        let beforeProgress = recorder.count
        await controller.emit(
            jobID: jobID,
            event: .progress(
                bytesCompleted: 1,
                bytesTotal: 100,
                itemsCompleted: 0,
                itemsTotal: 2
            )
        )
        #expect(recorder.count == beforeProgress + 1)
        await controller.emit(
            jobID: jobID,
            event: .progress(
                bytesCompleted: 2,
                bytesTotal: 200,
                itemsCompleted: 1,
                itemsTotal: 3
            )
        )
        await controller.emit(
            jobID: jobID,
            event: .currentItem(try RemoteTransferPresentationText("second.txt"))
        )
        #expect(recorder.count == beforeProgress + 1)

        let retained = try #require((await engine.snapshots()).first)
        #expect(retained.bytesCompleted == 2)
        #expect(retained.bytesTotal == 200)
        #expect(retained.itemsCompleted == 1)
        #expect(retained.itemsTotal == 3)
        #expect(retained.currentItemDisplay?.value == "second.txt")

        await clock.advance(100_000_000)
        await controller.emit(
            jobID: jobID,
            event: .currentItem(try RemoteTransferPresentationText("third.txt"))
        )
        #expect(recorder.count == beforeProgress + 2)
        #expect(recorder.latest?.first?.currentItemDisplay?.value == "third.txt")
        await engine.cancelAllAndSettle()
    }

    @Test("[FILE-XFER-001, FILE-XFER-004] snapshots are complete, bounded, redacted, and timestamped")
    func snapshotProjectionExcludesExecutionSecretsAndUsesMonotonicTimestamps() async throws {
        let clock = ContractTransferClock(now: 10)
        let controller = ContractWorkerController()
        let request = try secretBearingRequest()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller),
            clock: clock
        )
        let jobID = try await engine.enqueue(request)
        await contractEventually { await controller.contexts().count == 1 }
        await clock.advance(5)
        await controller.emit(jobID: jobID, event: .phase(.transferring))
        await controller.emit(
            jobID: jobID,
            event: .currentItem(try RemoteTransferPresentationText("visible item"))
        )

        let snapshot = try #require((await engine.snapshots()).first)
        #expect(snapshot.id == request.id)
        #expect(snapshot.kind == .download)
        #expect(snapshot.attempt.generation == 1)
        #expect(snapshot.sourceSummary.value.contains("Reviewed server"))
        #expect(snapshot.destinationSummary.value == "Downloads")
        #expect(snapshot.state == .running)
        #expect(snapshot.runningPhase == .transferring)
        #expect(snapshot.currentItemDisplay?.value == "visible item")
        #expect(snapshot.timestamps.createdAtNanoseconds == 10)
        #expect(snapshot.timestamps.startedAtNanoseconds == 10)
        #expect(snapshot.timestamps.updatedAtNanoseconds == 15)
        #expect(snapshot.timestamps.settledAtNanoseconds == nil)

        let reflected = String(reflecting: snapshot)
        #expect(!reflected.contains("CONNECTION-SECRET"))
        #expect(!reflected.contains("RESOURCE-SECRET"))
        #expect(!reflected.contains("BOOKMARK-SECRET"))
        await engine.cancelAllAndSettle()
    }

    @Test("[FILE-XFER-003] foreign checkpoint keys and stale cleanup attempts fail closed without crashing")
    func foreignManifestIdentityFailsClosedAndEngineRemainsUsable() async throws {
        let controller = ContractWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller)
        )
        let firstRequest = contractRequest()
        let secondRequest = contractRequest()
        let firstID = try await engine.enqueue(firstRequest)
        let secondID = try await engine.enqueue(secondRequest)
        await contractEventually { await controller.contexts().count == 2 }
        let contexts = await controller.contexts()
        let secondContext = try #require(contexts.first { $0.jobID == secondID })

        let foreignKey = try RemoteTransferWorkItemKey(
            topLevelKey: RemoteTransferLogicalItemKey(),
            relativeRawComponents: []
        )
        let foreignManifest = try RemoteTransferCheckpointManifest(
            checkpoints: [RemoteTransferCheckpoint(key: foreignKey, disposition: .unstarted)],
            cleanupEntries: []
        )
        await controller.finish(
            jobID: firstID,
            outcome: .failed(
                error: .init(category: .timeout),
                itemFailures: [],
                completedItems: [],
                checkpointManifest: foreignManifest
            )
        )

        let validKey = try RemoteTransferWorkItemKey(
            topLevelKey: secondRequest.logicalItemKeys[0],
            relativeRawComponents: []
        )
        let staleAttempt = try RemoteTransferAttemptIdentity(
            id: UUID(),
            generation: secondContext.attempt.generation
        )
        let staleCleanupManifest = try RemoteTransferCheckpointManifest(
            checkpoints: [],
            cleanupEntries: [
                RemoteTransferCleanupEntry(
                    attempt: staleAttempt,
                    workItemKey: validKey,
                    location: .remote(endpointID: UUID(), path: .root)
                )
            ]
        )
        await controller.finish(
            jobID: secondID,
            outcome: .failed(
                error: .init(category: .timeout),
                itemFailures: [],
                completedItems: [],
                checkpointManifest: staleCleanupManifest
            )
        )
        await contractEventually { (await engine.snapshots()).allSatisfy(\.state.isTerminal) }

        for snapshot in await engine.snapshots() {
            guard case let .failed(error) = snapshot.state else {
                Issue.record("Foreign manifest identity did not fail closed")
                continue
            }
            #expect(error.category == .malformedResponse)
        }

        let followUpID = try await engine.enqueue(contractRequest())
        await contractEventually {
            await controller.contexts().contains { $0.jobID == followUpID }
        }
        await engine.cancelAllAndSettle()
    }

    @Test("[FILE-XFER-003] completed disposition commits every requested top-level key")
    func completedOutcomeProducesCommittedManifestTruth() throws {
        let request = contractRequest(itemCount: 3)
        let attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)
        let outcome = RemoteTransferWorkerOutcome.completed(
            completedItems: [],
            checkpointManifest: .empty
        )

        let manifest = try RemoteTransferEnginePolicy.mergedManifest(
            from: outcome,
            request: request,
            attempt: attempt
        )

        #expect(manifest.checkpoints.map(\.key.topLevelKey) == request.logicalItemKeys)
        #expect(manifest.checkpoints.allSatisfy {
            if case .committed = $0.disposition { return true }
            return false
        })

        let foreignKey = try RemoteTransferWorkItemKey(
            topLevelKey: RemoteTransferLogicalItemKey(),
            relativeRawComponents: []
        )
        let foreignCleanup = try RemoteTransferCheckpointManifest(
            checkpoints: [],
            cleanupEntries: [
                RemoteTransferCleanupEntry(
                    attempt: attempt,
                    workItemKey: foreignKey,
                    location: .remote(endpointID: UUID(), path: .root)
                )
            ]
        )
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferEnginePolicy.mergedManifest(
                from: .failed(
                    error: .init(category: .timeout),
                    itemFailures: [],
                    completedItems: [],
                    checkpointManifest: foreignCleanup
                ),
                request: request,
                attempt: attempt
            )
        }
    }

    @Test("[FILE-XFER-003] outcome dispositions cannot contradict descendant checkpoints")
    func outcomeDispositionRejectsContradictoryDescendantCheckpoints() throws {
        let request = contractRequest()
        let logicalKey = request.logicalItemKeys[0]
        let attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)
        let descendant = try RemoteTransferWorkItemKey(
            topLevelKey: logicalKey,
            relativeRawComponents: [
                try RemotePathComponent(rawBytes: Array("child".utf8))
            ]
        )
        let committed = try RemoteTransferCheckpointManifest(
            checkpoints: [RemoteTransferCheckpoint(key: descendant, disposition: .committed)],
            cleanupEntries: []
        )
        let unfinished = try RemoteTransferCheckpointManifest(
            checkpoints: [RemoteTransferCheckpoint(key: descendant, disposition: .unstarted)],
            cleanupEntries: []
        )
        let collision = RemoteTransferCollision(
            logicalItemKey: logicalKey,
            destination: try RemotePath(rawBytes: Array("/tmp/existing".utf8))
        )

        #expect(throws: RemoteFileError.self) {
            try RemoteTransferEnginePolicy.mergedManifest(
                from: .failed(
                    error: RemoteFileError(category: .timeout),
                    itemFailures: [
                        RemoteTransferItemFailure(
                            logicalItemKey: logicalKey,
                            error: RemoteFileError(category: .timeout)
                        )
                    ],
                    completedItems: [],
                    checkpointManifest: committed
                ),
                request: request,
                attempt: attempt
            )
        }
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferEnginePolicy.mergedManifest(
                from: .conflict(
                    collision: collision,
                    completedItems: [],
                    checkpointManifest: committed
                ),
                request: request,
                attempt: attempt
            )
        }
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferEnginePolicy.mergedManifest(
                from: .completed(completedItems: [], checkpointManifest: unfinished),
                request: request,
                attempt: attempt
            )
        }
    }

    @Test("[FILE-XFER-003] retry is blocked while prior-attempt cleanup remains unsettled")
    func retryRejectsUnsettledAttemptOwnedCleanup() async throws {
        let controller = ContractWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller)
        )
        let request = contractRequest()
        let jobID = try await engine.enqueue(request)
        await contractEventually { await controller.contexts().count == 1 }
        let first = try #require((await controller.contexts()).first)
        let workKey = try RemoteTransferWorkItemKey(
            topLevelKey: request.logicalItemKeys[0],
            relativeRawComponents: []
        )
        let manifest = try RemoteTransferCheckpointManifest(
            checkpoints: [RemoteTransferCheckpoint(key: workKey, disposition: .unstarted)],
            cleanupEntries: [
                RemoteTransferCleanupEntry(
                    attempt: first.attempt,
                    workItemKey: workKey,
                    location: .remote(
                        endpointID: UUID(),
                        path: try RemotePath(rawBytes: Array("/tmp/staging".utf8))
                    )
                )
            ]
        )
        await controller.finish(
            jobID: jobID,
            outcome: .failed(
                error: RemoteFileError(category: .timeout),
                itemFailures: [],
                completedItems: [],
                checkpointManifest: manifest
            )
        )
        await contractEventually { (await engine.snapshots()).first?.state.isTerminal == true }
        #expect((await engine.snapshots()).first?.canRetry == false)
        await #expect(throws: RemoteTransferEngineError.self) {
            try await engine.retry(jobID: jobID)
        }
        #expect(await controller.contexts().count == 1)
    }

    @Test("[FILE-XFER-003] failed work cannot also be committed")
    func contradictoryFailedOutcomeFailsClosedAndRemainsRetryable() async throws {
        let controller = ContractWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller)
        )
        let request = contractRequest()
        let jobID = try await engine.enqueue(request)
        await contractEventually { await controller.contexts().count == 1 }
        let key = request.logicalItemKeys[0]
        await controller.finish(
            jobID: jobID,
            outcome: .failed(
                error: RemoteFileError(category: .timeout),
                itemFailures: [
                    RemoteTransferItemFailure(
                        logicalItemKey: key,
                        error: RemoteFileError(category: .permissionDenied)
                    )
                ],
                completedItems: [key],
                checkpointManifest: .empty
            )
        )
        await contractEventually { (await engine.snapshots()).first?.state.isTerminal == true }
        let snapshot = try #require((await engine.snapshots()).first)
        guard case let .failed(error) = snapshot.state else {
            Issue.record("Contradictory failed outcome did not fail closed")
            return
        }
        #expect(error.category == .malformedResponse)
        try await engine.retry(jobID: jobID)
        await contractEventually { await controller.contexts().count == 2 }
        await engine.cancelAllAndSettle()
    }

    @Test("[FILE-XFER-001] conflicted work cannot also be committed")
    func contradictoryConflictOutcomeFailsClosed() async throws {
        let controller = ContractWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller)
        )
        let request = contractRequest()
        let jobID = try await engine.enqueue(request)
        await contractEventually { await controller.contexts().count == 1 }
        let key = request.logicalItemKeys[0]
        await controller.finish(
            jobID: jobID,
            outcome: .conflict(
                collision: RemoteTransferCollision(
                    logicalItemKey: key,
                    destination: try RemotePath(rawBytes: Array("/tmp/existing".utf8))
                ),
                completedItems: [key],
                checkpointManifest: .empty
            )
        )
        await contractEventually { (await engine.snapshots()).first?.state.isTerminal == true }
        guard case let .failed(error) = (await engine.snapshots()).first?.state else {
            Issue.record("Contradictory conflict outcome did not fail closed")
            return
        }
        #expect(error.category == .malformedResponse)
    }

    @Test("[FILE-XFER-003] stale collision decisions are rejected and atomic downgrade re-enters conflict")
    func staleDecisionAndAtomicReplaceDowngradeRemainConflictSafe() async throws {
        let controller = ContractWorkerController()
        let engine = RemoteTransferEngine(
            workerFactory: ContractWorkerFactory(controller: controller)
        )
        let request = contractRequest()
        let jobID = try await engine.enqueue(request)
        await contractEventually { await controller.contexts().count == 1 }
        let firstContext = try #require((await controller.contexts()).first)
        let collision = RemoteTransferCollision(
            logicalItemKey: request.logicalItemKeys[0],
            destination: try RemotePath(rawBytes: Array("/destination".utf8))
        )
        await controller.finish(
            jobID: jobID,
            outcome: .conflict(
                collision: collision,
                completedItems: [],
                checkpointManifest: .empty
            )
        )
        await contractEventually { (await engine.snapshots()).first?.state == .conflict }

        let stale = RemoteTransferAttemptIdentity(
            uncheckedID: firstContext.attempt.id,
            generation: firstContext.attempt.generation + 1
        )
        await #expect(throws: RemoteTransferEngineError.invalidState) {
            try await engine.resolveCollision(
                jobID: jobID,
                attempt: stale,
                resolution: .init(decision: .replace, applyToAll: false)
            )
        }
        try await engine.resolveCollision(
            jobID: jobID,
            attempt: firstContext.attempt,
            resolution: .init(decision: .replace, applyToAll: false)
        )
        await contractEventually { await controller.contexts().count == 2 }
        let resumed = try #require((await controller.contexts()).last)
        #expect(resumed.attempt == firstContext.attempt)
        #expect(resumed.requiresDestinationRevalidation)

        let downgrade = RemoteTransferCollision(
            logicalItemKey: request.logicalItemKeys[0],
            destination: try RemotePath(rawBytes: Array("/non-atomic-replace".utf8))
        )
        await controller.finish(
            jobID: jobID,
            outcome: .conflict(
                collision: downgrade,
                completedItems: [],
                checkpointManifest: resumed.checkpointManifest
            )
        )
        await contractEventually { (await engine.snapshots()).first?.state == .conflict }
        let snapshot = try #require((await engine.snapshots()).first)
        #expect(snapshot.attempt == firstContext.attempt)
        #expect(snapshot.collision?.destinationSummary.value.contains("non-atomic-replace") == true)
    }

    @Test("[APP-008] retained data validator enforces exact job and 64 MiB engine totals")
    func retainedBudgetsCountPrimaryFailureSettlementAndMaximumFailClosedReserve() throws {
        let maximumJob = RemoteTransferBounds.maximumJobRetainedByteCount
        let maximumEngine = RemoteTransferBounds.maximumEngineRetainedByteCount
        let targets = [maximumJob, maximumJob, maximumJob, maximumJob - 1_000, 1_000]
        var terminalJobs = try targets.map {
            try retainedJob(targetByteCount: $0, state: .completed)
        }
        try RemoteTransferRetainedStateValidator.validate(terminalJobs)
        #expect(targets.reduce(0, +) == maximumEngine)

        terminalJobs[4] = try retainedJob(targetByteCount: 1_001, state: .completed)
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferRetainedStateValidator.validate(terminalJobs)
        }

        let maximumDefaultFailureBytes = RemoteFileError.Category.allCases.reduce(0) {
            max($0, RemoteFileError(category: $1).userFacingMessage.utf8.count)
        }
        let nonterminalAtReserve = try retainedJob(
            targetByteCount: maximumJob - maximumDefaultFailureBytes,
            state: .running
        )
        try RemoteTransferRetainedStateValidator.validate([nonterminalAtReserve])
        let nonterminalOverReserve = try retainedJob(
            targetByteCount: maximumJob - maximumDefaultFailureBytes + 1,
            state: .running
        )
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferRetainedStateValidator.validate([nonterminalOverReserve])
        }

        let primaryError = RemoteFileError(
            category: .providerFailure,
            userFacingMessage: String(repeating: "E", count: 4_096)
        )
        let primaryFailureOver = try retainedJob(
            targetByteCount: maximumJob,
            state: .failed(primaryError),
            omitPrimaryFailureFromTarget: true
        )
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferRetainedStateValidator.validate([primaryFailureOver])
        }

        let settlementAtBoundary = try retainedJob(
            targetByteCount: maximumJob,
            state: .cancelling,
            settlementFailureByteCount: 4_096
        )
        try RemoteTransferRetainedStateValidator.validate([settlementAtBoundary])
        let settlementOver = try retainedJob(
            targetByteCount: maximumJob + 1,
            state: .cancelling,
            settlementFailureByteCount: 4_096
        )
        #expect(throws: RemoteFileError.self) {
            try RemoteTransferRetainedStateValidator.validate([settlementOver])
        }
    }

    private func contractRequest(itemCount: Int = 1) -> RemoteTransferRequest {
        RemoteTransferRequest(
            logicalItemKeys: (0..<itemCount).map { _ in RemoteTransferLogicalItemKey() }
        )
    }

    private func secretBearingRequest() throws -> RemoteTransferRequest {
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let endpoint = try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: try RemoteTransferPresentationText("Reviewed server"),
                kind: .packageTest
            ),
            trustedConnectionMaterial: ContractSecretMaterial(secret: "CONNECTION-SECRET")
        )
        let local = try RemoteTransferLocalFileIdentity(
            url: URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true),
            fileResourceIdentifier: Data("RESOURCE-SECRET".utf8),
            volumeIdentifier: nil,
            kind: .directory,
            observedSize: nil,
            observedModificationNanoseconds: nil,
            securityScopedBookmark: Data("BOOKMARK-SECRET".utf8)
        )
        return try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .download,
            requestedItems: [
                RemoteTransferRequestedItem(
                    logicalKey: RemoteTransferLogicalItemKey(),
                    source: .remote(
                        endpoint: endpoint,
                        path: try RemotePath(rawBytes: Array("/bounded/source".utf8))
                    )
                )
            ],
            destination: .localDirectory(local),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )
    }

    private func retainedJob(
        targetByteCount: Int,
        state: RemoteTransferJobState,
        settlementFailureByteCount: Int = 0,
        omitPrimaryFailureFromTarget: Bool = false
    ) throws -> RemoteTransferRetainedJobState {
        let source = try RemoteTransferPresentationText("s")
        let destination = try RemoteTransferPresentationText("d")
        let snapshot = try RemoteTransferJobSnapshot(
            id: UUID(),
            attempt: try RemoteTransferAttemptIdentity(id: UUID(), generation: 1),
            kind: .download,
            state: state,
            sourceSummary: source,
            destinationSummary: destination,
            currentItemDisplay: nil,
            canRetry: state.isTerminal,
            timestamps: try RemoteTransferTimestamps(
                createdAtNanoseconds: 1,
                startedAtNanoseconds: nil,
                updatedAtNanoseconds: 1,
                settledAtNanoseconds: state.isTerminal ? 1 : nil
            )
        )
        let primaryFailureBytes: Int
        if case let .failed(error) = state {
            primaryFailureBytes = error.userFacingMessage.utf8.count
        } else {
            primaryFailureBytes = 0
        }
        let chargedPrimary = omitPrimaryFailureFromTarget ? 0 : primaryFailureBytes
        let fixedBytes = source.value.utf8.count
            + destination.value.utf8.count
            + settlementFailureByteCount
            + chargedPrimary
        #expect(targetByteCount >= fixedBytes)
        return RemoteTransferRetainedJobState(
            isTerminal: state.isTerminal,
            requestRetainedByteCount: targetByteCount - fixedBytes,
            checkpointManifest: .empty,
            snapshot: snapshot,
            collisionRawByteCount: 0,
            settlementFailureByteCount: settlementFailureByteCount
        )
    }
}

private struct ContractSecretMaterial: RemoteTransferTrustedConnectionMaterial {
    let secret: String
    var retainedByteCount: Int { secret.utf8.count }
}

private actor ContractWorkerController {
    private var startedContexts: [RemoteTransferWorkerContext] = []
    private var cancellationRequests: Set<UUID> = []
    private var reporters: [UUID: @Sendable (RemoteTransferWorkerEvent) async -> Void] = [:]
    private var continuations: [UUID: CheckedContinuation<RemoteTransferWorkerOutcome, Never>] = [:]

    func run(
        context: RemoteTransferWorkerContext,
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        startedContexts.append(context)
        reporters[context.jobID] = report
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellationRequests.remove(context.jobID) != nil {
                    continuation.resume(returning: cancelledOutcome(context))
                } else {
                    continuations[context.jobID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(context: context) }
        }
    }

    func contexts() -> [RemoteTransferWorkerContext] { startedContexts }

    func emit(jobID: UUID, event: RemoteTransferWorkerEvent) async {
        await reporters[jobID]?(event)
    }

    func finish(jobID: UUID, outcome: RemoteTransferWorkerOutcome) {
        reporters[jobID] = nil
        continuations.removeValue(forKey: jobID)?.resume(returning: outcome)
    }

    private func cancel(context: RemoteTransferWorkerContext) {
        reporters[context.jobID] = nil
        if let continuation = continuations.removeValue(forKey: context.jobID) {
            continuation.resume(returning: cancelledOutcome(context))
        } else {
            cancellationRequests.insert(context.jobID)
        }
    }

    private func cancelledOutcome(
        _ context: RemoteTransferWorkerContext
    ) -> RemoteTransferWorkerOutcome {
        .cancelled(completedItems: [], checkpointManifest: context.checkpointManifest)
    }
}

private struct ContractWorkerFactory: RemoteTransferWorkerFactory {
    let controller: ContractWorkerController

    func makeWorker(for context: RemoteTransferWorkerContext) async throws -> any RemoteTransferWorker {
        ContractWorker(context: context, controller: controller)
    }
}

private struct ContractWorker: RemoteTransferWorker {
    let context: RemoteTransferWorkerContext
    let controller: ContractWorkerController

    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        await controller.run(context: context, report: report)
    }
}

private actor ContractTransferClock: RemoteTransferClock {
    private var value: UInt64

    init(now: UInt64) { value = now }

    func nowNanoseconds() -> UInt64 { value }

    func advance(_ nanoseconds: UInt64) {
        value += nanoseconds
    }
}

@MainActor
private final class ContractPublicationRecorder {
    private(set) var publications: [[RemoteTransferJobSnapshot]] = []
    var count: Int { publications.count }
    var latest: [RemoteTransferJobSnapshot]? { publications.last }

    func record(_ snapshots: [RemoteTransferJobSnapshot]) {
        publications.append(snapshots)
    }
}

private func contractEventually(
    limit: Int = 4_000,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<limit {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}
