import Foundation
import Testing
import XMtermRemote

@Suite("Remote workspace performance evidence", .serialized)
struct RemoteWorkspacePerformanceTests {
  private static let entryCount = 1_000
  private static let measuredRunCount = 11
  private static let lookupIterationCount = 1_000

  @Test("[FILE-CACHE-001, FILE-LIST-001] A diverse 1,000-entry listing publishes within budget")
  func diverseThousandEntryListingPublishesWithinBudget() throws {
    let clock = ContinuousClock()
    let directory = try RemotePath(rawBytes: Array("/performance".utf8))

    let fixtureStartedAt = clock.now
    let fixture = try makeFixture(in: directory)
    let fixtureConstructionElapsed = fixtureStartedAt.duration(to: clock.now)

    let warmup = try publish(fixture, in: directory)
    var elapsedSamples: [Duration] = []
    var publications: [Publication] = []
    elapsedSamples.reserveCapacity(Self.measuredRunCount)
    publications.reserveCapacity(Self.measuredRunCount)

    for _ in 0..<Self.measuredRunCount {
      let startedAt = clock.now
      let publication = try publish(fixture, in: directory)
      let elapsed = startedAt.duration(to: clock.now)

      elapsedSamples.append(elapsed)
      publications.append(publication)
    }

    let orderedSamples = elapsedSamples.sorted()
    let percentile90Index = ((orderedSamples.count * 9) + 9) / 10 - 1
    let percentile90 = orderedSamples[percentile90Index]
    let slowest = try #require(orderedSamples.last)
    let listing = warmup.listing

    #expect(fixture.count == Self.entryCount)
    #expect(listing.entries.count == Self.entryCount)
    #expect(Set(listing.entries.map(\.path)).count == Self.entryCount)
    #expect(isInDefaultOrder(listing.entries))
    #expect(publications.allSatisfy { $0.listing.entries == listing.entries })
    #expect(publications.allSatisfy { $0.cachedListing == $0.listing })
    #expect(publications.allSatisfy { $0.cache.listingCount == 1 })
    #expect(publications.allSatisfy { $0.cache.totalEntryCount == Self.entryCount })
    #expect(
      publications.allSatisfy {
        $0.cache.listingCount <= $0.cache.maximumListingCount
          && $0.cache.totalEntryCount <= $0.cache.maximumTotalEntryCount
      }
    )
    expectFixtureCoverage(in: listing.entries)
    #expect(
      percentile90 < .milliseconds(100),
      "Fixture construction was \(fixtureConstructionElapsed); model/order/cache publication p90 was \(percentile90) across \(Self.measuredRunCount) measured runs after one warm-up (slowest \(slowest))"
    )
  }

  @Test("[FILE-CACHE-001, FILE-LIST-001, FILE-PERF-001] A diverse 1,000-entry projection with exact lookups stays within budget")
  func diverseThousandEntryProjectionWithExactLookupsStaysWithinBudget() throws {
    let clock = ContinuousClock()
    let directory = try RemotePath(rawBytes: Array("/performance".utf8))

    let fixtureStartedAt = clock.now
    let fixture = try makeFixture(in: directory)
    let currentListing = try RemoteDirectoryListing(
      directory: directory,
      entries: fixture,
      metadataCompleteness: .partial,
      providerCapabilityNotes: "Mixed complete and partial metadata"
    )
    let expectedPath = currentListing.entries[723].path
    let missingPath = try directory.appending(
      RemotePathComponent(rawBytes: Array("missing.txt".utf8))
    )
    let fixtureConstructionElapsed = fixtureStartedAt.duration(to: clock.now)

    let warmup = RemoteWorkspaceVisibleEntryProjection(
      currentListing: currentListing,
      expandedDirectories: [],
      directoryStates: [:]
    )
    var elapsedSamples: [Duration] = []
    var projections: [RemoteWorkspaceVisibleEntryProjection] = []
    elapsedSamples.reserveCapacity(Self.measuredRunCount)
    projections.reserveCapacity(Self.measuredRunCount)

    for _ in 0..<Self.measuredRunCount {
      let startedAt = clock.now
      let projection = RemoteWorkspaceVisibleEntryProjection(
        currentListing: currentListing,
        expandedDirectories: [],
        directoryStates: [:]
      )
      for _ in 0..<Self.lookupIterationCount {
        _ = projection.entry(for: expectedPath)
        _ = projection.isSelectable(expectedPath)
        _ = projection.entry(for: missingPath)
        _ = projection.isSelectable(missingPath)
      }
      let elapsed = startedAt.duration(to: clock.now)

      elapsedSamples.append(elapsed)
      projections.append(projection)
    }

    let orderedSamples = elapsedSamples.sorted()
    let percentile90Index = ((orderedSamples.count * 9) + 9) / 10 - 1
    let percentile90 = orderedSamples[percentile90Index]
    let slowest = try #require(orderedSamples.last)
    let warmupIDs = warmup.rows.map(\.id)

    #expect(fixture.count == Self.entryCount)
    #expect(currentListing.entries.count == Self.entryCount)
    #expect(warmup.rows.count == Self.entryCount)
    #expect(warmup.selectablePaths.count == Self.entryCount)
    #expect(Set(warmupIDs) == Set(currentListing.entries.map { .entry($0.path) }))
    #expect(warmup.rows.allSatisfy { $0.depth == 0 })
    #expect(warmup.entry(for: expectedPath) == currentListing.entries[723])
    #expect(warmup.entry(for: missingPath) == nil)
    #expect(warmup.isSelectable(expectedPath))
    #expect(!warmup.isSelectable(missingPath))
    #expect(projections.allSatisfy { $0.rows.map(\.id) == warmupIDs })
    #expect(projections.allSatisfy { $0.selectablePaths == warmup.selectablePaths })
    #expect(
      projections.allSatisfy {
        $0.entry(for: expectedPath) == currentListing.entries[723]
      }
    )
    expectFixtureCoverage(in: currentListing.entries)
    #expect(
      percentile90 < .milliseconds(100),
      "Fixture construction was \(fixtureConstructionElapsed); projection construction plus \(Self.lookupIterationCount) exact lookup iterations p90 was \(percentile90) across \(Self.measuredRunCount) measured runs after one warm-up (slowest \(slowest))"
    )
  }

  private func makeFixture(in directory: RemotePath) throws -> [RemoteFileEntry] {
    try (0..<Self.entryCount).reversed().map { ordinal in
      let descriptor = fixtureDescriptor(for: ordinal)
      let component = try RemotePathComponent(rawBytes: Array(descriptor.name.utf8))
      let path = try directory.appending(component)
      let isPartial = ordinal.isMultiple(of: 2)
      let linkTarget =
        descriptor.kind == .symbolicLink
        ? try RemoteSymlinkTarget(rawBytes: Array("../target-\(ordinal)".utf8))
        : nil

      return try RemoteFileEntry(
        path: path,
        kind: descriptor.kind,
        size: isPartial ? nil : UInt64(ordinal * 17),
        modificationDate: isPartial
          ? nil
          : Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + ordinal)),
        permissions: isPartial ? nil : descriptor.permissions,
        symbolicLinkTarget: linkTarget,
        metadataCompleteness: isPartial ? .partial : .complete
      )
    }
  }

  private func fixtureDescriptor(
    for ordinal: Int
  ) -> (name: String, kind: RemoteFileEntry.Kind, permissions: UInt16) {
    let bucket = String(format: "%03d", ordinal / 10)

    switch ordinal % 10 {
    case 0: return ("ascii-\(bucket).txt", .directory, 0o755)
    case 1: return ("café-\(bucket).txt", .regular, 0o644)
    case 2: return ("cafe\u{301}-\(bucket).txt", .regular, 0o640)
    case 3: return ("研究-\(bucket)", .directory, 0o750)
    case 4: return ("🚀-\(bucket).log", .other, 0o600)
    case 5: return ("space name-\(bucket).txt", .regular, 0o644)
    case 6: return ("it's-\(bucket).txt", .regular, 0o600)
    case 7: return ("-option-\(bucket)", .regular, 0o755)
    case 8: return (".hidden-\(bucket)", .regular, 0o600)
    default: return ("symlink-\(bucket)", .symbolicLink, 0o777)
    }
  }

  private func publish(
    _ entries: [RemoteFileEntry],
    in directory: RemotePath
  ) throws -> Publication {
    let listing = try RemoteDirectoryListing(
      directory: directory,
      entries: entries,
      metadataCompleteness: .partial,
      providerCapabilityNotes: "Mixed complete and partial metadata"
    )
    let inserted = try RemoteDirectoryCache().inserting(listing)
    let access = inserted.accessing(directory)

    return Publication(
      listing: listing,
      cachedListing: access.listing,
      cache: access.cache
    )
  }

  private func isInDefaultOrder(_ entries: [RemoteFileEntry]) -> Bool {
    zip(entries, entries.dropFirst()).allSatisfy { left, right in
      !RemoteFileEntry.defaultOrdering(right, left)
    }
  }

  private func expectFixtureCoverage(in entries: [RemoteFileEntry]) {
    #expect(entries.contains { rawName(of: $0, startsWith: "ascii-") })
    #expect(entries.contains { rawName(of: $0, startsWith: "café-") })
    #expect(entries.contains { rawName(of: $0, startsWith: "cafe\u{301}-") })
    #expect(entries.contains { rawName(of: $0, startsWith: "研究-") })
    #expect(entries.contains { rawName(of: $0, startsWith: "🚀-") })
    #expect(entries.contains { $0.name.rawBytes.contains(0x20) })
    #expect(entries.contains { $0.name.rawBytes.contains(0x27) })
    #expect(entries.contains { $0.name.rawBytes.first == 0x2D })
    #expect(entries.contains { $0.isHidden })
    #expect(
      entries.contains {
        $0.kind == .symbolicLink && $0.symbolicLinkTarget != nil
      }
    )
    #expect(
      entries.contains {
        $0.metadataCompleteness == .partial
          && $0.size == nil
          && $0.modificationDate == nil
          && $0.permissions == nil
      }
    )
  }

  private func rawName(
    of entry: RemoteFileEntry,
    startsWith prefix: String
  ) -> Bool {
    entry.name.rawBytes.starts(with: prefix.utf8)
  }
}

private struct Publication {
  let listing: RemoteDirectoryListing
  let cachedListing: RemoteDirectoryListing?
  let cache: RemoteDirectoryCache
}
