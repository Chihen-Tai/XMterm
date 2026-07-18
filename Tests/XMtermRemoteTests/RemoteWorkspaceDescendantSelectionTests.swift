import Foundation
import Testing
@testable import XMtermRemote

@Suite("Remote workspace descendant selection", .serialized)
@MainActor
struct RemoteWorkspaceDescendantSelectionTests {
    @Test("[FILE-SEL-001] selection accepts exactly the visible loaded entries")
    func selectionAcceptsVisibleDescendantsOnly() async throws {
        let fixture = try makeGraphFixture()
        let provider = fixture.makeProvider()
        let workspace = RemoteWorkspace(provider: provider)
        workspace.start()
        try await waitUntil { workspace.availability == .available }

        workspace.selectEntry(fixture.alpha)
        #expect(workspace.selectedEntry == fixture.alpha)

        // Hidden child of a collapsed directory is rejected.
        workspace.selectEntry(fixture.fileA)
        #expect(workspace.selectedEntry == fixture.alpha)

        workspace.setExpanded(fixture.alpha, isExpanded: true)
        try await waitUntil {
            if case .loaded = workspace.directoryStates[fixture.alpha] { return true }
            return false
        }
        workspace.selectEntry(fixture.fileA)
        #expect(workspace.selectedEntry == fixture.fileA)

        workspace.setExpanded(fixture.inner, isExpanded: true)
        try await waitUntil {
            if case .loaded = workspace.directoryStates[fixture.inner] { return true }
            return false
        }
        workspace.selectEntry(fixture.deep)
        #expect(workspace.selectedEntry == fixture.deep)

        // Arbitrary unknown paths are rejected.
        workspace.selectEntry(try path("/nope"))
        #expect(workspace.selectedEntry == fixture.deep)

        let listCountBeforeSelections = await provider.recordedAttempts
            .count(where: { $0 == .listDirectory })
        workspace.selectEntry(fixture.alpha)
        workspace.selectEntry(fixture.deep)
        workspace.selectEntry(nil)
        workspace.selectEntry(fixture.inner)
        let listCountAfterSelections = await provider.recordedAttempts
            .count(where: { $0 == .listDirectory })
        #expect(listCountAfterSelections == listCountBeforeSelections)
    }

    @Test("[FILE-SEL-001] collapsing an ancestor moves selection to the collapsed directory")
    func collapseRepairsSelectionToCollapsedAncestor() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)
        try await expandLoaded(workspace, fixture.inner)

        workspace.selectEntry(fixture.deep)
        workspace.setExpanded(fixture.alpha, isExpanded: false)
        #expect(workspace.selectedEntry == fixture.alpha)

        workspace.setExpanded(fixture.alpha, isExpanded: true)
        try await waitUntil {
            if case .loaded = workspace.directoryStates[fixture.alpha] { return true }
            return false
        }
        workspace.selectEntry(fixture.deep)
        #expect(workspace.selectedEntry == fixture.deep)
        workspace.setExpanded(fixture.inner, isExpanded: false)
        #expect(workspace.selectedEntry == fixture.inner)
    }

    @Test("[FILE-SEL-001] collapsing an unrelated directory preserves selection")
    func collapseOfUnrelatedDirectoryPreservesSelection() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)
        try await expandLoaded(workspace, fixture.beta)

        workspace.selectEntry(fixture.fileA)
        workspace.setExpanded(fixture.beta, isExpanded: false)
        #expect(workspace.selectedEntry == fixture.fileA)
    }

    @Test("[FILE-NAV-002] refresh preserves the exact surviving descendant selection")
    func refreshPreservesExactDescendantSelection() async throws {
        let fixture = try makeGraphFixture()
        let provider = fixture.makeProvider()
        let workspace = RemoteWorkspace(provider: provider)
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)

        workspace.selectEntry(fixture.fileA)
        workspace.refresh()
        try await waitUntil {
            workspace.pendingDirectory == nil && workspace.activeRequestCount == 0
        }
        #expect(workspace.selectedEntry == fixture.fileA)
        #expect(workspace.currentDirectory == fixture.work)
    }

    @Test("[FILE-CACHE-001, FILE-SEL-001] cache eviction repairs a selected descendant to the nearest visible ancestor")
    func cacheEvictionRepairsSelectedDescendantToNearestVisibleAncestor() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(
            provider: fixture.makeProvider(),
            directoryCache: RemoteDirectoryCache(
                maximumListingCount: 3,
                maximumTotalEntryCount: 16
            )
        )
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)
        try await expandLoaded(workspace, fixture.inner)

        workspace.selectEntry(fixture.deep)
        #expect(workspace.selectedEntry == fixture.deep)
        #expect(workspace.visibleProjection.isSelectable(fixture.deep))

        try await expandLoaded(workspace, fixture.beta)

        #expect(workspace.cachedListingCount == 3)
        #expect(workspace.expandedDirectories.contains(fixture.alpha))
        #expect(workspace.expandedDirectories.contains(fixture.inner))
        #expect(workspace.expandedDirectories.contains(fixture.beta))
        #expect(!workspace.visibleProjection.isSelectable(fixture.deep))
        #expect(!workspace.visibleProjection.isSelectable(fixture.inner))
        #expect(workspace.visibleProjection.isSelectable(fixture.alpha))
        #expect(workspace.selectedEntry == fixture.alpha)
    }

    @Test("[FILE-NAV-002] refresh repairs a vanished selection without display-name redirection")
    func refreshRepairsSelectionWhenExactPathDisappears() async throws {
        let provider = ControllableRemoteFileProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let work = try path("/work")
        let alpha = try path("/work/alpha")
        let doomed = try path("/work/doomed.txt")
        let nestedDoomed = try path("/work/alpha/doomed.txt")
        let firstListing = try RemoteDirectoryListing(
            directory: work,
            entries: [
                try RemoteFileEntry(path: alpha, kind: .directory),
                try RemoteFileEntry(path: doomed, kind: .regular)
            ]
        )
        let alphaListing = try RemoteDirectoryListing(
            directory: alpha,
            entries: [try RemoteFileEntry(path: nestedDoomed, kind: .regular)]
        )
        let secondListing = try RemoteDirectoryListing(
            directory: work,
            entries: [try RemoteFileEntry(path: alpha, kind: .directory)]
        )

        workspace.start()
        let resolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: resolve.requestID, path: work)
        let initialList = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: initialList.requestID,
            listing: firstListing
        )
        try await waitUntil { workspace.availability == .available }

        workspace.setExpanded(alpha, isExpanded: true)
        let expandList = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: expandList.requestID,
            listing: alphaListing
        )
        try await waitUntil {
            if case .loaded = workspace.directoryStates[alpha] { return true }
            return false
        }

        workspace.selectEntry(doomed)
        #expect(workspace.selectedEntry == doomed)

        workspace.refresh()
        let refreshList = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: refreshList.requestID,
            listing: secondListing
        )
        try await waitUntil {
            workspace.pendingDirectory == nil && workspace.currentListing == secondListing
        }

        // The exact path is gone. A same-named visible entry at a different
        // path must never inherit the selection.
        #expect(workspace.selectedEntry != nestedDoomed)
        #expect(workspace.selectedEntry == nil)
    }

    @Test("[FILE-NAV-002] history restores the exact recorded descendant selection")
    func historyRestoresExactDescendantSelection() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)
        try await expandLoaded(workspace, fixture.inner)

        workspace.selectEntry(fixture.deep)
        workspace.openDirectory(fixture.beta)
        try await waitUntil { workspace.currentDirectory == fixture.beta }
        #expect(workspace.selectedEntry == nil)

        workspace.goBack()
        try await waitUntil { workspace.currentDirectory == fixture.work }
        #expect(workspace.selectedEntry == fixture.deep)
    }

    @Test("[FILE-NAV-002] history clears an exact descendant absent after cache eviction and reload")
    func historyClearsExactDescendantAbsentAfterCacheEvictionAndReload() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(
            provider: fixture.makeProvider(),
            directoryCache: RemoteDirectoryCache(
                maximumListingCount: 3,
                maximumTotalEntryCount: 16
            )
        )
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)
        try await expandLoaded(workspace, fixture.inner)

        workspace.selectEntry(fixture.deep)
        workspace.openDirectory(fixture.beta)
        try await waitUntil { workspace.currentDirectory == fixture.beta }
        #expect(workspace.backHistory.last?.selectedEntry == fixture.deep)

        workspace.goBack()
        try await waitUntil { workspace.currentDirectory == fixture.work }

        #expect(workspace.cachedListingCount == 3)
        #expect(!workspace.visibleProjection.isSelectable(fixture.deep))
        #expect(!workspace.visibleProjection.isSelectable(fixture.inner))
        #expect(workspace.selectedEntry == nil)
    }

    @Test("[FILE-NAV-002] a failed navigation preserves the successful selection")
    func failedNavigationPreservesSelection() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)

        workspace.selectEntry(fixture.fileA)
        workspace.openDirectory(fixture.gamma)
        try await waitUntil {
            if case .failed = workspace.directoryStates[fixture.gamma] { return true }
            return false
        }
        #expect(workspace.currentDirectory == fixture.work)
        #expect(workspace.selectedEntry == fixture.fileA)
    }

    @Test("[SESS-011] two workspaces keep independent descendant selections")
    func independentWorkspaceSelections() async throws {
        let fixture = try makeGraphFixture()
        let first = RemoteWorkspace(provider: fixture.makeProvider())
        let second = RemoteWorkspace(provider: fixture.makeProvider())
        first.start()
        second.start()
        try await waitUntil {
            first.availability == .available && second.availability == .available
        }
        try await expandLoaded(first, fixture.alpha)

        first.selectEntry(fixture.fileA)
        second.selectEntry(fixture.beta)
        #expect(first.selectedEntry == fixture.fileA)
        #expect(second.selectedEntry == fixture.beta)

        first.selectEntry(nil)
        #expect(second.selectedEntry == fixture.beta)
    }

    @Test("[FILE-SEL-001, FILE-STATE-001] hidden child completion after ancestor collapse cannot reselect or render descendant")
    func hiddenCompletionAfterAncestorCollapseCannotReselectOrRenderDescendant() async throws {
        let fixture = try makeGraphFixture()
        let provider = ControllableRemoteFileProvider(honorsTaskCancellation: false)
        let workspace = RemoteWorkspace(provider: provider)
        let workListing = try RemoteDirectoryListing(
            directory: fixture.work,
            entries: [
                try RemoteFileEntry(path: fixture.alpha, kind: .directory),
                try RemoteFileEntry(path: fixture.beta, kind: .directory)
            ]
        )
        let alphaListing = try RemoteDirectoryListing(
            directory: fixture.alpha,
            entries: [
                try RemoteFileEntry(path: fixture.inner, kind: .directory),
                try RemoteFileEntry(path: fixture.fileA, kind: .regular)
            ]
        )
        let innerListing = try RemoteDirectoryListing(
            directory: fixture.inner,
            entries: [try RemoteFileEntry(path: fixture.deep, kind: .regular)]
        )

        workspace.start()
        let resolve = await provider.nextAttempt()
        await provider.succeedResolve(requestID: resolve.requestID, path: fixture.work)
        let initialList = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: initialList.requestID,
            listing: workListing
        )
        try await waitUntil { workspace.availability == .available }

        workspace.setExpanded(fixture.alpha, isExpanded: true)
        let alphaAttempt = await provider.nextAttempt()
        await provider.succeedListing(
            requestID: alphaAttempt.requestID,
            listing: alphaListing
        )
        try await waitUntil {
            if case .loaded = workspace.directoryStates[fixture.alpha] { return true }
            return false
        }

        workspace.setExpanded(fixture.inner, isExpanded: true)
        let innerAttempt = await provider.nextAttempt()
        try await waitUntil { workspace.activeRequestCount == 1 }
        workspace.selectEntry(fixture.fileA)
        workspace.setExpanded(fixture.alpha, isExpanded: false)

        #expect(workspace.selectedEntry == fixture.alpha)
        #expect(!workspace.expandedDirectories.contains(fixture.alpha))
        #expect(workspace.expandedDirectories.contains(fixture.inner))
        #expect(!workspace.visibleProjection.isSelectable(fixture.fileA))
        #expect(!workspace.visibleProjection.isSelectable(fixture.deep))

        await provider.succeedListing(
            requestID: innerAttempt.requestID,
            listing: innerListing
        )
        try await waitUntil { workspace.activeRequestCount == 0 }

        #expect(workspace.selectedEntry == fixture.alpha)
        #expect(workspace.expandedDirectories.contains(fixture.inner))
        #expect(!workspace.visibleProjection.rows.map(\.id).contains(.entry(fixture.inner)))
        #expect(!workspace.visibleProjection.rows.map(\.id).contains(.entry(fixture.deep)))
        #expect(!workspace.visibleProjection.isSelectable(fixture.deep))

        workspace.setExpanded(fixture.alpha, isExpanded: true)
        try await waitUntil {
            if case .loaded = workspace.directoryStates[fixture.alpha] { return true }
            return false
        }
        #expect(workspace.expandedDirectories.contains(fixture.inner))
        #expect(workspace.visibleProjection.isSelectable(fixture.inner))
        #expect(workspace.visibleProjection.isSelectable(fixture.deep))
    }

    @Test("[FILE-SEL-001] lossy raw descendant paths keep exact byte identity")
    func lossyDescendantPathsKeepExactIdentity() async throws {
        let fixture = try makeGraphFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        try await expandLoaded(workspace, fixture.alpha)

        workspace.selectEntry(fixture.lossyA)
        #expect(workspace.selectedEntry == fixture.lossyA)
        #expect(workspace.selectedEntry?.losslessString == nil)
    }

    private struct GraphFixture {
        let work: RemotePath
        let alpha: RemotePath
        let beta: RemotePath
        let gamma: RemotePath
        let inner: RemotePath
        let deep: RemotePath
        let fileA: RemotePath
        let lossyA: RemotePath
        private let graph: [RemotePath: InMemoryRemoteFileProvider.Directory]
        private let responses: InMemoryRemoteFileProvider.DeterministicResponses

        init(
            work: RemotePath,
            alpha: RemotePath,
            beta: RemotePath,
            gamma: RemotePath,
            inner: RemotePath,
            deep: RemotePath,
            fileA: RemotePath,
            lossyA: RemotePath,
            graph: [RemotePath: InMemoryRemoteFileProvider.Directory],
            responses: InMemoryRemoteFileProvider.DeterministicResponses
        ) {
            self.work = work
            self.alpha = alpha
            self.beta = beta
            self.gamma = gamma
            self.inner = inner
            self.deep = deep
            self.fileA = fileA
            self.lossyA = lossyA
            self.graph = graph
            self.responses = responses
        }

        func makeProvider() -> InMemoryRemoteFileProvider {
            InMemoryRemoteFileProvider(
                initialDirectory: work,
                directoryGraph: graph,
                deterministicResponses: responses
            )
        }
    }

    private func makeGraphFixture() throws -> GraphFixture {
        let work = try path("/work")
        let alpha = try path("/work/alpha")
        let beta = try path("/work/beta")
        let gamma = try path("/work/gamma")
        let inner = try path("/work/alpha/inner")
        let deep = try path("/work/alpha/inner/deep.txt")
        let fileA = try path("/work/alpha/file-a.txt")
        let lossyA = try RemotePath(
            components: try path("/work/alpha").components
                + [RemotePathComponent(rawBytes: [0x80])]
        )

        let graph: [RemotePath: InMemoryRemoteFileProvider.Directory] = [
            work: .init(entries: [
                try RemoteFileEntry(path: alpha, kind: .directory),
                try RemoteFileEntry(path: beta, kind: .directory),
                try RemoteFileEntry(path: gamma, kind: .directory),
                try RemoteFileEntry(path: path("/work/readme.txt"), kind: .regular)
            ]),
            alpha: .init(entries: [
                try RemoteFileEntry(path: inner, kind: .directory),
                try RemoteFileEntry(path: fileA, kind: .regular),
                try RemoteFileEntry(path: lossyA, kind: .regular)
            ]),
            inner: .init(entries: [
                try RemoteFileEntry(path: deep, kind: .regular)
            ]),
            beta: .init(entries: [
                try RemoteFileEntry(path: path("/work/beta/file-b.txt"), kind: .regular)
            ])
        ]

        return GraphFixture(
            work: work,
            alpha: alpha,
            beta: beta,
            gamma: gamma,
            inner: inner,
            deep: deep,
            fileA: fileA,
            lossyA: lossyA,
            graph: graph,
            responses: .init(listings: [
                gamma: .failure(RemoteFileError(category: .permissionDenied))
            ])
        )
    }

    private func expandLoaded(
        _ workspace: RemoteWorkspace,
        _ directory: RemotePath
    ) async throws {
        workspace.setExpanded(directory, isExpanded: true)
        try await waitUntil {
            if case .loaded = workspace.directoryStates[directory] { return true }
            return false
        }
    }

    private func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for descendant selection state")
    }
}
