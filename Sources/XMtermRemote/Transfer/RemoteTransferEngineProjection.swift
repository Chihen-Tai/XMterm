import Foundation

extension RemoteTransferEngine.JobRecord {
    var retainedCollisionByteCount: Int {
        guard let retained = collision ?? resolvedCollision?.collision else { return 0 }
        return retained.workItemKey.retainedByteCount + retained.destination.rawBytes.count
    }

    func projectedSnapshot(
        state: RemoteTransferJobState,
        runningPhase: RemoteTransferRunningPhase?,
        currentItemDisplay: RemoteTransferPresentationText? = nil,
        bytesCompleted: UInt64? = nil,
        bytesTotal: UInt64?? = nil,
        itemsCompleted: Int? = nil,
        itemsTotal: Int?? = nil,
        itemFailures: [RemoteTransferItemFailure]? = nil,
        collision: RemoteTransferCollisionSummary?,
        canRetry: Bool,
        now: UInt64,
        settled: Bool,
        starting: Bool = false
    ) throws -> RemoteTransferJobSnapshot {
        try RemoteTransferSnapshotProjection.updating(
            prior: snapshot,
            request: request,
            attempt: attempt,
            state: state,
            runningPhase: runningPhase,
            currentItemDisplay: currentItemDisplay,
            bytesCompleted: bytesCompleted,
            bytesTotal: bytesTotal,
            itemsCompleted: itemsCompleted,
            itemsTotal: itemsTotal,
            itemFailures: itemFailures,
            collision: collision,
            canRetry: canRetry,
            now: now,
            settled: settled,
            starting: starting
        )
    }

    mutating func failClosed(
        error: RemoteFileError,
        now: UInt64,
        terminalSequence: UInt64
    ) {
        collision = nil
        resolvedCollision = nil
        settlementFailure = nil
        self.terminalSequence = terminalSequence
        snapshot = RemoteTransferJobSnapshot(
            failClosedFrom: snapshot,
            error: error,
            updatedAtNanoseconds: now,
            canRetry: checkpointManifest.cleanupEntries.isEmpty
        )
    }

    mutating func markTerminal(
        state: RemoteTransferJobState,
        itemFailures: [RemoteTransferItemFailure],
        now: UInt64,
        terminalSequence: UInt64,
        completedItemFloor: Int?
    ) throws {
        collision = nil
        resolvedCollision = nil
        self.terminalSequence = terminalSequence
        let completed = max(snapshot.itemsCompleted, completedItemFloor ?? 0)
        let total = max(snapshot.itemsTotal ?? 0, completedItemFloor ?? 0)
        snapshot = try projectedSnapshot(
            state: state,
            runningPhase: nil,
            currentItemDisplay: nil,
            itemsCompleted: completed,
            itemsTotal: total == 0 ? snapshot.itemsTotal : total,
            itemFailures: itemFailures,
            collision: nil,
            canRetry: (state == .cancelled || state.isFailed)
                && checkpointManifest.cleanupEntries.isEmpty,
            now: now,
            settled: true
        )
        settlementFailure = nil
    }

    mutating func resetForRetry(
        attempt nextAttempt: RemoteTransferAttemptIdentity,
        items: [RemoteTransferAttemptItem],
        now: UInt64
    ) throws {
        attempt = nextAttempt
        attemptItems = items
        collision = nil
        resolvedCollision = nil
        requiresDestinationRevalidation = true
        lastProgressPublicationNanoseconds = nil
        terminalSequence = nil
        settlementFailure = nil
        snapshot = try RemoteTransferJobSnapshot(
            id: id,
            attempt: nextAttempt,
            kind: request.kind,
            state: .queued,
            sourceSummary: snapshot.sourceSummary,
            destinationSummary: snapshot.destinationSummary,
            currentItemDisplay: nil,
            canRetry: false,
            timestamps: try RemoteTransferTimestamps(
                createdAtNanoseconds: snapshot.timestamps.createdAtNanoseconds,
                startedAtNanoseconds: nil,
                updatedAtNanoseconds: max(now, snapshot.timestamps.updatedAtNanoseconds),
                settledAtNanoseconds: nil
            )
        )
    }

    mutating func applyProgress(
        bytesCompleted: UInt64,
        bytesTotal: UInt64?,
        itemsCompleted: Int,
        itemsTotal: Int?,
        now: UInt64
    ) throws -> Bool? {
        guard itemsCompleted >= 0, itemsTotal.map({ $0 >= 0 }) ?? true else {
            throw RemoteFileError(category: .invalidOperation)
        }
        let previous = snapshot
        let nextBytes = max(previous.bytesCompleted, bytesCompleted)
        let nextItems = max(previous.itemsCompleted, itemsCompleted)
        let nextBytesTotal = RemoteTransferEnginePolicy.monotonicTotal(
            previous: previous.bytesTotal,
            proposed: bytesTotal,
            completed: nextBytes
        )
        let nextItemsTotal = RemoteTransferEnginePolicy.monotonicTotal(
            previous: previous.itemsTotal,
            proposed: itemsTotal,
            completed: nextItems
        )
        guard nextBytes != previous.bytesCompleted
            || nextItems != previous.itemsCompleted
            || nextBytesTotal != previous.bytesTotal
            || nextItemsTotal != previous.itemsTotal else { return nil }
        let shouldPublish = lastProgressPublicationNanoseconds.map {
            now >= $0 && now - $0 >= RemoteTransferEngine.minimumProgressPublicationIntervalNanoseconds
        } ?? true
        if shouldPublish { lastProgressPublicationNanoseconds = now }
        snapshot = try projectedSnapshot(
            state: previous.state,
            runningPhase: previous.runningPhase,
            currentItemDisplay: previous.currentItemDisplay,
            bytesCompleted: nextBytes,
            bytesTotal: nextBytesTotal,
            itemsCompleted: nextItems,
            itemsTotal: nextItemsTotal,
            itemFailures: previous.itemFailures,
            collision: previous.collision,
            canRetry: false,
            now: now,
            settled: false
        )
        return shouldPublish
    }

    mutating func apply(
        _ outcome: RemoteTransferWorkerOutcome,
        now: UInt64,
        terminalSequence: UInt64?
    ) throws {
        checkpointManifest = try RemoteTransferEnginePolicy.mergedManifest(
            from: outcome,
            request: request,
            attempt: attempt
        )
        let validKeys = Set(request.logicalItemKeys)
        switch outcome.disposition {
        case .completed:
            attemptItems = []
            try markTerminal(
                state: .completed,
                itemFailures: [],
                now: now,
                terminalSequence: try requiredTerminalSequence(terminalSequence),
                completedItemFloor: request.logicalItemKeys.count
            )
        case let .conflict(nextCollision):
            guard validKeys.contains(nextCollision.logicalItemKey) else {
                throw RemoteFileError(category: .malformedResponse)
            }
            collision = nextCollision
            snapshot = try projectedSnapshot(
                state: .conflict,
                runningPhase: nil,
                collision: RemoteTransferCollisionSummary(nextCollision),
                canRetry: false,
                now: now,
                settled: false
            )
        case .cancelled:
            try markTerminal(
                state: .cancelled,
                itemFailures: [],
                now: now,
                terminalSequence: try requiredTerminalSequence(terminalSequence),
                completedItemFloor: nil
            )
        case let .failed(error, itemFailures):
            guard itemFailures.allSatisfy({ validKeys.contains($0.logicalItemKey) }) else {
                throw RemoteFileError(category: .malformedResponse)
            }
            try markTerminal(
                state: .failed(error),
                itemFailures: itemFailures,
                now: now,
                terminalSequence: try requiredTerminalSequence(terminalSequence),
                completedItemFloor: nil
            )
        }
    }

    private func requiredTerminalSequence(_ sequence: UInt64?) throws -> UInt64 {
        guard let sequence else { throw RemoteFileError(category: .invalidOperation) }
        return sequence
    }
}

package enum RemoteTransferSnapshotProjection {
    static func initial(
        request: RemoteTransferRequest,
        attempt: RemoteTransferAttemptIdentity,
        now: UInt64
    ) throws -> RemoteTransferJobSnapshot {
        try RemoteTransferJobSnapshot(
            id: request.id,
            attempt: attempt,
            kind: request.kind,
            state: .queued,
            sourceSummary: RemoteTransferPresentationText(bounding: sourceSummary(for: request)),
            destinationSummary: RemoteTransferPresentationText(bounding: destinationSummary(for: request)),
            currentItemDisplay: nil,
            canRetry: false,
            timestamps: try RemoteTransferTimestamps(
                createdAtNanoseconds: now,
                startedAtNanoseconds: nil,
                updatedAtNanoseconds: now,
                settledAtNanoseconds: nil
            )
        )
    }

    static func updating(
        prior: RemoteTransferJobSnapshot,
        request: RemoteTransferRequest,
        attempt: RemoteTransferAttemptIdentity,
        state: RemoteTransferJobState,
        runningPhase: RemoteTransferRunningPhase?,
        currentItemDisplay: RemoteTransferPresentationText?,
        bytesCompleted: UInt64?,
        bytesTotal: UInt64??,
        itemsCompleted: Int?,
        itemsTotal: Int??,
        itemFailures: [RemoteTransferItemFailure]?,
        collision: RemoteTransferCollisionSummary?,
        canRetry: Bool,
        now: UInt64,
        settled: Bool,
        starting: Bool
    ) throws -> RemoteTransferJobSnapshot {
        let updated = max(now, prior.timestamps.updatedAtNanoseconds)
        let startedAt = prior.timestamps.startedAtNanoseconds ?? (starting ? updated : nil)
        return try RemoteTransferJobSnapshot(
            id: request.id,
            attempt: attempt,
            kind: request.kind,
            state: state,
            runningPhase: runningPhase,
            sourceSummary: prior.sourceSummary,
            destinationSummary: prior.destinationSummary,
            currentItemDisplay: currentItemDisplay,
            bytesCompleted: bytesCompleted ?? prior.bytesCompleted,
            bytesTotal: bytesTotal ?? prior.bytesTotal,
            itemsCompleted: itemsCompleted ?? prior.itemsCompleted,
            itemsTotal: itemsTotal ?? prior.itemsTotal,
            itemFailures: itemFailures ?? prior.itemFailures,
            collision: collision,
            canRetry: canRetry,
            timestamps: try RemoteTransferTimestamps(
                createdAtNanoseconds: prior.timestamps.createdAtNanoseconds,
                startedAtNanoseconds: startedAt,
                updatedAtNanoseconds: updated,
                settledAtNanoseconds: settled ? updated : nil
            )
        )
    }

    private static func sourceSummary(for request: RemoteTransferRequest) -> String {
        guard let first = request.requestedItems.first else { return "No source" }
        let firstSummary: String
        switch first.source {
        case let .remote(endpoint, path):
            firstSummary = "\(endpoint.summary.displayName.value): \(path.escapedDisplayString)"
        case let .local(identity):
            firstSummary = identity.url.lastPathComponent
        }
        let remainder = request.requestedItems.count - 1
        return remainder == 0 ? firstSummary : "\(firstSummary) and \(remainder) more"
    }

    private static func destinationSummary(for request: RemoteTransferRequest) -> String {
        switch request.destination {
        case let .remoteDirectory(endpoint, path), let .remotePath(endpoint, path):
            return "\(endpoint.summary.displayName.value): \(path.escapedDisplayString)"
        case let .localDirectory(identity):
            return identity.url.lastPathComponent
        case .none:
            return "No separate destination"
        }
    }
}

package struct RemoteTransferRetainedJobState: Sendable {
    let isTerminal: Bool
    let requestRetainedByteCount: Int
    let checkpointManifest: RemoteTransferCheckpointManifest
    let snapshot: RemoteTransferJobSnapshot
    let collisionRawByteCount: Int
    let settlementFailureByteCount: Int
}

package enum RemoteTransferRetainedStateValidator {
    static func validate(_ jobs: [RemoteTransferRetainedJobState]) throws {
        var nonterminal = 0
        var terminal = 0
        var combinedRecords = 0
        var cleanupEntries = 0
        var retainedBytes = 0
        var failClosedCapacityBytes = 0
        let defaultFailureBytes = RemoteFileError.Category.allCases.reduce(0) { maximum, category in
            max(maximum, RemoteFileError(category: category).userFacingMessage.utf8.count)
        }
        for job in jobs {
            if job.isTerminal {
                terminal = try RemoteTransferAggregateCounts.checkedSum(terminal, 1)
            } else {
                nonterminal = try RemoteTransferAggregateCounts.checkedSum(nonterminal, 1)
            }
            let jobCombined = try RemoteTransferAggregateCounts.checkedSum(
                job.checkpointManifest.checkpoints.count,
                job.snapshot.itemFailures.count
            )
            _ = try RemoteTransferWorkRecordCounts(
                discoveredWorkItems: 0,
                checkpoints: job.checkpointManifest.checkpoints.count,
                itemFailures: job.snapshot.itemFailures.count
            )
            combinedRecords = try RemoteTransferAggregateCounts.checkedSum(
                combinedRecords,
                jobCombined
            )
            cleanupEntries = try RemoteTransferAggregateCounts.checkedSum(
                cleanupEntries,
                job.checkpointManifest.cleanupEntries.count
            )
            let jobBytes = try retainedByteCount(for: job)
            _ = try RemoteTransferRetainedDataBudget(
                jobRetainedByteCount: jobBytes,
                engineRetainedByteCount: jobBytes
            )
            retainedBytes = try RemoteTransferAggregateCounts.checkedSum(retainedBytes, jobBytes)
            let reserve = job.isTerminal || job.settlementFailureByteCount > 0
                ? 0
                : defaultFailureBytes
            let jobCapacityBytes = try RemoteTransferAggregateCounts.checkedSum(jobBytes, reserve)
            guard jobCapacityBytes <= RemoteTransferBounds.maximumJobRetainedByteCount else {
                throw RemoteFileError(category: .limitExceeded)
            }
            failClosedCapacityBytes = try RemoteTransferAggregateCounts.checkedSum(
                failClosedCapacityBytes,
                jobCapacityBytes
            )
        }
        _ = try RemoteTransferAggregateCounts(
            nonterminalJobs: nonterminal,
            terminalRecords: terminal,
            workCheckpointFailureRecords: combinedRecords,
            cleanupEntries: cleanupEntries
        )
        _ = try RemoteTransferRetainedDataBudget(
            jobRetainedByteCount: 0,
            engineRetainedByteCount: retainedBytes
        )
        guard failClosedCapacityBytes <= RemoteTransferBounds.maximumEngineRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
    }

    private static func retainedByteCount(for job: RemoteTransferRetainedJobState) throws -> Int {
        var total = try RemoteTransferAggregateCounts.checkedSum(
            job.requestRetainedByteCount,
            job.checkpointManifest.retainedByteCount
        )
        let presentationCounts = [
            job.snapshot.sourceSummary.value.utf8.count,
            job.snapshot.destinationSummary.value.utf8.count,
            job.snapshot.currentItemDisplay?.value.utf8.count ?? 0,
            job.snapshot.collision?.destinationSummary.value.utf8.count ?? 0,
            job.collisionRawByteCount,
            job.settlementFailureByteCount,
            stateFailureByteCount(job.snapshot.state)
        ]
        for count in presentationCounts {
            total = try RemoteTransferAggregateCounts.checkedSum(total, count)
        }
        for failure in job.snapshot.itemFailures {
            total = try RemoteTransferAggregateCounts.checkedSum(
                total,
                failure.error.userFacingMessage.utf8.count
            )
        }
        guard total <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        return total
    }

    private static func stateFailureByteCount(_ state: RemoteTransferJobState) -> Int {
        if case let .failed(error) = state {
            return error.userFacingMessage.utf8.count
        }
        return 0
    }
}
