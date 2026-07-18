/// Immutable Finder-style selection state for the visible Remote Workspace rows.
///
/// `visiblePaths` is always supplied by `RemoteWorkspaceVisibleEntryProjection`;
/// this value never loads directories or otherwise contacts a provider.
public struct RemoteSelectionState: Equatable, Sendable {
  public let orderedPaths: [RemotePath]
  public let anchor: RemotePath?
  public let focusedPath: RemotePath?

  public init() {
    self.init(orderedPaths: [], anchor: nil, focusedPath: nil)
  }

  public func clicking(
    _ path: RemotePath,
    command: Bool,
    shift: Bool,
    visiblePaths: [RemotePath]
  ) -> Self {
    let visiblePaths = Self.uniquePaths(in: visiblePaths)
    guard visiblePaths.contains(path) else { return copied() }

    if shift {
      let rangeAnchor = visiblePaths.contains(anchor ?? path) ? anchor ?? path : path
      let range = Self.inclusiveRange(
        from: rangeAnchor,
        to: path,
        in: visiblePaths
      )
      let selected = command
        ? Set(orderedPaths).union(range)
        : Set(range)
      return selection(
        selected,
        visiblePaths: visiblePaths,
        anchor: rangeAnchor,
        focusedPath: path
      )
    }

    if command {
      var selected = Set(orderedPaths)
      if selected.contains(path) {
        selected.remove(path)
      } else {
        selected.insert(path)
      }
      return selection(
        selected,
        visiblePaths: visiblePaths,
        anchor: selected.contains(path) ? path : anchor,
        focusedPath: path
      )
    }

    return Self(orderedPaths: [path], anchor: path, focusedPath: path)
  }

  public func contextClicking(
    _ path: RemotePath,
    visiblePaths: [RemotePath]
  ) -> Self {
    let visiblePaths = Self.uniquePaths(in: visiblePaths)
    guard visiblePaths.contains(path) else { return copied() }
    guard !orderedPaths.contains(path) else { return copied() }
    return Self(orderedPaths: [path], anchor: path, focusedPath: path)
  }

  public func movingFocus(
    by delta: Int,
    extending: Bool,
    visiblePaths: [RemotePath]
  ) -> Self {
    let visiblePaths = Self.uniquePaths(in: visiblePaths)
    guard !visiblePaths.isEmpty else { return clearing() }
    let currentFocus = focusedPath.flatMap { focus in
      visiblePaths.contains(focus) ? focus : nil
    } ?? orderedPaths.last(where: { visiblePaths.contains($0) })
    let destination: RemotePath
    if let currentFocus, let startIndex = visiblePaths.firstIndex(of: currentFocus) {
      let destinationIndex = min(
        max(startIndex + delta, 0),
        visiblePaths.count - 1
      )
      destination = visiblePaths[destinationIndex]
    } else {
      destination = delta < 0 ? visiblePaths[visiblePaths.count - 1] : visiblePaths[0]
    }
    guard extending else {
      return Self(
        orderedPaths: [destination],
        anchor: destination,
        focusedPath: destination
      )
    }
    let rangeAnchor = visiblePaths.contains(anchor ?? destination)
      ? anchor ?? destination
      : destination
    return selection(
      Set(Self.inclusiveRange(from: rangeAnchor, to: destination, in: visiblePaths)),
      visiblePaths: visiblePaths,
      anchor: rangeAnchor,
      focusedPath: destination
    )
  }

  public func selectingAll(visiblePaths: [RemotePath]) -> Self {
    let visiblePaths = Self.uniquePaths(in: visiblePaths)
    guard let first = visiblePaths.first else { return clearing() }
    return Self(orderedPaths: visiblePaths, anchor: first, focusedPath: first)
  }

  public func clearing() -> Self {
    Self()
  }

  public func reconciling(
    visiblePaths: [RemotePath],
    collapsedAncestor: RemotePath?
  ) -> Self {
    let visiblePaths = Self.uniquePaths(in: visiblePaths)
    var selected = Set(orderedPaths).intersection(Set(visiblePaths))
    let hidSelectedDescendant = collapsedAncestor.map { ancestor in
      orderedPaths.contains(where: ancestor.isAncestor(of:))
        && visiblePaths.contains(ancestor)
    } ?? false
    if let collapsedAncestor, hidSelectedDescendant {
      selected.insert(collapsedAncestor)
    }

    let repairedPaths = visiblePaths.filter { selected.contains($0) }
    guard !repairedPaths.isEmpty else { return clearing() }
    let repairedAnchor: RemotePath?
    if let anchor, visiblePaths.contains(anchor) {
      repairedAnchor = anchor
    } else if hidSelectedDescendant, let collapsedAncestor {
      repairedAnchor = collapsedAncestor
    } else {
      repairedAnchor = repairedPaths.first
    }
    let repairedFocus: RemotePath?
    if let focusedPath, visiblePaths.contains(focusedPath) {
      repairedFocus = focusedPath
    } else if hidSelectedDescendant, let collapsedAncestor {
      repairedFocus = collapsedAncestor
    } else {
      repairedFocus = repairedAnchor
    }
    return Self(
      orderedPaths: repairedPaths,
      anchor: repairedAnchor,
      focusedPath: repairedFocus
    )
  }

  private init(
    orderedPaths: [RemotePath],
    anchor: RemotePath?,
    focusedPath: RemotePath?
  ) {
    self.orderedPaths = orderedPaths
    self.anchor = anchor
    self.focusedPath = focusedPath
  }

  private func copied() -> Self {
    Self(orderedPaths: orderedPaths, anchor: anchor, focusedPath: focusedPath)
  }

  private func selection(
    _ selected: Set<RemotePath>,
    visiblePaths: [RemotePath],
    anchor: RemotePath?,
    focusedPath: RemotePath?
  ) -> Self {
    let orderedPaths = visiblePaths.filter { selected.contains($0) }
    guard !orderedPaths.isEmpty else { return clearing() }
    return Self(
      orderedPaths: orderedPaths,
      anchor: anchor ?? orderedPaths.first,
      focusedPath: focusedPath ?? anchor ?? orderedPaths.first
    )
  }

  private static func uniquePaths(in paths: [RemotePath]) -> [RemotePath] {
    var seen: Set<RemotePath> = []
    return paths.filter { seen.insert($0).inserted }
  }

  private static func inclusiveRange(
    from first: RemotePath,
    to second: RemotePath,
    in visiblePaths: [RemotePath]
  ) -> [RemotePath] {
    guard let firstIndex = visiblePaths.firstIndex(of: first),
      let secondIndex = visiblePaths.firstIndex(of: second)
    else {
      return [second]
    }
    let lowerBound = min(firstIndex, secondIndex)
    let upperBound = max(firstIndex, secondIndex)
    return Array(visiblePaths[lowerBound...upperBound])
  }
}
