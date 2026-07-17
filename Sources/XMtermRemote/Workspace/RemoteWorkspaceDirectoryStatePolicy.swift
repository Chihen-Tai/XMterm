enum RemoteWorkspaceDirectoryStatePolicy {
  static func listingState(
    _ listing: RemoteDirectoryListing
  ) -> RemoteDirectoryLoadState {
    listing.entries.isEmpty ? .empty(listing) : .loaded(listing)
  }

  static func isFailedOrCancelled(
    _ state: RemoteDirectoryLoadState?
  ) -> Bool {
    switch state {
    case .failed, .cancelled: true
    default: false
    }
  }

  static func reconcilingListingPayloads(
    in states: [RemotePath: RemoteDirectoryLoadState],
    retainedDirectories: Set<RemotePath>
  ) -> [RemotePath: RemoteDirectoryLoadState] {
    states.mapValues { state in
      guard let listing = state.visibleListing,
        !retainedDirectories.contains(listing.directory)
      else {
        return state
      }
      return withoutListingPayload(state)
    }
  }

  static func retainingOnlyCachedListing(
    _ state: RemoteDirectoryLoadState,
    for directory: RemotePath,
    retainedDirectories: Set<RemotePath>
  ) -> RemoteDirectoryLoadState {
    guard state.visibleListing != nil,
      !retainedDirectories.contains(directory)
    else {
      return state
    }
    return withoutListingPayload(state)
  }

  private static func withoutListingPayload(
    _ state: RemoteDirectoryLoadState
  ) -> RemoteDirectoryLoadState {
    switch state {
    case .notLoaded:
      .notLoaded
    case .loading:
      .loading(previousListing: nil)
    case .loaded, .empty:
      .notLoaded
    case .failed(let error, _):
      .failed(error: error, previousListing: nil)
    case .cancelled:
      .cancelled(previousListing: nil)
    }
  }
}
