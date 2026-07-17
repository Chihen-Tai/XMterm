public enum RemoteDirectoryCacheError: Error, Equatable, Sendable {
  case listingExceedsTotalEntryLimit(
    directory: RemotePath,
    maximum: Int,
    actual: Int
  )
}

public struct RemoteDirectoryCache: Equatable, Sendable {
  public static let defaultMaximumListingCount = 32
  public static let defaultMaximumTotalEntryCount = 20_000

  public struct Access: Equatable, Sendable {
    public let listing: RemoteDirectoryListing?
    public let cache: RemoteDirectoryCache

    fileprivate init(
      listing: RemoteDirectoryListing?,
      cache: RemoteDirectoryCache
    ) {
      self.listing = listing
      self.cache = cache
    }
  }

  public let maximumListingCount: Int
  public let maximumTotalEntryCount: Int
  public let pinnedDirectory: RemotePath?
  public let totalEntryCount: Int

  public var listingCount: Int {
    items.count
  }

  var retainedDirectories: Set<RemotePath> {
    Set(items.keys)
  }

  private struct Item: Equatable, Sendable {
    let listing: RemoteDirectoryListing
    let accessOrder: UInt64
  }

  private let items: [RemotePath: Item]
  private let lastAccessOrder: UInt64

  public init(
    maximumListingCount: Int = Self.defaultMaximumListingCount,
    maximumTotalEntryCount: Int = Self.defaultMaximumTotalEntryCount
  ) {
    precondition(maximumListingCount >= 0)
    precondition(maximumTotalEntryCount >= 0)

    self.maximumListingCount = maximumListingCount
    self.maximumTotalEntryCount = maximumTotalEntryCount
    pinnedDirectory = nil
    totalEntryCount = 0
    items = [:]
    lastAccessOrder = 0
  }

  public func accessing(_ directory: RemotePath) -> Access {
    guard let item = items[directory] else {
      return Access(listing: nil, cache: self)
    }

    let accessOrder = nextAccessOrder
    var replacementItems = items
    replacementItems[directory] = Item(
      listing: item.listing,
      accessOrder: accessOrder
    )
    return Access(
      listing: item.listing,
      cache: replacing(
        items: replacementItems,
        totalEntryCount: totalEntryCount,
        lastAccessOrder: accessOrder
      )
    )
  }

  public func inserting(_ listing: RemoteDirectoryListing) throws -> Self {
    let entryCount = listing.entries.count
    guard entryCount <= maximumTotalEntryCount else {
      throw RemoteDirectoryCacheError.listingExceedsTotalEntryLimit(
        directory: listing.directory,
        maximum: maximumTotalEntryCount,
        actual: entryCount
      )
    }

    let accessOrder = nextAccessOrder
    let replacedEntryCount = items[listing.directory]?.listing.entries.count ?? 0
    var replacementItems = items
    replacementItems[listing.directory] = Item(
      listing: listing,
      accessOrder: accessOrder
    )
    let replacementTotal = totalEntryCount - replacedEntryCount + entryCount

    return replacing(
      items: replacementItems,
      totalEntryCount: replacementTotal,
      lastAccessOrder: accessOrder
    ).evictingToBounds()
  }

  public func pinning(_ directory: RemotePath?) -> Self {
    Self(
      maximumListingCount: maximumListingCount,
      maximumTotalEntryCount: maximumTotalEntryCount,
      pinnedDirectory: directory,
      totalEntryCount: totalEntryCount,
      items: items,
      lastAccessOrder: lastAccessOrder
    )
  }

  public func invalidating(_ directory: RemotePath) -> Self {
    guard let removed = items[directory] else { return self }

    var replacementItems = items
    replacementItems.removeValue(forKey: directory)
    return replacing(
      items: replacementItems,
      totalEntryCount: totalEntryCount - removed.listing.entries.count,
      lastAccessOrder: lastAccessOrder
    )
  }

  public func clearing() -> Self {
    Self(
      maximumListingCount: maximumListingCount,
      maximumTotalEntryCount: maximumTotalEntryCount
    )
  }

  private init(
    maximumListingCount: Int,
    maximumTotalEntryCount: Int,
    pinnedDirectory: RemotePath?,
    totalEntryCount: Int,
    items: [RemotePath: Item],
    lastAccessOrder: UInt64
  ) {
    self.maximumListingCount = maximumListingCount
    self.maximumTotalEntryCount = maximumTotalEntryCount
    self.pinnedDirectory = pinnedDirectory
    self.totalEntryCount = totalEntryCount
    self.items = items
    self.lastAccessOrder = lastAccessOrder
  }

  private var nextAccessOrder: UInt64 {
    precondition(lastAccessOrder < UInt64.max)
    return lastAccessOrder + 1
  }

  private func replacing(
    items: [RemotePath: Item],
    totalEntryCount: Int,
    lastAccessOrder: UInt64
  ) -> Self {
    Self(
      maximumListingCount: maximumListingCount,
      maximumTotalEntryCount: maximumTotalEntryCount,
      pinnedDirectory: pinnedDirectory,
      totalEntryCount: totalEntryCount,
      items: items,
      lastAccessOrder: lastAccessOrder
    )
  }

  private func evictingToBounds() -> Self {
    var replacementItems = items
    var replacementTotal = totalEntryCount

    while replacementItems.count > maximumListingCount
      || replacementTotal > maximumTotalEntryCount
    {
      guard let directory = evictionCandidate(in: replacementItems),
        let removed = replacementItems.removeValue(forKey: directory)
      else {
        break
      }
      replacementTotal -= removed.listing.entries.count
    }

    return replacing(
      items: replacementItems,
      totalEntryCount: replacementTotal,
      lastAccessOrder: lastAccessOrder
    )
  }

  private func evictionCandidate(in items: [RemotePath: Item]) -> RemotePath? {
    let unpinned = items.filter { $0.key != pinnedDirectory }
    return leastRecentDirectory(in: unpinned.isEmpty ? items : unpinned)
  }

  private func leastRecentDirectory(
    in items: [RemotePath: Item]
  ) -> RemotePath? {
    items.min { left, right in
      if left.value.accessOrder != right.value.accessOrder {
        return left.value.accessOrder < right.value.accessOrder
      }
      return left.key.rawBytes.lexicographicallyPrecedes(right.key.rawBytes)
    }?.key
  }
}
