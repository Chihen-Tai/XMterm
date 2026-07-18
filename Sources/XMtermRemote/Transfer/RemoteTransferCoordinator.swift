import Foundation
import Observation

@MainActor
@Observable
final class RemoteTransferPublishedState {
    var jobs: [RemoteTransferJobSnapshot] = []
}

@MainActor
@Observable
public final class RemoteTransferCoordinator {
    public var jobs: [RemoteTransferJobSnapshot] {
        publishedState.jobs
    }

    @ObservationIgnored private let engine: RemoteTransferEngine
    @ObservationIgnored private let publishedState: RemoteTransferPublishedState

    public init(
        workerFactory: any RemoteTransferWorkerFactory,
        identifierGenerator: any RemoteTransferIdentifierGenerator = SystemRemoteTransferIdentifierGenerator(),
        clock: any RemoteTransferClock = SystemRemoteTransferClock()
    ) {
        let state = RemoteTransferPublishedState()
        publishedState = state
        engine = RemoteTransferEngine(
            workerFactory: workerFactory,
            identifierGenerator: identifierGenerator,
            clock: clock,
            publication: { @MainActor [weak state] snapshots in
                state?.jobs = snapshots
            }
        )
    }

    @discardableResult
    public func enqueue(_ request: RemoteTransferRequest) async throws -> UUID {
        try await engine.enqueue(request)
    }

    public func cancel(jobID: UUID) async {
        await engine.cancel(jobID: jobID)
    }

    public func retry(jobID: UUID) async throws {
        try await engine.retry(jobID: jobID)
    }

    public func resolveCollision(
        jobID: UUID,
        resolution: RemoteTransferCollisionResolution
    ) async throws {
        try await engine.resolveCollision(jobID: jobID, resolution: resolution)
    }

    public func clearTerminalRecords() async {
        await engine.clearTerminalRecords()
    }

    public func close() async {
        await engine.cancelAllAndSettle()
    }
}
