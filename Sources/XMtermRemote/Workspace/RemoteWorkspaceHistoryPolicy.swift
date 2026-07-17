struct RemoteWorkspaceHistoryPolicy {
  static let maximumLocationCount = 128
  static let maximumByteCount = 1_024 * 1_024
  static let maximumScrollRestorationTokenByteCount = 4 * 1_024

  struct Histories {
    let back: [RemoteWorkspaceLocation]
    let forward: [RemoteWorkspaceLocation]
  }

  static func acceptedScrollRestorationToken(
    _ token: RemoteScrollRestorationToken?
  ) -> RemoteScrollRestorationToken? {
    guard let token else { return nil }
    guard
      token.rawValue.utf8.count
        <= maximumScrollRestorationTokenByteCount
    else {
      return nil
    }
    return token
  }

  static func bounded(
    back: [RemoteWorkspaceLocation],
    forward: [RemoteWorkspaceLocation]
  ) -> Histories {
    var boundedBack = back
    var boundedForward = forward

    while exceedsBudget(back: boundedBack, forward: boundedForward) {
      if shouldEvictBack(back: boundedBack, forward: boundedForward) {
        boundedBack = Array(boundedBack.dropFirst())
      } else {
        boundedForward = Array(boundedForward.dropFirst())
      }
    }
    return Histories(back: boundedBack, forward: boundedForward)
  }

  private static func exceedsBudget(
    back: [RemoteWorkspaceLocation],
    forward: [RemoteWorkspaceLocation]
  ) -> Bool {
    let locations = back + forward
    return locations.count > maximumLocationCount
      || locations.reduce(0) { $0 + byteCount(of: $1) } > maximumByteCount
  }

  private static func shouldEvictBack(
    back: [RemoteWorkspaceLocation],
    forward: [RemoteWorkspaceLocation]
  ) -> Bool {
    guard !back.isEmpty else { return false }
    guard !forward.isEmpty else { return true }
    if back.count != forward.count {
      return back.count > forward.count
    }
    return totalByteCount(of: back) >= totalByteCount(of: forward)
  }

  private static func totalByteCount(
    of locations: [RemoteWorkspaceLocation]
  ) -> Int {
    locations.reduce(0) { $0 + byteCount(of: $1) }
  }

  private static func byteCount(of location: RemoteWorkspaceLocation) -> Int {
    location.directory.rawBytes.count
      + (location.selectedEntry?.rawBytes.count ?? 0)
      + (location.scrollRestorationToken?.rawValue.utf8.count ?? 0)
  }
}
