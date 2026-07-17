import Testing

@testable import XMtermRemote

@Suite("Remote workspace lifecycle ownership")
@MainActor
struct RemoteWorkspaceLifecycleTests {
    @Test("[FILE-WORKSPACE-001, FILE-STATE-001] Close settles cancellation, provider shutdown, and cache release")
    func closeWaitsForProviderAndClearsOwnedState() async {
        let provider = ControllableRemoteFileProvider(
            suspendsCancelAll: true,
            suspendsClose: true
        )
        let workspace = RemoteWorkspace(provider: provider)
        workspace.start()
        let resolve = await provider.nextAttempt()

        let closeTask = Task { @MainActor in
            await workspace.close()
        }
        await eventually { workspace.availability == .closing }
        await eventually { (await provider.snapshot()).cancelAllCount == 1 }

        #expect(workspace.availability == .closing)
        #expect((await provider.snapshot()).cancelledRequestIDs == [resolve.requestID])
        await provider.releaseCancelAll()
        await eventually { (await provider.snapshot()).closeCount == 1 }
        #expect(workspace.availability == .closing)

        await provider.releaseClose()
        await closeTask.value

        #expect(workspace.availability == .closed)
        #expect(workspace.currentDirectory == nil)
        #expect(workspace.currentListing == nil)
        #expect(workspace.pendingDirectory == nil)
        #expect(workspace.directoryStates.isEmpty)
        #expect(workspace.cachedListingCount == 0)
    }

    @Test("[FILE-WORKSPACE-001] Start and close are idempotent and closed workspaces reject new work")
    func lifecycleCallsAreIdempotent() async {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)

        workspace.start()
        workspace.start()
        _ = await provider.nextAttempt()
        await workspace.close()
        await workspace.close()
        workspace.start()
        workspace.retry()
        workspace.cancelCurrentRequest()
        for _ in 0..<10 { await Task.yield() }

        let snapshot = await provider.snapshot()
        #expect(snapshot.attempts.count == 1)
        #expect(snapshot.cancelAllCount == 1)
        #expect(snapshot.closeCount == 1)
        #expect(workspace.availability == .closed)
    }

    @Test("[FILE-WORKSPACE-001] Separate workspaces never share provider or lifecycle state")
    func independentWorkspaceInstancesRemainIsolated() async throws {
        let firstProvider = ControllableRemoteFileProvider()
        let secondProvider = ControllableRemoteFileProvider()
        let first = RemoteWorkspace(provider: firstProvider)
        let second = RemoteWorkspace(provider: secondProvider)
        let firstDirectory = try remotePath("/first")
        let secondDirectory = try remotePath("/second")

        first.start()
        second.start()
        let firstResolve = await firstProvider.nextAttempt()
        let secondResolve = await secondProvider.nextAttempt()
        await firstProvider.succeedResolve(
            requestID: firstResolve.requestID,
            path: firstDirectory
        )
        await secondProvider.succeedResolve(
            requestID: secondResolve.requestID,
            path: secondDirectory
        )
        let firstList = await firstProvider.nextAttempt()
        let secondList = await secondProvider.nextAttempt()
        let firstListing = try RemoteDirectoryListing(
            directory: firstDirectory,
            entries: []
        )
        let secondListing = try RemoteDirectoryListing(
            directory: secondDirectory,
            entries: []
        )
        await firstProvider.succeedListing(
            requestID: firstList.requestID,
            listing: firstListing
        )
        await secondProvider.succeedListing(
            requestID: secondList.requestID,
            listing: secondListing
        )
        await eventually {
            first.availability == .available && second.availability == .available
        }

        #expect(first.id != second.id)
        #expect(first.currentDirectory == firstDirectory)
        #expect(second.currentDirectory == secondDirectory)
        await first.close()
        #expect(first.availability == .closed)
        #expect(second.availability == .available)
        #expect((await secondProvider.snapshot()).cancelAllCount == 0)
        await second.close()
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic lifecycle state")
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}
