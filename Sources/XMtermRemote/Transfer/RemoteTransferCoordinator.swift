import Foundation
import Observation
import XMtermCore

@MainActor
@Observable
final class RemoteTransferPublishedState {
    var jobs: [RemoteTransferJobSnapshot] = []
}

@MainActor
@Observable
public final class RemoteTransferCoordinator {
    public let owner: RemoteTransferOwnerIdentity

    public var jobs: [RemoteTransferJobSnapshot] {
        publishedState.jobs
    }

    @ObservationIgnored private let engine: RemoteTransferEngine
    @ObservationIgnored private let publishedState: RemoteTransferPublishedState
    @ObservationIgnored private var isClosing = false

    public init(
        owner: RemoteTransferOwnerIdentity = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        ),
        workerFactory: any RemoteTransferWorkerFactory,
        identifierGenerator: any RemoteTransferIdentifierGenerator = SystemRemoteTransferIdentifierGenerator(),
        clock: any RemoteTransferClock = SystemRemoteTransferClock()
    ) {
        self.owner = owner
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
        guard !isClosing else {
            throw RemoteTransferEngineError.invalidState
        }
        guard request.owner == owner else {
            throw RemoteTransferEngineError.invalidRequest
        }
        return try await engine.enqueue(request)
    }

    public func cancel(jobID: UUID) async {
        await engine.cancel(jobID: jobID)
    }

    public func retry(jobID: UUID) async throws {
        try await engine.retry(jobID: jobID)
    }

    public func resolveCollision(
        jobID: UUID,
        attempt: RemoteTransferAttemptIdentity,
        resolution: RemoteTransferCollisionResolution
    ) async throws {
        try await engine.resolveCollision(
            jobID: jobID,
            attempt: attempt,
            resolution: resolution
        )
    }

    public func clearTerminalRecords() async {
        await engine.clearTerminalRecords()
    }

    public func close() async {
        isClosing = true
        await engine.cancelAllAndSettle()
    }

    package func beginClosing() {
        isClosing = true
    }
}
