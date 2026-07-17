import Testing

@testable import XMtermRemote

@Suite("Remote workspace lifecycle")
@MainActor
struct RemoteWorkspaceTests {
    @Test("[FILE-STATE-001, FILE-NAV-002] Initial directory publishes only after its listing succeeds")
    func initialLoadPublishesTransactionally() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let directory = try remotePath("/workspace")
        let listing = try directoryListing(directory, names: ["file.txt"])

        #expect(workspace.availability == .idle)
        #expect(workspace.currentDirectory == nil)
        #expect(workspace.currentListing == nil)
        workspace.start()
        #expect(workspace.availability == .connecting)

        let resolve = await provider.nextAttempt()
        #expect(resolve == .resolveInitialDirectory(requestID: resolve.requestID))
        await provider.succeedResolve(requestID: resolve.requestID, path: directory)
        let list = await provider.nextAttempt()

        #expect(list == .listDirectory(requestID: list.requestID, path: directory))
        #expect(workspace.availability == .loadingInitialDirectory)
        #expect(workspace.pendingDirectory == directory)
        #expect(workspace.currentDirectory == nil)
        #expect(workspace.currentListing == nil)
        #expect(workspace.directoryStates[directory] == .loading(previousListing: nil))

        await provider.succeedListing(requestID: list.requestID, listing: listing)
        await eventually { workspace.availability == .available }

        #expect(workspace.currentDirectory == directory)
        #expect(workspace.currentListing == listing)
        #expect(workspace.pendingDirectory == nil)
        #expect(workspace.directoryStates[directory] == .loaded(listing))
        #expect(workspace.cachedListingCount == 1)
    }

    @Test("[FILE-STATE-001] A successful zero-entry listing is explicitly empty")
    func emptyInitialDirectoryIsNotFailure() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let directory = try remotePath("/empty")
        let listing = try RemoteDirectoryListing(directory: directory, entries: [])

        workspace.start()
        let resolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: resolve.requestID, path: directory)
        let list = await provider.nextAttempt()
        await provider.succeedListing(requestID: list.requestID, listing: listing)
        await eventually { workspace.availability == .available }

        #expect(workspace.currentDirectory == directory)
        #expect(workspace.currentListing == listing)
        #expect(workspace.directoryStates[directory] == .empty(listing))
    }

    @Test("[FILE-STATE-001] Resolve failure remains typed and publishes no directory")
    func initialResolveFailureIsHonest() async {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let expected = RemoteFileError(category: .authenticationRequired)

        workspace.start()
        let resolve = await provider.nextAttempt()
        await provider.fail(requestID: resolve.requestID, error: expected)
        await eventually { workspace.availability == .failed(expected) }

        #expect(workspace.currentDirectory == nil)
        #expect(workspace.currentListing == nil)
        #expect(workspace.pendingDirectory == nil)
        #expect(workspace.directoryStates.isEmpty)
    }

    @Test("[FILE-STATE-001, FILE-NAV-002] Listing failure preserves an unpublished target and supports Retry")
    func listingFailureCanRetryWithoutFalseEmptyState() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let directory = try remotePath("/denied")
        let expected = RemoteFileError(category: .permissionDenied)

        workspace.start()
        let firstResolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: firstResolve.requestID, path: directory)
        let firstList = await provider.nextAttempt()
        await provider.fail(requestID: firstList.requestID, error: expected)
        await eventually { workspace.availability == .failed(expected) }

        #expect(workspace.currentDirectory == nil)
        #expect(workspace.currentListing == nil)
        #expect(workspace.directoryStates[directory] == .failed(
            error: expected,
            previousListing: nil
        ))

        workspace.retry()
        let secondResolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: secondResolve.requestID, path: directory)
        let secondList = await provider.nextAttempt()
        let listing = try RemoteDirectoryListing(directory: directory, entries: [])
        await provider.succeedListing(requestID: secondList.requestID, listing: listing)
        await eventually { workspace.availability == .available }

        #expect(workspace.currentDirectory == directory)
        #expect(workspace.directoryStates[directory] == .empty(listing))
        #expect((await provider.snapshot()).attempts.count == 4)
    }

    @Test("[FILE-STATE-001, FILE-NAV-002] Explicit cancellation is typed and Retry starts a new generation")
    func cancellationIsExplicitAndRetryable() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)

        workspace.start()
        let firstResolve = await provider.nextAttempt()
        workspace.cancelCurrentRequest()
        await eventually {
            guard workspace.availability
                    == .failed(RemoteFileError(category: .cancelled)) else {
                return false
            }
            return (await provider.snapshot()).cancelledRequestIDs.contains(
                firstResolve.requestID
            )
        }

        let cancelledSnapshot = await provider.snapshot()
        #expect(cancelledSnapshot.cancelledRequestIDs == [firstResolve.requestID])
        #expect(workspace.currentDirectory == nil)

        workspace.retry()
        let secondResolve = await provider.nextAttempt()
        #expect(secondResolve.requestID != firstResolve.requestID)
        let directory = try remotePath("/retry")
        await provider.succeedResolve(requestID: secondResolve.requestID, path: directory)
        let secondList = await provider.nextAttempt()
        let listing = try RemoteDirectoryListing(directory: directory, entries: [])
        await provider.succeedListing(requestID: secondList.requestID, listing: listing)
        await eventually { workspace.availability == .available }
    }

    @Test("[FILE-NAV-002] Successful navigation, Back, and Forward restore exact cached locations")
    func navigationHistoryRestoresSelectionAndScrollFromCache() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let child = try remotePath("/root/child")
        let sibling = try remotePath("/root/sibling")
        let childFile = try remotePath("/root/child/file.txt")
        let rootListing = try listing(
            in: root,
            entries: [("child", .directory), ("sibling", .directory)]
        )
        let childListing = try listing(in: child, entries: [("file.txt", .regular)])
        let rootScroll = RemoteScrollRestorationToken(rawValue: "root-scroll")
        let childScroll = RemoteScrollRestorationToken(rawValue: "child-scroll")
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )

        workspace.selectEntry(child)
        workspace.setScrollRestorationToken(rootScroll)
        workspace.openDirectory(child)
        let childAttempt = await provider.nextAttempt()
        #expect(workspace.currentDirectory == root)
        #expect(workspace.pendingDirectory == child)
        await provider.succeedListing(
            requestID: childAttempt.requestID,
            listing: childListing
        )
        await eventually { workspace.currentDirectory == child }

        #expect(workspace.backHistory == [
            RemoteWorkspaceLocation(
                directory: root,
                selectedEntry: child,
                scrollRestorationToken: rootScroll
            )
        ])
        #expect(workspace.forwardHistory.isEmpty)
        #expect(workspace.selectedEntry == nil)
        workspace.selectEntry(childFile)
        workspace.setScrollRestorationToken(childScroll)

        workspace.goBack()
        #expect(workspace.currentDirectory == root)
        #expect(workspace.selectedEntry == child)
        #expect(workspace.scrollRestorationToken == rootScroll)
        #expect(workspace.backHistory.isEmpty)
        #expect(workspace.forwardHistory == [
            RemoteWorkspaceLocation(
                directory: child,
                selectedEntry: childFile,
                scrollRestorationToken: childScroll
            )
        ])

        workspace.goForward()
        #expect(workspace.currentDirectory == child)
        #expect(workspace.selectedEntry == childFile)
        #expect(workspace.scrollRestorationToken == childScroll)
        #expect(workspace.canGoBack)

        workspace.goBack()
        workspace.openDirectory(sibling)
        let siblingAttempt = await provider.nextAttempt()
        let siblingListing = try RemoteDirectoryListing(
            directory: sibling,
            entries: []
        )
        await provider.succeedListing(
            requestID: siblingAttempt.requestID,
            listing: siblingListing
        )
        await eventually { workspace.currentDirectory == sibling }

        #expect(workspace.forwardHistory.isEmpty)
        #expect((await provider.snapshot()).attempts.count == 4)
    }

    @Test("[FILE-NAV-002, FILE-STATE-001] Failed and cancelled targets preserve the current location and history")
    func failedAndCancelledNavigationRemainTransactional() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let denied = try remotePath("/root/denied")
        let cancelled = try remotePath("/root/cancelled")
        let rootListing = try listing(
            in: root,
            entries: [("denied", .directory), ("cancelled", .directory)]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )
        workspace.selectEntry(denied)
        let originalBack = workspace.backHistory
        let originalForward = workspace.forwardHistory

        workspace.openDirectory(denied)
        let deniedAttempt = await provider.nextAttempt()
        let deniedError = RemoteFileError(category: .permissionDenied)
        await provider.fail(requestID: deniedAttempt.requestID, error: deniedError)
        await eventually {
            workspace.directoryStates[denied] == .failed(
                error: deniedError,
                previousListing: nil
            )
        }

        #expect(workspace.availability == .available)
        #expect(workspace.currentDirectory == root)
        #expect(workspace.currentListing == rootListing)
        #expect(workspace.selectedEntry == denied)
        #expect(workspace.backHistory == originalBack)
        #expect(workspace.forwardHistory == originalForward)

        workspace.openDirectory(cancelled)
        let cancelledAttempt = await provider.nextAttempt()
        workspace.cancelCurrentRequest()
        await eventually {
            (await provider.snapshot()).cancelledRequestIDs.contains(
                cancelledAttempt.requestID
            )
        }

        #expect(workspace.availability == .available)
        #expect(workspace.currentDirectory == root)
        #expect(workspace.directoryStates[cancelled] == .cancelled(
            previousListing: nil
        ))
        #expect(workspace.backHistory == originalBack)
        #expect(workspace.forwardHistory == originalForward)
    }

    @Test("[FILE-NAV-002] Parent and breadcrumbs use structured paths and root Parent is disabled")
    func parentAndBreadcrumbNavigationRespectRoot() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = RemotePath.root
        let home = try remotePath("/home")
        let user = try remotePath("/home/user")
        let rootListing = try listing(in: root, entries: [("home", .directory)])
        let homeListing = try listing(in: home, entries: [("user", .directory)])
        let userListing = try RemoteDirectoryListing(directory: user, entries: [])
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )

        #expect(!workspace.canGoToParent)
        workspace.goToParent()
        #expect((await provider.snapshot()).attempts.count == 2)

        workspace.openDirectory(home)
        let homeAttempt = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: homeAttempt.requestID,
            listing: homeListing
        )
        await eventually { workspace.currentDirectory == home }
        workspace.openDirectory(user)
        let userAttempt = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: userAttempt.requestID,
            listing: userListing
        )
        await eventually { workspace.currentDirectory == user }

        workspace.openBreadcrumb(home)
        #expect(workspace.currentDirectory == home)
        #expect(workspace.canGoToParent)
        let historyAfterAncestor = workspace.backHistory
        workspace.openBreadcrumb(home)
        #expect(workspace.backHistory == historyAfterAncestor)

        workspace.goToParent()
        #expect(workspace.currentDirectory == root)
        #expect(!workspace.canGoToParent)
        #expect((await provider.snapshot()).attempts.count == 4)
    }

    @Test("[FILE-NAV-002, FILE-CACHE-001] Refresh retains visible content and exact surviving selection without history")
    func refreshReplacesOnlyCurrentListingAndSelection() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let selected = try remotePath("/root/selected.txt")
        let initial = try listing(
            in: root,
            entries: [("selected.txt", .regular), ("removed.txt", .regular)]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: initial
        )
        workspace.selectEntry(selected)
        let originalBack = workspace.backHistory
        let originalForward = workspace.forwardHistory

        workspace.refresh()
        let firstRefresh = await provider.nextAttempt()
        #expect(workspace.currentListing == initial)
        #expect(workspace.directoryStates[root] == .loading(
            previousListing: initial
        ))
        let retained = try listing(
            in: root,
            entries: [("selected.txt", .regular), ("new.txt", .regular)]
        )
        await provider.succeedListing(
            requestID: firstRefresh.requestID,
            listing: retained
        )
        await eventually { workspace.currentListing == retained }

        #expect(workspace.selectedEntry == selected)
        #expect(workspace.backHistory == originalBack)
        #expect(workspace.forwardHistory == originalForward)

        workspace.refresh()
        let secondRefresh = await provider.nextAttempt()
        let removed = try listing(in: root, entries: [("new.txt", .regular)])
        await provider.succeedListing(
            requestID: secondRefresh.requestID,
            listing: removed
        )
        await eventually { workspace.currentListing == removed }
        #expect(workspace.selectedEntry == nil)

        workspace.refresh()
        let failedRefresh = await provider.nextAttempt()
        let disconnected = RemoteFileError(category: .disconnected)
        await provider.fail(requestID: failedRefresh.requestID, error: disconnected)
        await eventually {
            workspace.directoryStates[root] == .failed(
                error: disconnected,
                previousListing: removed
            )
        }
        #expect(workspace.availability == .available)
        #expect(workspace.currentListing == removed)
        #expect(workspace.backHistory == originalBack)
        #expect(workspace.forwardHistory == originalForward)
    }

    @Test("[FILE-CACHE-001, FILE-STATE-001] Expansion is lazy, scoped, cache-backed, and never follows symlinks")
    func lazyExpansionCollapseRetryAndChildFailureAreScoped() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let first = try remotePath("/root/first")
        let second = try remotePath("/root/second")
        let link = try remotePath("/root/link")
        let nested = try remotePath("/root/first/nested")
        let rootListing = try listing(
            in: root,
            entries: [
                ("first", .directory),
                ("second", .directory),
                ("link", .symbolicLink)
            ]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )
        #expect((await provider.snapshot()).attempts.count == 2)

        workspace.setExpanded(first, isExpanded: true)
        let cancelledAttempt = await provider.nextAttempt()
        workspace.setExpanded(first, isExpanded: false)
        await eventually {
            (await provider.snapshot()).cancelledRequestIDs.contains(
                cancelledAttempt.requestID
            )
        }
        #expect(!workspace.expandedDirectories.contains(first))
        #expect(workspace.directoryStates[first] == .cancelled(
            previousListing: nil
        ))

        workspace.setExpanded(first, isExpanded: true)
        let firstRetry = await provider.nextAttempt()
        let firstListing = try listing(
            in: first,
            entries: [("nested", .directory)]
        )
        await provider.succeedListing(
            requestID: firstRetry.requestID,
            listing: firstListing
        )
        await eventually { workspace.directoryStates[first] == .loaded(firstListing) }
        #expect(workspace.directoryStates[nested] == nil)

        workspace.setExpanded(first, isExpanded: false)
        workspace.setExpanded(first, isExpanded: true)
        #expect(workspace.directoryStates[first] == .loaded(firstListing))
        #expect((await provider.snapshot()).attempts.count == 4)

        workspace.setExpanded(second, isExpanded: true)
        let failedChild = await provider.nextAttempt()
        let denied = RemoteFileError(category: .permissionDenied)
        await provider.fail(requestID: failedChild.requestID, error: denied)
        await eventually {
            workspace.directoryStates[second] == .failed(
                error: denied,
                previousListing: nil
            )
        }
        #expect(workspace.currentDirectory == root)
        #expect(workspace.directoryStates[first] == .loaded(firstListing))

        workspace.retryDirectory(second)
        let childRetry = await provider.nextAttempt()
        let secondListing = try RemoteDirectoryListing(directory: second, entries: [])
        await provider.succeedListing(
            requestID: childRetry.requestID,
            listing: secondListing
        )
        await eventually { workspace.directoryStates[second] == .empty(secondListing) }

        workspace.setExpanded(link, isExpanded: true)
        #expect(!workspace.expandedDirectories.contains(link))
        #expect((await provider.snapshot()).attempts.count == 6)
    }

    @Test("[FILE-CACHE-001, FILE-STATE-001] Request pump caps the workspace at two and one per path")
    func requestPumpIsBoundedAndPromotesQueuedExpansion() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let first = try remotePath("/root/first")
        let second = try remotePath("/root/second")
        let third = try remotePath("/root/third")
        let rootListing = try listing(
            in: root,
            entries: [
                ("first", .directory),
                ("second", .directory),
                ("third", .directory)
            ]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )

        workspace.setExpanded(first, isExpanded: true)
        workspace.setExpanded(second, isExpanded: true)
        workspace.setExpanded(third, isExpanded: true)
        let firstAttempt = await provider.nextAttempt()
        let secondAttempt = await provider.nextAttempt()
        #expect(Set([attemptPath(firstAttempt), attemptPath(secondAttempt)]) == [first, second])
        #expect(workspace.activeRequestCount == 2)
        #expect(workspace.queuedRequestCount == 1)
        #expect((await provider.snapshot()).attempts.count == 4)

        let firstListing = try RemoteDirectoryListing(directory: first, entries: [])
        await provider.succeedListing(
            requestID: firstAttempt.requestID,
            listing: firstListing
        )
        await eventually { (await provider.snapshot()).attempts.count == 5 }
        let thirdAttempt = await provider.nextAttempt()
        #expect(attemptPath(thirdAttempt) == third)
        #expect(workspace.activeRequestCount == 2)

        let secondPath = try #require(attemptPath(secondAttempt))
        let secondListing = try RemoteDirectoryListing(
            directory: secondPath,
            entries: []
        )
        await provider.succeedListing(
            requestID: secondAttempt.requestID,
            listing: secondListing
        )
        let thirdListing = try RemoteDirectoryListing(directory: third, entries: [])
        await provider.succeedListing(
            requestID: thirdAttempt.requestID,
            listing: thirdListing
        )
        await eventually { workspace.activeRequestCount == 0 }

        let snapshot = await provider.snapshot()
        #expect(snapshot.maximumPendingRequestCount <= 2)
        #expect(snapshot.maximumPendingListingCountByPath.values.allSatisfy { $0 <= 1 })
        #expect(workspace.queuedRequestCount == 0)
    }

    @Test("[FILE-NAV-002] A non-cooperative stale navigation result cannot beat a newer target")
    func newerNavigationWinsOutOfOrderCompletion() async throws {
        let provider = ControllableRemoteFileProvider(
            honorsTaskCancellation: false
        )
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let first = try remotePath("/root/first")
        let second = try remotePath("/root/second")
        let rootListing = try listing(
            in: root,
            entries: [("first", .directory), ("second", .directory)]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )

        workspace.openDirectory(first)
        let staleAttempt = await provider.nextAttempt()
        workspace.openDirectory(second)
        let winningAttempt = await provider.nextAttempt()
        let winningListing = try RemoteDirectoryListing(directory: second, entries: [])
        await provider.succeedListing(
            requestID: winningAttempt.requestID,
            listing: winningListing
        )
        await eventually { workspace.currentDirectory == second }

        let staleListing = try RemoteDirectoryListing(directory: first, entries: [])
        await provider.succeedListing(
            requestID: staleAttempt.requestID,
            listing: staleListing
        )
        await eventually { workspace.activeRequestCount == 0 }

        #expect(workspace.currentDirectory == second)
        #expect(workspace.currentListing == winningListing)
        #expect(workspace.backHistory.map(\.directory) == [root])
        #expect(workspace.directoryStates[first] == .cancelled(previousListing: nil))
        #expect((await provider.snapshot()).cancelledRequestIDs.contains(
            staleAttempt.requestID
        ))
    }

    @Test("[FILE-NAV-002] Same-path refresh replacement waits for stale work and publishes only newest data")
    func refreshRaceMaintainsOneRequestPerPath() async throws {
        let provider = ControllableRemoteFileProvider(
            honorsTaskCancellation: false
        )
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let original = try listing(in: root, entries: [("old.txt", .regular)])
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: original
        )

        workspace.refresh()
        let staleRefresh = await provider.nextAttempt()
        workspace.refresh()
        await eventually {
            (await provider.snapshot()).cancelledRequestIDs.contains(
                staleRefresh.requestID
            )
        }
        #expect(workspace.activeRequestCount == 1)
        #expect(workspace.queuedRequestCount == 1)
        #expect((await provider.snapshot()).attempts.count == 3)

        let stale = try listing(in: root, entries: [("stale.txt", .regular)])
        await provider.succeedListing(
            requestID: staleRefresh.requestID,
            listing: stale
        )
        let winningRefresh = await provider.nextAttempt()
        #expect(attemptPath(winningRefresh) == root)
        #expect(workspace.currentListing == original)

        let winning = try listing(in: root, entries: [("new.txt", .regular)])
        await provider.succeedListing(
            requestID: winningRefresh.requestID,
            listing: winning
        )
        await eventually { workspace.currentListing == winning }

        let snapshot = await provider.snapshot()
        #expect(snapshot.maximumPendingListingCountByPath[root] == 1)
        #expect(workspace.activeRequestCount == 0)
        #expect(workspace.queuedRequestCount == 0)
        #expect(workspace.backHistory.isEmpty)
        #expect(workspace.forwardHistory.isEmpty)
    }

    @Test("[FILE-NAV-002] New navigation cancels a queued refresh and restores its visible state")
    func navigationSupersedesQueuedRefreshWithoutPhantomLoading() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let first = try remotePath("/root/first")
        let second = try remotePath("/root/second")
        let target = try remotePath("/root/target")
        let rootListing = try listing(
            in: root,
            entries: [
                ("first", .directory),
                ("second", .directory),
                ("target", .directory)
            ]
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )
        workspace.setExpanded(first, isExpanded: true)
        workspace.setExpanded(second, isExpanded: true)
        _ = await provider.nextAttempt()
        _ = await provider.nextAttempt()

        workspace.refresh()
        #expect(workspace.queuedRequestCount == 1)
        #expect(workspace.directoryStates[root] == .loading(
            previousListing: rootListing
        ))
        workspace.openDirectory(target)

        #expect(workspace.directoryStates[root] == .loaded(rootListing))
        #expect(workspace.pendingDirectory == target)
        #expect(workspace.queuedRequestCount == 1)
        await workspace.close()
    }

    @Test("[FILE-CACHE-001] Per-directory observable state remains bounded under repeated failures")
    func directoryStateBookkeepingIsBounded() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let root = try remotePath("/root")
        let names = (0..<40).map { "child-\($0)" }
        let rootListing = try listing(
            in: root,
            entries: names.map { ($0, RemoteFileEntry.Kind.directory) }
        )
        await loadInitial(
            workspace,
            provider: provider,
            directory: root,
            listing: rootListing
        )

        for name in names {
            let path = try root.appending(
                RemotePathComponent(rawBytes: Array(name.utf8))
            )
            workspace.openDirectory(path)
            let attempt = await provider.nextAttempt()
            await provider.fail(
                requestID: attempt.requestID,
                error: RemoteFileError(category: .pathNotFound)
            )
            await eventually { workspace.pendingDirectory == nil }
        }

        #expect(workspace.directoryStates.count <= 32)
        #expect(workspace.directoryStates[root] == .loaded(rootListing))
        #expect(workspace.currentDirectory == root)
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

    private func attemptPath(
        _ attempt: ControllableRemoteFileProvider.Attempt
    ) -> RemotePath? {
        guard case let .listDirectory(_, path) = attempt else { return nil }
        return path
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic workspace state")
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func directoryListing(
        _ directory: RemotePath,
        names: [String]
    ) throws -> RemoteDirectoryListing {
        let entries = try names.map { name in
            try RemoteFileEntry(
                path: directory.appending(
                    RemotePathComponent(rawBytes: Array(name.utf8))
                ),
                kind: .regular
            )
        }
        return try RemoteDirectoryListing(directory: directory, entries: entries)
    }
}
