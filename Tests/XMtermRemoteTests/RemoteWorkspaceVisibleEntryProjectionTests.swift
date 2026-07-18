import Foundation
import Testing
@testable import XMtermRemote

@Suite("Remote workspace visible entry projection")
struct RemoteWorkspaceVisibleEntryProjectionTests {
    @Test("[FILE-SEL-001, FILE-NAV-002] rows flatten loaded expanded descendants in listing order")
    func rowsFlattenLoadedExpandedDescendantsInOrder() throws {
        let fixture = try makeTreeFixture()
        let projection = RemoteWorkspaceVisibleEntryProjection(
            currentListing: fixture.workListing,
            expandedDirectories: [fixture.alpha, fixture.inner],
            directoryStates: [
                fixture.alpha: .loaded(fixture.alphaListing),
                fixture.inner: .loaded(fixture.innerListing),
                fixture.beta: .failed(error: RemoteFileError(category: .timeout), previousListing: nil)
            ]
        )

        let identifiers = projection.rows.map(\.id)
        #expect(identifiers == [
            .entry(fixture.alpha),
            .entry(fixture.inner),
            .entry(fixture.deep),
            .entry(fixture.lossyDeep),
            .entry(fixture.alphaReadme),
            .entry(fixture.beta),
            .childStatus(fixture.beta),
            .entry(fixture.workReadme)
        ])
        #expect(projection.rows.map(\.depth) == [0, 1, 2, 2, 1, 0, 1, 0])
        #expect(projection.orderedSelectablePaths == [
            fixture.alpha,
            fixture.inner,
            fixture.deep,
            fixture.lossyDeep,
            fixture.alphaReadme,
            fixture.beta,
            fixture.workReadme
        ])

        guard case let .childStatus(path, state, allowsRetry) =
            projection.rows[6].kind else {
            Issue.record("Expected a collapsed failed-status row")
            return
        }
        #expect(path == fixture.beta)
        #expect(!allowsRetry)
        if case .failed = state {} else {
            Issue.record("Expected the failed state payload")
        }
    }

    @Test("[FILE-STATE-001] expanded but unloaded directories get retryable status rows")
    func expandedNotLoadedStatesGetStatusRows() throws {
        let fixture = try makeTreeFixture()
        let projection = RemoteWorkspaceVisibleEntryProjection(
            currentListing: fixture.workListing,
            expandedDirectories: [fixture.alpha],
            directoryStates: [
                fixture.alpha: .loading(previousListing: nil)
            ]
        )

        #expect(projection.rows.map(\.id) == [
            .entry(fixture.alpha),
            .childStatus(fixture.alpha),
            .entry(fixture.beta),
            .entry(fixture.workReadme)
        ])
        guard case let .childStatus(_, _, allowsRetry) = projection.rows[1].kind else {
            Issue.record("Expected an expanded status row")
            return
        }
        #expect(allowsRetry)
    }

    @Test("[FILE-SEL-001] selectable paths are exactly the visible loaded entries")
    func selectablePathsIncludeAllVisibleEntriesOnly() throws {
        let fixture = try makeTreeFixture()
        // beta is collapsed but has a loaded listing: its children must be
        // neither rendered nor selectable.
        let projection = RemoteWorkspaceVisibleEntryProjection(
            currentListing: fixture.workListing,
            expandedDirectories: [fixture.alpha, fixture.inner],
            directoryStates: [
                fixture.alpha: .loaded(fixture.alphaListing),
                fixture.inner: .loaded(fixture.innerListing),
                fixture.beta: .loaded(fixture.betaListing)
            ]
        )

        #expect(projection.selectablePaths == [
            fixture.alpha,
            fixture.inner,
            fixture.deep,
            fixture.lossyDeep,
            fixture.alphaReadme,
            fixture.beta,
            fixture.workReadme
        ])
        #expect(!projection.isSelectable(fixture.betaChild))
        #expect(projection.entry(for: fixture.betaChild) == nil)
        #expect(!projection.rows.map(\.id).contains(.entry(fixture.betaChild)))
    }

    @Test("[FILE-SEL-001] entry lookup uses exact raw path identity, never display names")
    func entryLookupUsesExactRawPathIdentity() throws {
        let fixture = try makeTreeFixture()
        let projection = RemoteWorkspaceVisibleEntryProjection(
            currentListing: fixture.workListing,
            expandedDirectories: [fixture.alpha, fixture.inner],
            directoryStates: [
                fixture.alpha: .loaded(fixture.alphaListing),
                fixture.inner: .loaded(fixture.innerListing)
            ]
        )

        let topLevel = projection.entry(for: fixture.workReadme)
        let nested = projection.entry(for: fixture.alphaReadme)
        #expect(topLevel?.path == fixture.workReadme)
        #expect(nested?.path == fixture.alphaReadme)
        #expect(topLevel?.name == nested?.name)
        #expect(topLevel?.path != nested?.path)

        let lossyNested = projection.entry(for: fixture.lossyDeep)
        #expect(lossyNested?.path == fixture.lossyDeep)
        #expect(lossyNested?.path.losslessString == nil)
    }

    @Test("[FILE-CACHE-001] projection depth stays within the bounded expansion depth")
    func projectionDepthStaysBounded() throws {
        var parent = RemotePath.root
        var expanded: Set<RemotePath> = []
        var states: [RemotePath: RemoteDirectoryLoadState] = [:]
        var currentListing: RemoteDirectoryListing?
        for index in 0...(RemoteWorkspaceVisibleEntryProjection.maximumDepth + 2) {
            let child = try parent.appending(
                RemotePathComponent(rawBytes: Array("d\(index)".utf8))
            )
            let listing = try RemoteDirectoryListing(
                directory: parent,
                entries: [RemoteFileEntry(path: child, kind: .directory)]
            )
            if parent == .root {
                currentListing = listing
            } else {
                states[parent] = .loaded(listing)
            }
            expanded.insert(parent)
            parent = child
        }

        let projection = RemoteWorkspaceVisibleEntryProjection(
            currentListing: currentListing,
            expandedDirectories: expanded,
            directoryStates: states
        )
        let maximumRowDepth = projection.rows.map(\.depth).max() ?? 0
        #expect(maximumRowDepth <= RemoteWorkspaceVisibleEntryProjection.maximumDepth)
    }

    @Test("[FILE-CACHE-001] the projection depth bound matches the workspace expansion bound")
    @MainActor
    func maximumDepthMatchesWorkspaceExpansionBound() {
        #expect(
            RemoteWorkspaceVisibleEntryProjection.maximumDepth
                == RemoteWorkspace.maximumExpandedDirectoryCount
        )
    }

    @Test("[FILE-SEL-001] ancestor identity follows raw components, not string prefixes")
    func ancestorIdentityFollowsRawComponents() throws {
        let a = try path("/a")
        let ab = try path("/ab")
        let abc = try path("/a/b/c")
        let abPath = try path("/a/b")

        #expect(RemotePath.root.isAncestor(of: a))
        #expect(a.isAncestor(of: abc))
        #expect(abPath.isAncestor(of: abc))
        #expect(!a.isAncestor(of: ab))
        #expect(!a.isAncestor(of: a))
        #expect(!abPath.isAncestor(of: a))
        #expect(!abc.isAncestor(of: abPath))
    }

    @Test("[FILE-PERF-001] projecting 1,100 visible entries with lookups is deterministic")
    func projectionOfLargeExpandedListingHasDeterministicRowsAndLookups() throws {
        let work = try path("/work")
        let child = try path("/work/child")
        var entries = [try RemoteFileEntry(path: child, kind: .directory)]
        for index in 0..<999 {
            entries.append(
                try RemoteFileEntry(
                    path: path(String(format: "/work/file-%04d.txt", index)),
                    kind: .regular
                )
            )
        }
        let workListing = try RemoteDirectoryListing(directory: work, entries: entries)
        let childEntries = try (0..<100).map { index in
            try RemoteFileEntry(
                path: path(String(format: "/work/child/file-%03d.txt", index)),
                kind: .regular
            )
        }
        let childListing = try RemoteDirectoryListing(
            directory: child,
            entries: childEntries
        )

        let projection = RemoteWorkspaceVisibleEntryProjection(
            currentListing: workListing,
            expandedDirectories: [child],
            directoryStates: [child: .loaded(childListing)]
        )

        #expect(projection.rows.count == 1_100)
        #expect(projection.selectablePaths.count == 1_100)
        #expect(
            Set(projection.rows.map(\.id))
                == Set((entries + childEntries).map { .entry($0.path) })
        )
        let childRowIndex = try #require(
            projection.rows.firstIndex { $0.id == .entry(child) }
        )
        #expect(projection.rows[childRowIndex + 1].id == .entry(childEntries[0].path))
        for entry in entries + childEntries {
            #expect(projection.isSelectable(entry.path))
            #expect(projection.entry(for: entry.path) == entry)
        }
    }

    private struct TreeFixture {
        let work: RemotePath
        let alpha: RemotePath
        let beta: RemotePath
        let inner: RemotePath
        let deep: RemotePath
        let alphaReadme: RemotePath
        let workReadme: RemotePath
        let betaChild: RemotePath
        let lossyDeep: RemotePath
        let workListing: RemoteDirectoryListing
        let alphaListing: RemoteDirectoryListing
        let innerListing: RemoteDirectoryListing
        let betaListing: RemoteDirectoryListing
    }

    private func makeTreeFixture() throws -> TreeFixture {
        let work = try path("/work")
        let alpha = try path("/work/alpha")
        let beta = try path("/work/beta")
        let inner = try path("/work/alpha/inner")
        let deep = try path("/work/alpha/inner/deep.txt")
        let alphaReadme = try path("/work/alpha/readme.txt")
        let workReadme = try path("/work/readme.txt")
        let betaChild = try path("/work/beta/file-b.txt")
        let lossyDeep = try RemotePath(
            components: try path("/work/alpha/inner").components
                + [RemotePathComponent(rawBytes: [0x80])]
        )

        return TreeFixture(
            work: work,
            alpha: alpha,
            beta: beta,
            inner: inner,
            deep: deep,
            alphaReadme: alphaReadme,
            workReadme: workReadme,
            betaChild: betaChild,
            lossyDeep: lossyDeep,
            workListing: try RemoteDirectoryListing(
                directory: work,
                entries: [
                    try RemoteFileEntry(path: alpha, kind: .directory),
                    try RemoteFileEntry(path: beta, kind: .directory),
                    try RemoteFileEntry(path: workReadme, kind: .regular)
                ]
            ),
            alphaListing: try RemoteDirectoryListing(
                directory: alpha,
                entries: [
                    try RemoteFileEntry(path: inner, kind: .directory),
                    try RemoteFileEntry(path: alphaReadme, kind: .regular)
                ]
            ),
            innerListing: try RemoteDirectoryListing(
                directory: inner,
                entries: [
                    try RemoteFileEntry(path: deep, kind: .regular),
                    try RemoteFileEntry(path: lossyDeep, kind: .regular)
                ]
            ),
            betaListing: try RemoteDirectoryListing(
                directory: beta,
                entries: [
                    try RemoteFileEntry(path: betaChild, kind: .regular)
                ]
            )
        )
    }

    private func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}
