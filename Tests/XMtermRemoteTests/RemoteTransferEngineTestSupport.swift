import Foundation

@testable import XMtermRemote

actor BlockingTransferClock: RemoteTransferClock {
    private var continuation: CheckedContinuation<UInt64, Never>?
    private var requestObserved = false
    private var shouldBlockNextRequest = false
    private var immediateRequestsBeforeBlock = 0

    func nowNanoseconds() async -> UInt64 {
        guard shouldBlockNextRequest else { return 0 }
        if immediateRequestsBeforeBlock > 0 {
            immediateRequestsBeforeBlock -= 1
            return 0
        }
        shouldBlockNextRequest = false
        requestObserved = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func armNextRequest() {
        arm(afterImmediateRequests: 0)
    }

    func arm(afterImmediateRequests count: Int) {
        requestObserved = false
        shouldBlockNextRequest = true
        immediateRequestsBeforeBlock = count
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

actor ControlledTransferWorkerController {
    private var started: [RemoteTransferWorkerContext] = []
    private var activeJobs: Set<UUID> = []
    private var maximumActive = 0
    private var holdsCancellationSettlement = false
    private var cancellationRequests: Set<UUID> = []
    private var continuations: [UUID: CheckedContinuation<RemoteTransferWorkerOutcome, Never>] = [:]
    private var reporters: [UUID: @Sendable (RemoteTransferWorkerEvent) async -> Void] = [:]

    func run(
        context: RemoteTransferWorkerContext,
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        started.append(context)
        activeJobs.insert(context.jobID)
        maximumActive = max(maximumActive, activeJobs.count)
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

    func finish(jobID: UUID, with outcome: RemoteTransferWorkerOutcome) {
        activeJobs.remove(jobID)
        reporters.removeValue(forKey: jobID)
        continuations.removeValue(forKey: jobID)?.resume(returning: outcome)
    }

    func emit(jobID: UUID, _ event: RemoteTransferWorkerEvent) async {
        await reporters[jobID]?(event)
    }

    func startedJobIDs() -> [UUID] { started.map(\.jobID) }
    func startedContexts() -> [RemoteTransferWorkerContext] { started }
    func startedContextCount() -> Int { started.count }
    func maximumActiveCount() -> Int { maximumActive }
    func holdCancellationSettlement() { holdsCancellationSettlement = true }

    private func cancel(context: RemoteTransferWorkerContext) {
        guard !holdsCancellationSettlement else { return }
        activeJobs.remove(context.jobID)
        reporters.removeValue(forKey: context.jobID)
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

struct ControlledTransferWorkerFactory: RemoteTransferWorkerFactory {
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
