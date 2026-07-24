import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote workspace transfer ownership")
@MainActor
struct RemoteWorkspaceTransferOwnershipTests {
    @Test("[SESS-011] every workspace owns exactly one coordinator with exact typed identity")
    func workspaceOwnsOneCoordinatorWithExactIdentity() {
        let workspaceID = RemoteWorkspaceID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let runtimeID = TerminalSessionID(
            rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: runtimeID,
            workspaceID: workspaceID
        )
        let workspace = RemoteWorkspace(
            id: workspaceID,
            composition: .unavailable(owner: owner)
        )

        #expect(workspace.id == workspaceID)
        #expect(workspace.transferOwner == owner)
        #expect(workspace.transfers.owner == owner)
        #expect(workspace.transferEndpoint == nil)
    }

    @Test("[SESS-011] two workspaces never share coordinator or owner identity")
    func twoWorkspacesAreTransferIsolated() {
        let first = makeUnavailableWorkspace()
        let second = makeUnavailableWorkspace()

        #expect(first !== second)
        #expect(first.transfers !== second.transfers)
        #expect(first.transferOwner != second.transferOwner)
    }

    @Test("[SESS-011] mismatched prebuilt owner fails transfer composition closed")
    func mismatchedWorkspaceIdentityFailsClosed() throws {
        let compositionWorkspaceID = RemoteWorkspaceID()
        let actualWorkspaceID = RemoteWorkspaceID()
        let runtimeID = TerminalSessionID()
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: runtimeID,
            workspaceID: compositionWorkspaceID
        )
        let composition = try RemoteProviderComposition.production(
            profile: .configAlias(alias: "fixture-host"),
            owner: owner,
            displayName: "Fixture SSH"
        )

        let workspace = RemoteWorkspace(
            id: actualWorkspaceID,
            composition: composition
        )

        #expect(workspace.id == actualWorkspaceID)
        #expect(workspace.transferOwner.runtimeID == runtimeID)
        #expect(workspace.transferOwner.workspaceID == actualWorkspaceID)
        #expect(workspace.transferEndpoint == nil)
        #expect(workspace.transferEndpointProviderFactory == nil)
    }

    @Test("[APP-007, SESS-011] close settles transfers before browsing and is concurrent-idempotent")
    func closeSettlesTransfersBeforeBrowsingExactlyOnce() async throws {
        let events = TransferCloseEventRecorder()
        let browsingProvider = TransferCloseBrowsingProvider(events: events)
        let workerController = TransferCloseWorkerController(events: events)
        let workspaceID = RemoteWorkspaceID()
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: workspaceID
        )
        let composition = RemoteProviderComposition.packageTest(
            browsingProvider,
            owner: owner,
            workerFactory: TransferCloseWorkerFactory(controller: workerController)
        )
        let workspace = RemoteWorkspace(id: workspaceID, composition: composition)
        let endpoint = try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText("Close fixture"),
                kind: .packageTest
            ),
            trustedConnectionMaterial: WorkspaceOwnershipTestMaterial()
        )

        _ = try await workspace.transfers.enqueue(
            try deleteRequest(owner: owner, endpoint: endpoint)
        )
        await eventually { await workerController.didStart }

        let firstClose = Task { @MainActor in await workspace.close() }
        let secondClose = Task { @MainActor in await workspace.close() }
        await eventually { await workerController.didObserveCancellation }

        #expect(workspace.availability == .closing)
        #expect(await browsingProvider.closeCount == 0)
        #expect(await events.values == [.transferStarted, .transferCancelling])

        await workerController.releaseSettlement()
        await firstClose.value
        await secondClose.value

        #expect(workspace.availability == .closed)
        #expect(await browsingProvider.closeCount == 1)
        #expect(
            await events.values
                == [.transferStarted, .transferCancelling, .transferSettled, .browsingClosed]
        )
        await #expect(throws: RemoteTransferEngineError.invalidState) {
            _ = try await workspace.transfers.enqueue(
                RemoteTransferRequest(logicalItemKeys: [RemoteTransferLogicalItemKey()])
            )
        }
    }

    @Test("[FILE-XFER-001, SESS-011] Task 3B production ownership remains mutation-fail-closed")
    func productionCoordinatorUsesUnavailableWorkerUntilTaskFour() async throws {
        let workspaceID = RemoteWorkspaceID()
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: workspaceID
        )
        let composition = try RemoteProviderComposition.production(
            profile: .configAlias(alias: "fixture-host"),
            owner: owner,
            displayName: "Fixture SSH"
        )
        let workspace = RemoteWorkspace(id: workspaceID, composition: composition)
        let endpoint = try #require(workspace.transferEndpoint)

        let jobID = try await workspace.transfers.enqueue(
            try deleteRequest(owner: owner, endpoint: endpoint)
        )
        await eventually {
            workspace.transfers.jobs.first { $0.id == jobID }?.state.isTerminal == true
        }

        guard case let .failed(error)? = workspace.transfers.jobs.first(where: {
            $0.id == jobID
        })?.state else {
            Issue.record("Expected the fail-closed worker to publish a typed failure")
            return
        }
        #expect(error.category == .transportUnavailable)
        await workspace.close()
    }

    @Test("[SESS-011] coordinator rejects a request owned by another runtime before admission")
    func coordinatorRejectsMismatchedRequestOwner() async throws {
        let workspace = makeUnavailableWorkspace()
        let wrongOwner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let wrongEndpoint = try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: wrongOwner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText("Wrong owner"),
                kind: .packageTest
            ),
            trustedConnectionMaterial: WorkspaceOwnershipTestMaterial()
        )

        await #expect(throws: RemoteTransferEngineError.invalidRequest) {
            _ = try await workspace.transfers.enqueue(
                try deleteRequest(owner: wrongOwner, endpoint: wrongEndpoint)
            )
        }
        #expect(workspace.transfers.jobs.isEmpty)
        await workspace.close()
    }

    private func makeUnavailableWorkspace() -> RemoteWorkspace {
        let workspaceID = RemoteWorkspaceID()
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: workspaceID
        )
        return RemoteWorkspace(
            id: workspaceID,
            composition: .unavailable(owner: owner)
        )
    }

    private func deleteRequest(
        owner: RemoteTransferOwnerIdentity,
        endpoint: RemoteTransferEndpointSnapshot
    ) throws -> RemoteTransferRequest {
        try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .delete,
            requestedItems: [
                RemoteTransferRequestedItem(
                    logicalKey: RemoteTransferLogicalItemKey(),
                    source: .remote(
                        endpoint: endpoint,
                        path: RemotePath(rawBytes: Array("/fixture-item".utf8))
                    )
                )
            ],
            destination: .none,
            collisionPolicy: .notApplicable,
            metadataPolicy: .notApplicable,
            symlinkPolicy: .operateOnLinkIdentity,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic transfer ownership state")
    }
}

private struct WorkspaceOwnershipTestMaterial: RemoteTransferTrustedConnectionMaterial {
    let retainedByteCount = 0
}

private enum TransferCloseEvent: Equatable, Sendable {
    case transferStarted
    case transferCancelling
    case transferSettled
    case browsingClosed
}

private actor TransferCloseEventRecorder {
    private var storedValues: [TransferCloseEvent] = []

    var values: [TransferCloseEvent] { storedValues }

    func append(_ value: TransferCloseEvent) {
        storedValues.append(value)
    }
}

private actor TransferCloseBrowsingProvider: RemoteFileProvider {
    private let events: TransferCloseEventRecorder
    private(set) var closeCount = 0

    init(events: TransferCloseEventRecorder) {
        self.events = events
    }

    func resolveInitialDirectory() async throws -> RemotePath { .root }

    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        try RemoteDirectoryListing(directory: path, entries: [])
    }

    func cancelAll() async {}

    func close() async {
        closeCount += 1
        await events.append(.browsingClosed)
    }
}

private actor TransferCloseWorkerController {
    private let events: TransferCloseEventRecorder
    private var settlement: CheckedContinuation<Void, Never>?
    private var settlementReleaseRequested = false
    private(set) var didStart = false
    private(set) var didObserveCancellation = false

    init(events: TransferCloseEventRecorder) {
        self.events = events
    }

    func run(
        checkpointManifest: RemoteTransferCheckpointManifest
    ) async -> RemoteTransferWorkerOutcome {
        didStart = true
        await events.append(.transferStarted)
        do {
            try await Task.sleep(for: .seconds(3_600))
        } catch {
            didObserveCancellation = true
            await events.append(.transferCancelling)
            await withCheckedContinuation { continuation in
                if settlementReleaseRequested {
                    settlementReleaseRequested = false
                    continuation.resume()
                } else {
                    settlement = continuation
                }
            }
        }
        await events.append(.transferSettled)
        return .cancelled(
            completedItems: [],
            checkpointManifest: checkpointManifest
        )
    }

    func releaseSettlement() {
        if let continuation = settlement {
            settlement = nil
            continuation.resume()
        } else {
            settlementReleaseRequested = true
        }
    }
}

private struct TransferCloseWorkerFactory: RemoteTransferWorkerFactory {
    let controller: TransferCloseWorkerController

    func makeWorker(
        for context: RemoteTransferWorkerContext
    ) async throws -> any RemoteTransferWorker {
        TransferCloseWorker(
            controller: controller,
            checkpointManifest: context.checkpointManifest
        )
    }
}

private struct TransferCloseWorker: RemoteTransferWorker {
    let controller: TransferCloseWorkerController
    let checkpointManifest: RemoteTransferCheckpointManifest

    func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        await controller.run(checkpointManifest: checkpointManifest)
    }
}
