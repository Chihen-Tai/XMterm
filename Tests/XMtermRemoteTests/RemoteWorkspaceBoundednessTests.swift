import Testing

@testable import XMtermRemote

@Suite("Bounded remote workspace state")
@MainActor
struct RemoteWorkspaceBoundednessTests {
  @Test("[FILE-CACHE-001] Initial publication fails if the configured cache cannot retain it")
  func initialListingMustFitTheConfiguredCache() async throws {
    let provider = ControllableRemoteFileProvider()
    let workspace = RemoteWorkspace(
      provider: provider,
      directoryCache: RemoteDirectoryCache(
        maximumListingCount: 0,
        maximumTotalEntryCount: 4
      )
    )
    let root = try remotePath("/root")
    let rootListing = try RemoteDirectoryListing(
      directory: root,
      entries: []
    )

    workspace.start()
    let resolve = await provider.nextAttempt()
    await provider.succeedResolve(requestID: resolve.requestID, path: root)
    let list = await provider.nextAttempt()
    await provider.succeedListing(requestID: list.requestID, listing: rootListing)
    await eventually {
      workspace.availability != .loadingInitialDirectory
    }

    #expect(
      workspace.availability
        == .failed(RemoteFileError(category: .limitExceeded))
    )
    #expect(workspace.currentDirectory == nil)
    #expect(workspace.currentListing == nil)
    #expect(workspace.cachedListingCount == 0)
  }

  @Test("[FILE-CACHE-001] Observable states do not retain listings evicted by the cache budget")
  func directoryStatePayloadsStayInsideCacheEntryBudget() async throws {
    let provider = ControllableRemoteFileProvider()
    let workspace = RemoteWorkspace(
      provider: provider,
      directoryCache: RemoteDirectoryCache(
        maximumListingCount: 4,
        maximumTotalEntryCount: 4
      )
    )
    let root = try remotePath("/root")
    let children = try ["first", "second", "third"].map { name in
      try root.appending(
        RemotePathComponent(rawBytes: Array(name.utf8))
      )
    }
    let rootListing = try listing(
      in: root,
      entries: [
        ("first", .directory),
        ("second", .directory),
        ("third", .directory),
      ]
    )
    await loadInitial(
      workspace,
      provider: provider,
      directory: root,
      listing: rootListing
    )

    for (index, child) in children.enumerated() {
      workspace.setExpanded(child, isExpanded: true)
      let attempt = await provider.nextAttempt()
      let childListing = try listing(
        in: child,
        entries: [("item-\(index)", .regular)]
      )
      await provider.succeedListing(
        requestID: attempt.requestID,
        listing: childListing
      )
      await eventually {
        workspace.directoryStates[child] == .loaded(childListing)
      }
    }

    let retainedEntryCount = workspace.directoryStates.values.reduce(0) {
      $0 + ($1.visibleListing?.entries.count ?? 0)
    }
    #expect(workspace.cachedListingCount == 2)
    #expect(retainedEntryCount <= 4)
    #expect(workspace.directoryStates[children[0]]?.visibleListing == nil)
    #expect(workspace.directoryStates[children[1]]?.visibleListing == nil)
  }

  @Test("[FILE-NAV-002] History count and restoration-token bytes remain bounded")
    func navigationHistoryAndRestorationTokensAreBounded() async throws {
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

    workspace.setScrollRestorationToken(
      RemoteScrollRestorationToken(
        rawValue: String(repeating: "x", count: 4_097)
      )
    )
    #expect(workspace.scrollRestorationToken == nil)

    workspace.openDirectory(child)
    let childAttempt = await provider.nextAttempt()
    let childListing = try RemoteDirectoryListing(
      directory: child,
      entries: []
    )
    await provider.succeedListing(
      requestID: childAttempt.requestID,
      listing: childListing
    )
    await eventually { workspace.currentDirectory == child }

    for _ in 0..<140 {
      workspace.goToParent()
      workspace.openDirectory(child)
    }

    #expect(workspace.backHistory.count + workspace.forwardHistory.count <= 128)
        #expect((await provider.snapshot()).attempts.count == 3)
    }

    @Test("[FILE-NAV-002] History has a combined raw-path and token byte budget")
    func historyByteBudgetCanEvictBeforeTheCountBudget() throws {
        let directory = try RemotePath(
            components: [
                RemotePathComponent(
                    rawBytes: Array(repeating: 0x64, count: 4_096)
                )
            ]
        )
        let selectedEntry = try directory.appending(
            RemotePathComponent(
                rawBytes: Array(repeating: 0x66, count: 4_096)
            )
        )
        let location = RemoteWorkspaceLocation(
            directory: directory,
            selectedEntry: selectedEntry,
            scrollRestorationToken: RemoteScrollRestorationToken(
                rawValue: String(repeating: "t", count: 4_096)
            )
        )
        let histories = RemoteWorkspaceHistoryPolicy.bounded(
            back: Array(repeating: location, count: 128),
            forward: []
        )
        let retained = histories.back + histories.forward
        let retainedByteCount = retained.reduce(0) { count, location in
            count
                + location.directory.rawBytes.count
                + (location.selectedEntry?.rawBytes.count ?? 0)
                + (location.scrollRestorationToken?.rawValue.utf8.count ?? 0)
        }

        #expect(retained.count < 128)
        #expect(retainedByteCount <= 1_024 * 1_024)
    }

  @Test("[FILE-CACHE-001] Request generations are released after unique paths settle")
  func settledRequestGenerationBookkeepingIsReleased() async throws {
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

    #expect(workspace.trackedRequestPathCount == 0)
    #expect(workspace.activeRequestCount == 0)
    #expect(workspace.queuedRequestCount == 0)
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
    Issue.record("Timed out waiting for deterministic bounded state")
  }

  private func remotePath(_ value: String) throws -> RemotePath {
    try RemotePath(rawBytes: Array(value.utf8))
  }
}
