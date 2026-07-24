import Foundation
public actor RemoteTransferEngine {
    public static let maximumNonterminalJobCount = RemoteTransferBounds.maximumNonterminalJobs
    public static let maximumTerminalRecordCount = RemoteTransferBounds.maximumTerminalRecords
    public static let maximumActiveWorkerCount = 2
    public static let maximumLogicalItemCount = RemoteTransferBounds.maximumTopLevelRequestedItemsPerJob
    public static let minimumProgressPublicationIntervalNanoseconds: UInt64 = 100_000_000

    public typealias Publication = @MainActor @Sendable ([RemoteTransferJobSnapshot]) -> Void
    struct JobRecord {
        let sequence: UInt64
        let request: RemoteTransferRequest
        var attempt: RemoteTransferAttemptIdentity
        var attemptItems: [RemoteTransferAttemptItem]
        var checkpointManifest: RemoteTransferCheckpointManifest
        var collision: RemoteTransferCollision?
        var resolvedCollision: RemoteTransferResolvedCollision?
        var applyToAllResolution: RemoteTransferCollisionResolution?
        var requiresDestinationRevalidation: Bool
        var lastProgressPublicationNanoseconds: UInt64?
        var terminalSequence: UInt64?
        var settlementFailure: RemoteFileError?
        var snapshot: RemoteTransferJobSnapshot

        var id: UUID { request.id }
    }

    private struct ActiveWorker {
        let attempt: RemoteTransferAttemptIdentity
        var task: Task<Void, Never>?
    }
    private let workerFactory: any RemoteTransferWorkerFactory
    private let identifierGenerator: any RemoteTransferIdentifierGenerator
    private let clock: any RemoteTransferClock
    private let publication: Publication?
    private var records: [UUID: JobRecord] = [:]
    private var queue: [UUID] = []
    private var activeWorkers: [UUID: ActiveWorker] = [:]
    private var pendingAdmissions = 0
    private var retryReservations: Set<UUID> = []
    private var nextSequence: UInt64 = 0
    private var nextTerminalSequence: UInt64 = 0
    private var isShuttingDown = false
    public init(
        workerFactory: any RemoteTransferWorkerFactory,
        identifierGenerator: any RemoteTransferIdentifierGenerator = SystemRemoteTransferIdentifierGenerator(),
        clock: any RemoteTransferClock = SystemRemoteTransferClock(),
        publication: Publication? = nil
    ) {
        self.workerFactory = workerFactory
        self.identifierGenerator = identifierGenerator
        self.clock = clock
        self.publication = publication
    }

    @discardableResult
    public func enqueue(_ request: RemoteTransferRequest) async throws -> UUID {
        guard !isShuttingDown else {
            throw RemoteTransferEngineError.invalidState
        }
        try RemoteTransferEnginePolicy.validate(request)
        guard records[request.id] == nil else {
            throw RemoteTransferEngineError.identifierCollision
        }
        guard nonterminalRecordCount + pendingAdmissions < Self.maximumNonterminalJobCount else {
            throw RemoteTransferEngineError.queueCapacityExceeded
        }
        pendingAdmissions += 1
        defer { pendingAdmissions -= 1 }

        let attempt = try RemoteTransferAttemptIdentity(
            id: await identifierGenerator.nextIdentifier(),
            generation: 1
        )
        let attemptItems = try await makeAttemptItems(for: request.logicalItemKeys)
        let now = await clock.nowNanoseconds()
        guard !isShuttingDown else {
            throw RemoteTransferEngineError.invalidState
        }
        guard records[request.id] == nil else {
            throw RemoteTransferEngineError.identifierCollision
        }
        let snapshot = try RemoteTransferSnapshotProjection.initial(
            request: request,
            attempt: attempt,
            now: now
        )
        let record = JobRecord(
            sequence: try takeNextSequence(),
            request: request,
            attempt: attempt,
            attemptItems: attemptItems,
            checkpointManifest: .empty,
            collision: nil,
            resolvedCollision: nil,
            applyToAllResolution: nil,
            requiresDestinationRevalidation: false,
            lastProgressPublicationNanoseconds: nil,
            terminalSequence: nil,
            settlementFailure: nil,
            snapshot: snapshot
        )
        try commit(record)
        queue = insertingInOriginalOrder(request.id, into: queue)
        await publishSnapshots()
        await pumpQueue()
        return request.id
    }

    public func snapshots() -> [RemoteTransferJobSnapshot] {
        orderedRecords.map(\.snapshot)
    }

    public func resolveCollision(
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity,
        resolution: RemoteTransferCollisionResolution
    ) async throws {
        guard var record = records[jobID] else {
            throw RemoteTransferEngineError.jobNotFound
        }
        guard record.attempt == attempt,
              record.snapshot.state == .conflict,
              record.collision != nil else {
            throw RemoteTransferEngineError.invalidState
        }
        if resolution.decision == .cancel {
            await cancel(jobID: jobID)
            return
        }
        let now = await clock.nowNanoseconds()
        guard let current = records[jobID],
              current.attempt == attempt,
              current.snapshot.state == .conflict,
              let collision = current.collision else {
            throw RemoteTransferEngineError.invalidState
        }
        record = current
        let resolvedCollision = RemoteTransferResolvedCollision(
            collision: collision,
            resolution: resolution
        )
        record.collision = nil
        record.resolvedCollision = resolvedCollision
        record.requiresDestinationRevalidation = true
        if resolution.applyToAll {
            record.applyToAllResolution = resolution
        }
        record.snapshot = try record.projectedSnapshot(
            state: .queued,
            runningPhase: nil,
            collision: nil,
            canRetry: false,
            now: now,
            settled: false
        )
        try commit(record)
        queue = insertingInOriginalOrder(jobID, into: queue)
        await publishSnapshots()
        await pumpQueue()
    }

    public func cancel(jobID: UUID) async {
        guard var record = records[jobID], !record.snapshot.state.isTerminal else { return }
        if record.snapshot.state == .cancelling {
            if let active = activeWorkers[jobID],
               active.attempt == record.attempt,
               let task = active.task {
                await task.value
            } else {
                await settleInactiveCancellation(jobID: jobID, attempt: record.attempt)
            }
            return
        }

        let attempt = record.attempt
        let now = await clock.nowNanoseconds()
        guard let current = records[jobID],
              current.attempt == attempt,
              !current.snapshot.state.isTerminal else { return }
        record = current
        if record.snapshot.state == .cancelling {
            if let task = activeWorkers[jobID]?.task {
                await task.value
            } else {
                await settleInactiveCancellation(jobID: jobID, attempt: attempt)
            }
            return
        }
        record.collision = nil
        do {
            record.snapshot = try record.projectedSnapshot(
                state: .cancelling,
                runningPhase: nil,
                collision: nil,
                canRetry: false,
                now: now,
                settled: false
            )
            try commit(record)
        } catch {
            await beginForcedSettlement(
                jobID: jobID,
                attempt: record.attempt,
                error: RemoteTransferEnginePolicy.normalized(error)
            )
            return
        }
        queue = queue.filter { $0 != jobID }
        let active = activeWorkers[jobID]
        active?.task?.cancel()
        await publishSnapshots()

        if let active, active.attempt == record.attempt, let task = active.task {
            await task.value
        } else {
            await settleInactiveCancellation(jobID: jobID, attempt: record.attempt)
        }
    }

    public func retry(jobID: UUID) async throws {
        guard !isShuttingDown else {
            throw RemoteTransferEngineError.invalidState
        }
        guard var record = records[jobID] else {
            throw RemoteTransferEngineError.jobNotFound
        }
        guard retryReservations.insert(jobID).inserted else {
            throw RemoteTransferEngineError.invalidState
        }
        defer { retryReservations.remove(jobID) }
        guard RemoteTransferEnginePolicy.isRetryable(record.snapshot.state) else {
            throw RemoteTransferEngineError.invalidState
        }
        guard record.checkpointManifest.cleanupEntries.isEmpty else {
            throw RemoteTransferEngineError.invalidState
        }

        let remainingKeys = RemoteTransferEnginePolicy.retryableTopLevelKeys(
            request: record.request,
            manifest: record.checkpointManifest
        )
        guard !remainingKeys.isEmpty else {
            throw RemoteTransferEngineError.invalidState
        }
        let previousAttempt = record.attempt
        let nextAttempt = try previousAttempt.nextAttempt(
            id: await identifierGenerator.nextIdentifier()
        )
        let attemptItems = try await makeAttemptItems(for: remainingKeys)
        let now = await clock.nowNanoseconds()
        guard !isShuttingDown,
              let current = records[jobID],
              current.attempt == previousAttempt,
              current.snapshot.state == record.snapshot.state else {
            throw RemoteTransferEngineError.invalidState
        }
        record = current
        try record.resetForRetry(
            attempt: nextAttempt,
            items: attemptItems,
            now: now
        )
        try commit(record)
        queue = insertingInOriginalOrder(jobID, into: queue)
        await publishSnapshots()
        await pumpQueue()
    }

    public func clearTerminalRecords() async {
        records = records.filter { !$0.value.snapshot.state.isTerminal }
        await publishSnapshots()
    }

    public func cancelAllAndSettle() async {
        if !isShuttingDown {
            isShuttingDown = true
            let targets = orderedRecords.filter { !$0.snapshot.state.isTerminal }.map(\.id)
            for jobID in targets {
                let now = await clock.nowNanoseconds()
                guard var record = records[jobID],
                      !record.snapshot.state.isTerminal else { continue }
                record.collision = nil
                do {
                    record.snapshot = try record.projectedSnapshot(
                        state: .cancelling,
                        runningPhase: nil,
                        collision: nil,
                        canRetry: false,
                        now: now,
                        settled: false
                    )
                    try commit(record)
                } catch {
                    record.settlementFailure = RemoteTransferEnginePolicy.normalized(error)
                    records[jobID] = record
                }
            }
            queue = []
            activeWorkers.values.forEach { $0.task?.cancel() }
            await publishSnapshots()
        }

        let activeTasks = activeWorkers.values.compactMap(\.task)
        activeTasks.forEach { $0.cancel() }
        for task in activeTasks {
            await task.value
        }
        let unsettled = orderedRecords.filter { $0.snapshot.state == .cancelling }
        for record in unsettled {
            await settleInactiveCancellation(jobID: record.id, attempt: record.attempt)
        }
    }

    func receive(
        _ event: RemoteTransferWorkerEvent,
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity
    ) async {
        guard var record = records[jobID],
              record.attempt == attempt,
              activeWorkers[jobID]?.attempt == attempt,
              record.snapshot.state != .cancelling,
              !record.snapshot.state.isTerminal else {
            return
        }

        do {
            switch event {
            case let .phase(phase):
                let changed = record.snapshot.state != .running
                    || record.snapshot.runningPhase != phase
                guard changed else { return }
                let now = await clock.nowNanoseconds()
                guard let current = activeRecord(jobID: jobID, attempt: attempt) else { return }
                record = current
                guard record.snapshot.state != .running
                    || record.snapshot.runningPhase != phase else { return }
                record.snapshot = try record.projectedSnapshot(
                    state: .running,
                    runningPhase: phase,
                    collision: nil,
                    canRetry: false,
                    now: now,
                    settled: false
                )
                try commit(record)
                await publishSnapshots()

            case let .currentItem(currentItem):
                guard record.snapshot.currentItemDisplay != currentItem else { return }
                let now = await clock.nowNanoseconds()
                guard let current = activeRecord(jobID: jobID, attempt: attempt) else { return }
                record = current
                guard record.snapshot.currentItemDisplay != currentItem else { return }
                let intervalElapsed = record.lastProgressPublicationNanoseconds.map {
                    now >= $0 && now - $0 >= Self.minimumProgressPublicationIntervalNanoseconds
                } ?? true
                if intervalElapsed {
                    record.lastProgressPublicationNanoseconds = now
                }
                record.snapshot = try record.projectedSnapshot(
                    state: record.snapshot.state,
                    runningPhase: record.snapshot.runningPhase,
                    currentItemDisplay: currentItem,
                    collision: record.snapshot.collision,
                    canRetry: false,
                    now: now,
                    settled: false
                )
                try commit(record)
                if intervalElapsed {
                    await publishSnapshots()
                }

            case let .progress(bytesCompleted, bytesTotal, itemsCompleted, itemsTotal):
                try await receiveProgress(
                    record: &record,
                    bytesCompleted: bytesCompleted,
                    bytesTotal: bytesTotal,
                    itemsCompleted: itemsCompleted,
                    itemsTotal: itemsTotal
                )
            }
        } catch {
            await beginForcedSettlement(
                jobID: jobID,
                attempt: attempt,
                error: RemoteTransferEnginePolicy.normalized(error)
            )
        }
    }

    func finish(
        _ outcome: RemoteTransferWorkerOutcome,
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity
    ) async {
        guard var record = records[jobID],
              record.attempt == attempt,
              activeWorkers[jobID]?.attempt == attempt else {
            return
        }
        activeWorkers = activeWorkers.filter { key, value in
            key != jobID || value.attempt != attempt
        }
        let now = await clock.nowNanoseconds()
        guard let current = records[jobID],
              current.attempt == attempt,
              !current.snapshot.state.isTerminal else {
            await pumpQueue()
            return
        }
        record = current

        do {
            if let settlementFailure = record.settlementFailure {
                try markTerminal(
                    &record,
                    state: .failed(settlementFailure),
                    itemFailures: [],
                    now: now
                )
            } else if record.snapshot.state == .cancelling {
                record.checkpointManifest = try RemoteTransferEnginePolicy.mergedManifest(
                    from: outcome,
                    request: record.request,
                    attempt: record.attempt
                )
                try markTerminal(&record, state: .cancelled, itemFailures: [], now: now)
            } else {
                try apply(outcome, to: &record, now: now)
            }
            try commit(record, shouldTrimTerminalRecords: record.snapshot.state.isTerminal)
        } catch {
            record = records[jobID] ?? record
            installFailClosed(
                record,
                error: RemoteTransferEnginePolicy.failClosedError(error),
                now: now
            )
        }
        await publishSnapshots()
        await pumpQueue()
    }

    private var orderedRecords: [JobRecord] {
        records.values.sorted { $0.sequence < $1.sequence }
    }

    private var nonterminalRecordCount: Int {
        records.values.lazy.filter { !$0.snapshot.state.isTerminal }.count
    }

    private func makeAttemptItems(
        for logicalKeys: [RemoteTransferLogicalItemKey]
    ) async throws -> [RemoteTransferAttemptItem] {
        var identifiers: Set<RemoteTransferAttemptItemID> = []
        var items: [RemoteTransferAttemptItem] = []
        items.reserveCapacity(logicalKeys.count)
        for logicalKey in logicalKeys {
            let identifier = RemoteTransferAttemptItemID(await identifierGenerator.nextIdentifier())
            guard identifiers.insert(identifier).inserted else {
                throw RemoteTransferEngineError.identifierCollision
            }
            items.append(
                RemoteTransferAttemptItem(
                    logicalItemKey: logicalKey,
                    attemptItemID: identifier
                )
            )
        }
        return items
    }

    private func takeNextSequence() throws -> UInt64 {
        let result = nextSequence.addingReportingOverflow(1)
        guard !result.overflow else {
            throw RemoteFileError(category: .limitExceeded)
        }
        let current = nextSequence
        nextSequence = result.partialValue
        return current
    }

    private func takeNextTerminalSequence() throws -> UInt64 {
        let result = nextTerminalSequence.addingReportingOverflow(1)
        guard !result.overflow else {
            throw RemoteFileError(category: .limitExceeded)
        }
        let current = nextTerminalSequence
        nextTerminalSequence = result.partialValue
        return current
    }

    private func insertingInOriginalOrder(_ jobID: UUID, into queue: [UUID]) -> [UUID] {
        (queue.filter { $0 != jobID } + [jobID]).sorted {
            (records[$0]?.sequence ?? UInt64.max) < (records[$1]?.sequence ?? UInt64.max)
        }
    }

    private func pumpQueue() async {
        guard !isShuttingDown else { return }
        while activeWorkers.count < Self.maximumActiveWorkerCount,
              let jobID = queue.first {
            queue = Array(queue.dropFirst())
            guard var record = records[jobID], record.snapshot.state == .queued else { continue }
            let now = await clock.nowNanoseconds()
            guard !isShuttingDown else { return }
            guard let current = records[jobID],
                  current.attempt == record.attempt,
                  current.snapshot.state == .queued else { continue }
            guard activeWorkers.count < Self.maximumActiveWorkerCount else {
                queue = insertingInOriginalOrder(jobID, into: queue)
                return
            }
            record = current
            let context = RemoteTransferWorkerContext(
                request: record.request,
                attempt: record.attempt,
                items: record.attemptItems,
                checkpointManifest: record.checkpointManifest,
                resolvedCollision: record.resolvedCollision,
                applyToAllResolution: record.applyToAllResolution,
                requiresDestinationRevalidation: record.requiresDestinationRevalidation
            )
            do {
                record.snapshot = try record.projectedSnapshot(
                    state: .preparing,
                    runningPhase: nil,
                    collision: nil,
                    canRetry: false,
                    now: now,
                    settled: false,
                    starting: true
                )
                record.resolvedCollision = nil
                record.requiresDestinationRevalidation = false
                try commit(record)
            } catch {
                installFailClosed(
                    record,
                    error: RemoteTransferEnginePolicy.failClosedError(error),
                    now: now
                )
                await publishSnapshots()
                continue
            }

            let factory = workerFactory
            activeWorkers[jobID] = ActiveWorker(attempt: record.attempt, task: nil)
            let task = Task { [self] in
                let outcome: RemoteTransferWorkerOutcome
                do {
                    let worker = try await factory.makeWorker(for: context)
                    outcome = await worker.run { [self] event in
                        await receive(event, jobID: context.jobID, attempt: context.attempt)
                    }
                } catch is CancellationError {
                    outcome = .cancelled(
                        completedItems: [],
                        checkpointManifest: context.checkpointManifest
                    )
                } catch let error as RemoteFileError {
                    outcome = .failed(
                        error: error,
                        itemFailures: [],
                        completedItems: [],
                        checkpointManifest: context.checkpointManifest
                    )
                } catch {
                    outcome = .failed(
                        error: RemoteFileError(category: .providerFailure),
                        itemFailures: [],
                        completedItems: [],
                        checkpointManifest: context.checkpointManifest
                    )
                }
                await finish(outcome, jobID: context.jobID, attempt: context.attempt)
            }
            activeWorkers[jobID]?.task = task
            await publishSnapshots()
        }
    }

    private func receiveProgress(
        record: inout JobRecord,
        bytesCompleted: UInt64,
        bytesTotal: UInt64?,
        itemsCompleted: Int,
        itemsTotal: Int?
    ) async throws {
        let now = await clock.nowNanoseconds()
        guard let current = records[record.id],
              current.attempt == record.attempt,
              activeWorkers[record.id]?.attempt == record.attempt,
              current.snapshot.state != .cancelling,
              !current.snapshot.state.isTerminal else {
            return
        }
        record = current
        guard let shouldPublish = try record.applyProgress(
            bytesCompleted: bytesCompleted,
            bytesTotal: bytesTotal,
            itemsCompleted: itemsCompleted,
            itemsTotal: itemsTotal,
            now: now
        ) else { return }
        try commit(record)
        if shouldPublish {
            await publishSnapshots()
        }
    }

    private func settleInactiveCancellation(
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity
    ) async {
        let now = await clock.nowNanoseconds()
        guard var record = records[jobID],
              record.attempt == attempt,
              record.snapshot.state == .cancelling,
              activeWorkers[jobID] == nil else {
            return
        }
        do {
            let state: RemoteTransferJobState = record.settlementFailure.map {
                .failed($0)
            } ?? .cancelled
            try markTerminal(&record, state: state, itemFailures: [], now: now)
            try commit(record, shouldTrimTerminalRecords: true)
        } catch {
            installFailClosed(
                record,
                error: RemoteTransferEnginePolicy.failClosedError(error),
                now: now
            )
        }
        await publishSnapshots()
        await pumpQueue()
    }

    private func beginForcedSettlement(
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity,
        error: RemoteFileError
    ) async {
        guard var record = records[jobID],
              record.attempt == attempt,
              !record.snapshot.state.isTerminal else {
            return
        }
        record.settlementFailure = RemoteTransferEnginePolicy.failClosedError(error)
        record.collision = nil
        do {
            try commit(record)
        } catch {
            records[jobID] = record
        }
        queue = queue.filter { $0 != jobID }
        activeWorkers[jobID]?.task?.cancel()
        let now = await clock.nowNanoseconds()
        guard let current = records[jobID],
              current.attempt == attempt,
              !current.snapshot.state.isTerminal else { return }
        record = current
        do {
            record.snapshot = try record.projectedSnapshot(
                state: .cancelling,
                runningPhase: nil,
                collision: nil,
                canRetry: false,
                now: now,
                settled: false
            )
            try commit(record)
        } catch {
            record.snapshot = RemoteTransferJobSnapshot(
                settlingFrom: record.snapshot,
                updatedAtNanoseconds: now
            )
            records[jobID] = record
        }
        let active = activeWorkers[jobID]
        await publishSnapshots()
        if active == nil {
            await settleInactiveCancellation(jobID: jobID, attempt: attempt)
        }
    }

    private func apply(
        _ outcome: RemoteTransferWorkerOutcome,
        to record: inout JobRecord,
        now: UInt64
    ) throws {
        let terminalSequence: UInt64?
        switch outcome.disposition {
        case .conflict: terminalSequence = nil
        case .completed, .cancelled, .failed:
            terminalSequence = try takeNextTerminalSequence()
        }
        try record.apply(outcome, now: now, terminalSequence: terminalSequence)
    }

    private func markTerminal(
        _ record: inout JobRecord,
        state: RemoteTransferJobState,
        itemFailures: [RemoteTransferItemFailure],
        now: UInt64,
        completedItemFloor: Int? = nil
    ) throws {
        try record.markTerminal(
            state: state,
            itemFailures: itemFailures,
            now: now,
            terminalSequence: try takeNextTerminalSequence(),
            completedItemFloor: completedItemFloor
        )
    }

    private func commit(
        _ record: JobRecord,
        shouldTrimTerminalRecords: Bool = false
    ) throws {
        var proposed = records
        proposed[record.id] = record
        if shouldTrimTerminalRecords {
            proposed = trimmingTerminalRecords(in: proposed)
        }
        try validateAggregate(proposed)
        records = proposed
    }

    private func installFailClosed(
        _ original: JobRecord,
        error: RemoteFileError,
        now: UInt64
    ) {
        var record = original
        let terminalSequence = nextTerminalSequence
        if nextTerminalSequence < UInt64.max {
            nextTerminalSequence += 1
        }
        record.failClosed(
            error: error,
            now: now,
            terminalSequence: terminalSequence
        )
        var proposed = records
        proposed[record.id] = record
        records = trimmingTerminalRecords(in: proposed)
    }

    private func trimmingTerminalRecords(
        in proposed: [UUID: JobRecord]
    ) -> [UUID: JobRecord] {
        let terminal = proposed.values
            .filter { $0.snapshot.state.isTerminal }
            .sorted {
                ($0.terminalSequence ?? UInt64.max) < ($1.terminalSequence ?? UInt64.max)
            }
        let excess = terminal.count - Self.maximumTerminalRecordCount
        guard excess > 0 else { return proposed }
        let removals = Set(terminal.prefix(excess).map(\.id))
        return proposed.filter { !removals.contains($0.key) }
    }

    private func validateAggregate(_ proposed: [UUID: JobRecord]) throws {
        try RemoteTransferRetainedStateValidator.validate(
            proposed.values.map { record in
                RemoteTransferRetainedJobState(
                    isTerminal: record.snapshot.state.isTerminal,
                    requestRetainedByteCount: record.request.retainedByteCount,
                    checkpointManifest: record.checkpointManifest,
                    snapshot: record.snapshot,
                    collisionRawByteCount: record.retainedCollisionByteCount,
                    settlementFailureByteCount: record.settlementFailure?.userFacingMessage.utf8.count ?? 0
                )
            }
        )
    }

    private func publishSnapshots() async {
        guard let publication else { return }
        await publication(snapshots())
    }

    private func activeRecord(
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity
    ) -> JobRecord? {
        guard let record = records[jobID],
              record.attempt == attempt,
              activeWorkers[jobID]?.attempt == attempt,
              record.snapshot.state != .cancelling,
              !record.snapshot.state.isTerminal else { return nil }
        return record
    }
}
