import Testing

@testable import XMtermRemote

@Suite("Bounded remote directory cache")
struct RemoteDirectoryCacheTests {
    @Test("[FILE-CACHE-001] Defaults, misses, hits, and replacements preserve immutable values")
    func defaultsMissesHitsAndReplacementsAreImmutable() throws {
        let directory = try remotePath("/workspace")
        let firstListing = try listing(in: directory, names: ["first.txt"])
        let replacementListing = try listing(
            in: directory,
            names: ["replacement-a.txt", "replacement-b.txt"]
        )
        let empty = RemoteDirectoryCache()

        let miss = empty.accessing(directory)
        let inserted = try empty.inserting(firstListing)
        let firstHit = inserted.accessing(directory)
        let replaced = try inserted.inserting(replacementListing)
        let replacementHit = replaced.accessing(directory)

        #expect(RemoteDirectoryCache.defaultMaximumListingCount == 32)
        #expect(RemoteDirectoryCache.defaultMaximumTotalEntryCount == 20_000)
        #expect(empty.maximumListingCount == 32)
        #expect(empty.maximumTotalEntryCount == 20_000)
        #expect(miss.listing == nil)
        #expect(miss.cache.listingCount == 0)
        #expect(empty.listingCount == 0)
        #expect(empty.totalEntryCount == 0)
        #expect(firstHit.listing == firstListing)
        #expect(inserted.listingCount == 1)
        #expect(inserted.totalEntryCount == 1)
        #expect(replacementHit.listing == replacementListing)
        #expect(replaced.listingCount == 1)
        #expect(replaced.totalEntryCount == 2)
        #expect(inserted.accessing(directory).listing == firstListing)
        requireSendable(empty)
        requireSendable(firstHit)
    }

    @Test("[FILE-CACHE-001] A hit makes that listing most recent for deterministic LRU eviction")
    func hitUpdatesDeterministicRecency() throws {
        let first = try emptyListing(at: "/first")
        let second = try emptyListing(at: "/second")
        let third = try emptyListing(at: "/third")
        let firstPath = first.directory
        let secondPath = second.directory
        let thirdPath = third.directory
        let empty = RemoteDirectoryCache(
            maximumListingCount: 2,
            maximumTotalEntryCount: 10
        )
        let twoListings = try empty.inserting(first).inserting(second)

        let touchedFirst = twoListings.accessing(firstPath)
        let evicted = try touchedFirst.cache.inserting(third)

        #expect(touchedFirst.listing == first)
        #expect(evicted.accessing(firstPath).listing == first)
        #expect(evicted.accessing(secondPath).listing == nil)
        #expect(evicted.accessing(thirdPath).listing == third)
        #expect(evicted.listingCount == 2)
        #expect(twoListings.accessing(secondPath).listing == second)
        #expect(twoListings.accessing(thirdPath).listing == nil)
    }

    @Test("[FILE-CACHE-001] The default listing bound evicts the least-recent of 33 directories")
    func defaultThirtyTwoDirectoryBoundEvictsLeastRecent() throws {
        let listings = try (0...RemoteDirectoryCache.defaultMaximumListingCount).map { index in
            try emptyListing(at: "/directory-\(index)")
        }
        let cache = try listings.reduce(RemoteDirectoryCache()) { cache, listing in
            try cache.inserting(listing)
        }
        let lastListing = try #require(listings.last)

        #expect(cache.listingCount == RemoteDirectoryCache.defaultMaximumListingCount)
        #expect(cache.accessing(listings[0].directory).listing == nil)
        #expect(cache.accessing(listings[1].directory).listing == listings[1])
        #expect(cache.accessing(lastListing.directory).listing == lastListing)
    }

    @Test("[FILE-CACHE-001] The default total-entry bound evicts whole least-recent listings")
    func defaultTwentyThousandEntryBoundEvictsWholeListings() throws {
        let first = try listing(
            in: remotePath("/first-large"),
            entryCount: RemoteDirectoryListing.maximumEntryCount
        )
        let second = try listing(
            in: remotePath("/second-large"),
            entryCount: RemoteDirectoryListing.maximumEntryCount
        )
        let overflow = try listing(in: remotePath("/overflow"), entryCount: 1)
        let cache = try RemoteDirectoryCache()
            .inserting(first)
            .inserting(second)
            .inserting(overflow)

        #expect(cache.maximumTotalEntryCount == 20_000)
        #expect(cache.listingCount == 2)
        #expect(cache.totalEntryCount == RemoteDirectoryListing.maximumEntryCount + 1)
        #expect(cache.accessing(first.directory).listing == nil)
        #expect(cache.accessing(second.directory).listing == second)
        #expect(cache.accessing(overflow.directory).listing == overflow)
    }

    @Test("[FILE-CACHE-001] One listing over the configured total-entry bound is rejected atomically")
    func oversizedSingleListingReturnsTypedError() throws {
        let directory = try remotePath("/oversized")
        let oversized = try listing(in: directory, entryCount: 2)
        let cache = RemoteDirectoryCache(
            maximumListingCount: 2,
            maximumTotalEntryCount: 1
        )

        #expect(
            throws: RemoteDirectoryCacheError.listingExceedsTotalEntryLimit(
                directory: directory,
                maximum: 1,
                actual: 2
            )
        ) {
            try cache.inserting(oversized)
        }
        #expect(cache.listingCount == 0)
        #expect(cache.totalEntryCount == 0)
        #expect(cache.accessing(directory).listing == nil)
    }

    @Test("[FILE-CACHE-001] Atomic replacement accounts for the old listing before eviction")
    func atomicReplacementAdjustsBoundsBeforeEviction() throws {
        let currentDirectory = try remotePath("/current")
        let sibling = try listing(in: remotePath("/sibling"), entryCount: 1)
        let original = try listing(in: currentDirectory, entryCount: 2, stem: "old")
        let replacement = try listing(in: currentDirectory, entryCount: 3, stem: "new")
        let initial = try RemoteDirectoryCache(
            maximumListingCount: 2,
            maximumTotalEntryCount: 3
        )
        .inserting(original)
        .inserting(sibling)

        let replaced = try initial.inserting(replacement)

        #expect(replaced.listingCount == 1)
        #expect(replaced.totalEntryCount == 3)
        #expect(replaced.accessing(currentDirectory).listing == replacement)
        #expect(replaced.accessing(sibling.directory).listing == nil)
        #expect(initial.accessing(currentDirectory).listing == original)
        #expect(initial.accessing(sibling.directory).listing == sibling)
    }

    @Test("[FILE-CACHE-001] One current-directory pin survives publication and may evict the new item")
    func currentDirectoryPinProtectsPublication() throws {
        let prior = try emptyListing(at: "/prior")
        let current = try emptyListing(at: "/current")
        let incoming = try emptyListing(at: "/incoming")
        let base = try RemoteDirectoryCache(
            maximumListingCount: 1,
            maximumTotalEntryCount: 10
        ).inserting(prior)
        let pinned = base.pinning(current.directory)

        let published = try pinned.inserting(current)
        let stillBounded = try published.inserting(incoming)
        let unpinned = published.pinning(nil)
        let replacedAfterUnpin = try unpinned.inserting(incoming)

        #expect(base.pinnedDirectory == nil)
        #expect(base.accessing(prior.directory).listing == prior)
        #expect(pinned.pinnedDirectory == current.directory)
        #expect(published.accessing(prior.directory).listing == nil)
        #expect(published.accessing(current.directory).listing == current)
        #expect(stillBounded.listingCount == 1)
        #expect(stillBounded.accessing(current.directory).listing == current)
        #expect(stillBounded.accessing(incoming.directory).listing == nil)
        #expect(replacedAfterUnpin.accessing(current.directory).listing == nil)
        #expect(replacedAfterUnpin.accessing(incoming.directory).listing == incoming)
    }

    @Test("[FILE-CACHE-001] Targeted invalidation removes only its exact directory")
    func targetedInvalidationLeavesUnrelatedListingsIntact() throws {
        let target = try listing(in: remotePath("/target"), entryCount: 2)
        let unrelated = try listing(in: remotePath("/unrelated"), entryCount: 1)
        let populated = try RemoteDirectoryCache()
            .inserting(target)
            .inserting(unrelated)

        let invalidated = populated.invalidating(target.directory)

        #expect(invalidated.listingCount == 1)
        #expect(invalidated.totalEntryCount == 1)
        #expect(invalidated.accessing(target.directory).listing == nil)
        #expect(invalidated.accessing(unrelated.directory).listing == unrelated)
        #expect(populated.accessing(target.directory).listing == target)
        #expect(populated.accessing(unrelated.directory).listing == unrelated)
    }

    @Test("[FILE-NAV-002] Cached entries retain exact raw-path identity for selection restoration")
    func cachedListingPreservesSelectionRestorationIdentity() throws {
        let directory = try remotePath("/selection")
        let rawName = try RemotePathComponent(rawBytes: [0x66, 0x80, 0x2D, 0x31])
        let selectedPath = try directory.appending(rawName)
        let selectedEntry = try RemoteFileEntry(
            path: selectedPath,
            kind: .regular,
            size: 42,
            permissions: 0o640,
            metadataCompleteness: .complete
        )
        let listing = try RemoteDirectoryListing(
            directory: directory,
            entries: [selectedEntry],
            metadataCompleteness: .complete,
            providerCapabilityNotes: "Exact raw identity"
        )
        let cached = try RemoteDirectoryCache().inserting(listing)

        let hit = cached.accessing(directory)
        let restored = hit.listing?.entries.first { $0.id == selectedPath }

        #expect(hit.listing == listing)
        #expect(hit.listing?.directory == directory)
        #expect(restored == selectedEntry)
        #expect(restored?.id == selectedPath)
        #expect(restored?.name.rawBytes == rawName.rawBytes)
        #expect(restored?.path.rawBytes == selectedPath.rawBytes)
    }

    @Test("[FILE-CACHE-001] Clearing on runtime close drops listings, accounting, and pin")
    func clearOnCloseReturnsAnEmptyReplacement() throws {
        let listing = try listing(in: remotePath("/current"), entryCount: 2)
        let populated = try RemoteDirectoryCache()
            .inserting(listing)
            .pinning(listing.directory)

        let cleared = populated.clearing()

        #expect(cleared.listingCount == 0)
        #expect(cleared.totalEntryCount == 0)
        #expect(cleared.pinnedDirectory == nil)
        #expect(cleared.accessing(listing.directory).listing == nil)
        #expect(populated.listingCount == 1)
        #expect(populated.totalEntryCount == 2)
        #expect(populated.pinnedDirectory == listing.directory)
        #expect(populated.accessing(listing.directory).listing == listing)
    }

    private func emptyListing(at path: String) throws -> RemoteDirectoryListing {
        try RemoteDirectoryListing(directory: remotePath(path), entries: [])
    }

    private func listing(
        in directory: RemotePath,
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

    private func listing(
        in directory: RemotePath,
        entryCount: Int,
        stem: String = "item"
    ) throws -> RemoteDirectoryListing {
        let entries = try (0..<entryCount).map { index in
            let name = try RemotePathComponent(rawBytes: Array("\(stem)-\(index)".utf8))
            return try RemoteFileEntry(
                path: directory.appending(name),
                kind: .regular
            )
        }
        return try RemoteDirectoryListing(directory: directory, entries: entries)
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func requireSendable<Value: Sendable>(_ value: Value) {}
}
