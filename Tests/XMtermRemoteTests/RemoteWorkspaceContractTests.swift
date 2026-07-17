import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote workspace provider and shutdown contract")
@MainActor
struct RemoteWorkspaceContractTests {
    @Test("Test fixture attempt waits settle when their task is cancelled")
    func controllableProviderAttemptWaitIsCancellationAware() async {
        let provider = ControllableRemoteFileProvider()
        let wait = Task { await provider.nextAttempt() }

        await Task.yield()
        wait.cancel()

        #expect(await wait.value == .cancelledWaiter)
    }

    @Test("[FILE-STATE-001] A wrong-directory response is a typed malformed failure")
    func malformedInitialListingIsRejected() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let requested = try remotePath("/requested")
        let wrong = try remotePath("/wrong")

        workspace.start()
        let resolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: resolve.requestID, path: requested)
        let list = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: list.requestID,
            listing: try RemoteDirectoryListing(directory: wrong, entries: [])
        )
        await eventually {
            guard case let .failed(error) = workspace.availability else {
                return false
            }
            return error.category == .malformedResponse
        }

        #expect(workspace.currentDirectory == nil)
        #expect(workspace.currentListing == nil)
        #expect(workspace.cachedListingCount == 0)
    }

    @Test("[FILE-WORKSPACE-001] Concurrent close callers share one fully-settled shutdown")
    func concurrentCloseCallersShareProviderShutdown() async {
        let provider = ControllableRemoteFileProvider(
            suspendsCancelAll: true,
            suspendsClose: true
        )
        let workspace = RemoteWorkspace(provider: provider)
        workspace.start()
        _ = await provider.nextAttempt()

        let firstClose = Task { @MainActor in await workspace.close() }
        let secondClose = Task { @MainActor in await workspace.close() }
        await eventually { (await provider.snapshot()).cancelAllCount == 1 }

        #expect(workspace.availability == .closing)
        await provider.releaseCancelAll()
        await eventually { (await provider.snapshot()).closeCount == 1 }
        #expect(workspace.availability == .closing)
        await provider.releaseClose()
        await firstClose.value
        await secondClose.value

        let snapshot = await provider.snapshot()
        #expect(snapshot.cancelAllCount == 1)
        #expect(snapshot.closeCount == 1)
        #expect(workspace.availability == .closed)
    }

    @Test("[FILE-CACHE-001, FILE-WORKSPACE-001] Close clears a populated cache and directory state")
    func closeClearsPopulatedCacheAndState() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let child = try remotePath("/root/child")
        let rootListing = try listing(
            in: root,
            entries: [("child", .directory)]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )
        workspace.setExpanded(child, isExpanded: true)
        let childAttempt = await provider.nextAttempt()
        let childListing = try listing(
            in: child,
            entries: [("file.txt", .regular)]
        )
        await provider.succeedListing(
            requestID: childAttempt.requestID,
            listing: childListing
        )
        await eventually {
            workspace.directoryStates[child] == .loaded(childListing)
        }

        #expect(workspace.cachedListingCount == 2)
        #expect(!workspace.directoryStates.isEmpty)
        await workspace.close()

        #expect(workspace.cachedListingCount == 0)
        #expect(workspace.directoryStates.isEmpty)
        #expect(workspace.currentDirectory == nil)
        #expect(workspace.expandedDirectories.isEmpty)
    }

    @Test("[FILE-STATE-001] Provider resolve and list entry do not execute on MainActor")
    func providerCallsBeginOffMainActor() async throws {
        let directory = try remotePath("/probe")
        let recorder = ProviderThreadRecorder()
        let workspace = RemoteWorkspace(
            provider: ProviderThreadProbe(
                directory: directory,
                recorder: recorder
            )
        )

        workspace.start()
        await eventually { workspace.availability == .available }

        #expect(await recorder.observations == [false, false])
        await workspace.close()
    }

    private func loadInitial(
        _ workspace: RemoteWorkspace,
        provider: ControllableRemoteFileProvider,
        directory: RemotePath,
        listing: RemoteDirectoryListing
    ) async {
        workspace.start()
        let resolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: resolve.requestID, path: directory)
        let list = await provider.nextAttempt()
        await provider.succeedListing(requestID: list.requestID, listing: listing)
        await eventually { workspace.currentDirectory == directory }
    }

    private func listing(
        in directory: RemotePath,
        entries: [(String, RemoteFileEntry.Kind)]
    ) throws -> RemoteDirectoryListing {
        let values = try entries.map { name, kind in
            try RemoteFileEntry(
                path: directory.appending(
                    RemotePathComponent(rawBytes: Array(name.utf8))
                ),
                kind: kind
            )
        }
        return try RemoteDirectoryListing(directory: directory, entries: values)
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic contract state")
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}

private actor ProviderThreadRecorder {
    private(set) var observations: [Bool] = []

    func record(_ isMainThread: Bool) {
        observations = observations + [isMainThread]
    }
}

private struct ProviderThreadProbe: RemoteFileProvider {
    let directory: RemotePath
    let recorder: ProviderThreadRecorder

    func resolveInitialDirectory() async throws -> RemotePath {
        await recorder.record(isMainThreadSynchronously())
        return directory
    }

    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        await recorder.record(isMainThreadSynchronously())
        return try RemoteDirectoryListing(directory: path, entries: [])
    }

    func cancelAll() async {}
    func close() async {}
}

private func isMainThreadSynchronously() -> Bool {
    Thread.isMainThread
}
