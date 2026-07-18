import Foundation

public actor RemoteTransferEngine {
    public static let maximumNonterminalJobCount = 1_000
    public static let maximumTerminalRecordCount = 500
    public static let maximumActiveWorkerCount = 2
    public static let maximumLogicalItemCount = 20_000
    public static let minimumProgressPublicationIntervalNanoseconds: UInt64 = 100_000_000

    public typealias Publication = @MainActor @Sendable ([RemoteTransferJobSnapshot]) -> Void

    private struct JobRecord {
        let id: UUID
        let sequence: UInt64
        let request: RemoteTransferRequest
        var attemptID: UUID
        var attemptHistory: Set<UUID>
        var attemptItems: [RemoteTransferAttemptItem]
        var completedLogicalItems: Set<RemoteTransferLogicalItemKey>
        var state: RemoteTransferJobState
        var runningPhase: RemoteTransferRunningPhase?
        var bytesCompleted: UInt64
        var bytesTotal: UInt64?
        var itemsCompleted: Int
        var itemsTotal: Int?
        var itemFailures: [RemoteTransferItemFailure]
        var collision: RemoteTransferCollision?
        var collisionResolution: RemoteTransferCollisionResolution?
        var applyToAllDecision: RemoteTransferCollisionDecision?
        var requiresDestinationRevalidation: Bool
        var lastProgressPublicationNanoseconds: UInt64?
        var terminalSequence: UInt64?

        var snapshot: RemoteTransferJobSnapshot {
            RemoteTransferJobSnapshot(
                id: id,
                attemptID: attemptID,
                state: state,
                runningPhase: runningPhase,
                bytesCompleted: bytesCompleted,
                bytesTotal: bytesTotal,
                itemsCompleted: itemsCompleted,
                itemsTotal: itemsTotal,
                itemFailures: itemFailures,
                collision: collision
            )
        }
    }

    private struct ActiveWorker {
        let attemptID: UUID
        let task: Task<Void, Never>
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
        try validate(request)
        guard nonterminalRecordCount + pendingAdmissions < Self.maximumNonterminalJobCount else {
            throw RemoteTransferEngineError.queueCapacityExceeded
        }
        pendingAdmissions += 1
        defer { pendingAdmissions -= 1 }

        let jobID = await identifierGenerator.nextIdentifier()
        let attemptID = await identifierGenerator.nextIdentifier()
        let attemptItems = try await makeAttemptItems(for: request.logicalItemKeys)
        guard !isShuttingDown else {
            throw RemoteTransferEngineError.invalidState
        }
        guard records[jobID] == nil else {
            throw RemoteTransferEngineError.identifierCollision
        }
        let sequence = try takeNextSequence()
        let record = JobRecord(
            id: jobID,
            sequence: sequence,
            request: request,
            attemptID: attemptID,
            attemptHistory: [attemptID],
            attemptItems: attemptItems,
            completedLogicalItems: [],
            state: .queued,
            runningPhase: nil,
            bytesCompleted: 0,
            bytesTotal: nil,
            itemsCompleted: 0,
            itemsTotal: nil,
            itemFailures: [],
            collision: nil,
            collisionResolution: nil,
            applyToAllDecision: nil,
            requiresDestinationRevalidation: false,
            lastProgressPublicationNanoseconds: nil,
            terminalSequence: nil
        )
        records = records.merging([jobID: record]) { _, new in new }
        queue = insertingInOriginalOrder(jobID, into: queue)
        await publishSnapshots()
        await pumpQueue()
        return jobID
    }

    public func snapshots() -> [RemoteTransferJobSnapshot] {
        orderedRecords.map(\.snapshot)
    }

    public func resolveCollision(
        jobID: UUID,
        resolution: RemoteTransferCollisionResolution
    ) async throws {
        guard var record = records[jobID] else {
            throw RemoteTransferEngineError.jobNotFound
        }
        guard record.state == .conflict, record.collision != nil else {
            throw RemoteTransferEngineError.invalidState
        }
        if resolution.decision == .cancel {
            await cancel(jobID: jobID)
            return
        }
        record.state = .queued
        record.runningPhase = nil
        record.collision = nil
        record.collisionResolution = resolution
        record.requiresDestinationRevalidation = true
        if resolution.applyToAll {
            record.applyToAllDecision = resolution.decision
        }
        records = records.merging([jobID: record]) { _, new in new }
        queue = insertingInOriginalOrder(jobID, into: queue)
        await publishSnapshots()
        await pumpQueue()
    }

    public func cancel(jobID: UUID) async {
        guard var record = records[jobID], !record.state.isTerminal else { return }
        if record.state == .cancelling {
            if let active = activeWorkers[jobID], active.attemptID == record.attemptID {
                await active.task.value
            } else {
                await settleInactiveCancellation(jobID: jobID, attemptID: record.attemptID)
            }
            return
        }

        record.state = .cancelling
        record.runningPhase = nil
        record.collision = nil
        records = records.merging([jobID: record]) { _, new in new }
        queue = queue.filter { $0 != jobID }
        let active = activeWorkers[jobID]
        active?.task.cancel()
        await publishSnapshots()

        if let active, active.attemptID == record.attemptID {
            await active.task.value
            return
        }
        await settleInactiveCancellation(jobID: jobID, attemptID: record.attemptID)
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
        guard isRetryable(record.state) else {
            throw RemoteTransferEngineError.invalidState
        }
        guard nonterminalRecordCount + pendingAdmissions < Self.maximumNonterminalJobCount else {
            throw RemoteTransferEngineError.queueCapacityExceeded
        }
        let remainingKeys = record.request.logicalItemKeys.filter {
            !record.completedLogicalItems.contains($0)
        }
        guard !remainingKeys.isEmpty else {
            throw RemoteTransferEngineError.invalidState
        }
        pendingAdmissions += 1
        defer { pendingAdmissions -= 1 }

        let attemptID = await identifierGenerator.nextIdentifier()
        guard !record.attemptHistory.contains(attemptID) else {
            throw RemoteTransferEngineError.identifierCollision
        }
        let attemptItems = try await makeAttemptItems(for: remainingKeys)
        guard !isShuttingDown,
              let current = records[jobID], current.attemptID == record.attemptID,
              current.state == record.state else {
            throw RemoteTransferEngineError.invalidState
        }
        record = current
        record.attemptID = attemptID
        record.attemptHistory = record.attemptHistory.union([attemptID])
        record.attemptItems = attemptItems
        record.state = .queued
        record.runningPhase = nil
        record.bytesCompleted = 0
        record.bytesTotal = nil
        record.itemsCompleted = 0
        record.itemsTotal = nil
        record.itemFailures = []
        record.collision = nil
        record.collisionResolution = nil
        record.requiresDestinationRevalidation = true
        record.lastProgressPublicationNanoseconds = nil
        record.terminalSequence = nil
        records = records.merging([jobID: record]) { _, new in new }
        queue = insertingInOriginalOrder(jobID, into: queue)
        await publishSnapshots()
        await pumpQueue()
    }

    public func clearTerminalRecords() async {
        let terminalIDs = Set(records.values.filter { $0.state.isTerminal }.map(\.id))
        records = records.filter { !terminalIDs.contains($0.key) }
        await publishSnapshots()
    }

    public func cancelAllAndSettle() async {
        if !isShuttingDown {
            isShuttingDown = true
            let targets = orderedRecords.filter { !$0.state.isTerminal }.map(\.id)
            for jobID in targets {
                guard var record = records[jobID] else { continue }
                record.state = .cancelling
                record.runningPhase = nil
                record.collision = nil
                records = records.merging([jobID: record]) { _, new in new }
            }
            queue = []
            activeWorkers.values.forEach { $0.task.cancel() }
            await publishSnapshots()
        }

        let active = activeWorkers.values.map { $0 }
        active.forEach { $0.task.cancel() }
        for worker in active {
            await worker.task.value
        }
        let unsettled = orderedRecords.filter { $0.state == .cancelling }
        for record in unsettled {
            let jobID = record.id
            guard let record = records[jobID], record.state == .cancelling else { continue }
            await settleInactiveCancellation(jobID: jobID, attemptID: record.attemptID)
        }
    }

    func receive(
        _ event: RemoteTransferWorkerEvent,
        jobID: UUID,
        attemptID: UUID
    ) async {
        guard var record = records[jobID],
              record.attemptID == attemptID,
              activeWorkers[jobID]?.attemptID == attemptID,
              record.state != .cancelling,
              !record.state.isTerminal else {
            return
        }

        switch event {
        case let .phase(phase):
            let changed = record.state != .running || record.runningPhase != phase
            record.state = .running
            record.runningPhase = phase
            records = records.merging([jobID: record]) { _, new in new }
            if changed {
                await publishSnapshots()
            }

        case let .progress(bytesCompleted, bytesTotal, itemsCompleted, itemsTotal):
            let now = await clock.nowNanoseconds()
            guard var record = records[jobID],
                  record.attemptID == attemptID,
                  activeWorkers[jobID]?.attemptID == attemptID,
                  record.state != .cancelling,
                  !record.state.isTerminal else {
                return
            }
            let previousBytes = record.bytesCompleted
            let previousItems = record.itemsCompleted
            let previousBytesTotal = record.bytesTotal
            let previousItemsTotal = record.itemsTotal
            record.bytesCompleted = max(previousBytes, bytesCompleted)
            record.itemsCompleted = max(previousItems, max(0, itemsCompleted))
            record.bytesTotal = monotonicTotal(
                previous: previousBytesTotal,
                proposed: bytesTotal,
                completed: record.bytesCompleted
            )
            record.itemsTotal = monotonicTotal(
                previous: previousItemsTotal,
                proposed: itemsTotal.map { max(0, $0) },
                completed: record.itemsCompleted
            )
            let hasNonByteEdge = record.itemsCompleted != previousItems
                || record.bytesTotal != previousBytesTotal
                || record.itemsTotal != previousItemsTotal
            guard record.bytesCompleted != previousBytes || hasNonByteEdge else { return }
            let intervalElapsed = record.lastProgressPublicationNanoseconds.map {
                now >= $0 && now - $0 >= Self.minimumProgressPublicationIntervalNanoseconds
            } ?? true
            let shouldPublish = hasNonByteEdge || intervalElapsed
            if shouldPublish {
                record.lastProgressPublicationNanoseconds = now
            }
            records = records.merging([jobID: record]) { _, new in new }
            if shouldPublish {
                await publishSnapshots()
            }
        }
    }

    func finish(
        _ outcome: RemoteTransferWorkerOutcome,
        jobID: UUID,
        attemptID: UUID
    ) async {
        guard var record = records[jobID],
              record.attemptID == attemptID,
              activeWorkers[jobID]?.attemptID == attemptID else {
            return
        }
        activeWorkers = activeWorkers.filter { key, value in
            key != jobID || value.attemptID != attemptID
        }

        if record.state == .cancelling {
            record.completedLogicalItems = record.completedLogicalItems.union(
                completedItems(from: outcome).intersection(record.request.logicalItemKeys)
            )
            markTerminal(&record, state: .cancelled)
        } else {
            apply(outcome, to: &record)
        }
        records = records.merging([jobID: record]) { _, new in new }
        trimTerminalRecords()
        await publishSnapshots()
        await pumpQueue()
    }

    private var orderedRecords: [JobRecord] {
        records.values.sorted { $0.sequence < $1.sequence }
    }

    private var nonterminalRecordCount: Int {
        records.values.lazy.filter { !$0.state.isTerminal }.count
    }

    private func isRetryable(_ state: RemoteTransferJobState) -> Bool {
        if case .failed = state { return true }
        return state == .cancelled
    }

    private func validate(_ request: RemoteTransferRequest) throws {
        guard !request.logicalItemKeys.isEmpty,
              request.logicalItemKeys.count <= Self.maximumLogicalItemCount,
              Set(request.logicalItemKeys).count == request.logicalItemKeys.count else {
            throw RemoteTransferEngineError.invalidRequest
        }
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
        guard nextSequence < UInt64.max else {
            throw RemoteTransferEngineError.queueCapacityExceeded
        }
        let result = nextSequence
        nextSequence += 1
        return result
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
            guard var record = records[jobID], record.state == .queued else { continue }
            let context = RemoteTransferWorkerContext(
                jobID: record.id,
                attemptID: record.attemptID,
                items: record.attemptItems,
                excludedCompletedItems: record.request.logicalItemKeys.filter {
                    record.completedLogicalItems.contains($0)
                },
                collisionResolution: record.collisionResolution,
                applyToAllDecision: record.applyToAllDecision,
                requiresDestinationRevalidation: record.requiresDestinationRevalidation
            )
            record.state = .preparing
            record.runningPhase = nil
            record.collisionResolution = nil
            record.requiresDestinationRevalidation = false
            records = records.merging([jobID: record]) { _, new in new }

            let factory = workerFactory
            let task = Task { [self] in
                let outcome: RemoteTransferWorkerOutcome
                do {
                    let worker = try await factory.makeWorker(for: context)
                    outcome = await worker.run { [self] event in
                        await receive(event, jobID: context.jobID, attemptID: context.attemptID)
                    }
                } catch is CancellationError {
                    outcome = .cancelled(completedItems: [])
                } catch let error as RemoteFileError {
                    outcome = .failed(error: error, itemFailures: [], completedItems: [])
                } catch {
                    outcome = .failed(
                        error: RemoteFileError(category: .providerFailure),
                        itemFailures: [],
                        completedItems: []
                    )
                }
                await finish(outcome, jobID: context.jobID, attemptID: context.attemptID)
            }
            activeWorkers = activeWorkers.merging([
                jobID: ActiveWorker(attemptID: record.attemptID, task: task)
            ]) { _, new in new }
            await publishSnapshots()
        }
    }

    private func settleInactiveCancellation(jobID: UUID, attemptID: UUID) async {
        guard var record = records[jobID],
              record.attemptID == attemptID,
              record.state == .cancelling,
              activeWorkers[jobID] == nil else {
            return
        }
        markTerminal(&record, state: .cancelled)
        records = records.merging([jobID: record]) { _, new in new }
        trimTerminalRecords()
        await publishSnapshots()
        await pumpQueue()
    }

    private func apply(_ outcome: RemoteTransferWorkerOutcome, to record: inout JobRecord) {
        let validKeys = Set(record.request.logicalItemKeys)
        record.completedLogicalItems = record.completedLogicalItems.union(
            completedItems(from: outcome).intersection(validKeys)
        )
        switch outcome {
        case .completed:
            record.completedLogicalItems = record.completedLogicalItems.union(
                record.attemptItems.map(\.logicalItemKey)
            )
            record.itemsCompleted = max(record.itemsCompleted, record.attemptItems.count)
            record.itemsTotal = max(record.itemsTotal ?? 0, record.attemptItems.count)
            markTerminal(&record, state: .completed)

        case let .conflict(collision, _):
            guard validKeys.contains(collision.logicalItemKey) else {
                markTerminal(
                    &record,
                    state: .failed(RemoteFileError(category: .malformedResponse))
                )
                return
            }
            record.state = .conflict
            record.runningPhase = nil
            record.collision = collision

        case .cancelled:
            markTerminal(&record, state: .cancelled)

        case let .failed(error, failures, _):
            record.itemFailures = failures.filter { validKeys.contains($0.logicalItemKey) }
            markTerminal(&record, state: .failed(error))
        }
    }

    private func completedItems(
        from outcome: RemoteTransferWorkerOutcome
    ) -> Set<RemoteTransferLogicalItemKey> {
        switch outcome {
        case let .completed(items), let .cancelled(items):
            items
        case let .conflict(_, items), let .failed(_, _, items):
            items
        }
    }

    private func markTerminal(
        _ record: inout JobRecord,
        state: RemoteTransferJobState
    ) {
        record.state = state
        record.runningPhase = nil
        record.collision = nil
        record.collisionResolution = nil
        record.terminalSequence = nextTerminalSequence
        if nextTerminalSequence < UInt64.max {
            nextTerminalSequence += 1
        }
    }

    private func trimTerminalRecords() {
        let terminal = records.values
            .filter { $0.state.isTerminal }
            .sorted {
                ($0.terminalSequence ?? UInt64.max) < ($1.terminalSequence ?? UInt64.max)
            }
        let excess = terminal.count - Self.maximumTerminalRecordCount
        guard excess > 0 else { return }
        let removals = Set(terminal.prefix(excess).map(\.id))
        records = records.filter { !removals.contains($0.key) }
    }

    private func publishSnapshots() async {
        guard let publication else { return }
        await publication(snapshots())
    }

    private func monotonicTotal<T: FixedWidthInteger>(
        previous: T?,
        proposed: T?,
        completed: T
    ) -> T? {
        guard previous != nil || proposed != nil else { return nil }
        return max(previous ?? 0, proposed ?? 0, completed)
    }
}
