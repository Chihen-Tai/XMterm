/// One row of the flattened visible tree.
public struct RemoteWorkspaceVisibleRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case entry(
            RemoteFileEntry,
            isExpanded: Bool,
            childState: RemoteDirectoryLoadState?
        )
        case childStatus(
            RemotePath,
            RemoteDirectoryLoadState,
            allowsRetry: Bool
        )
    }

    public enum ID: Hashable, Sendable {
        case entry(RemotePath)
        case childStatus(RemotePath)
    }

    public let depth: Int
    public let kind: Kind

    public var id: ID {
        switch kind {
        case let .entry(entry, _, _):
            .entry(entry.path)
        case let .childStatus(path, _, _):
            .childStatus(path)
        }
    }

    public init(depth: Int, kind: Kind) {
        self.depth = depth
        self.kind = kind
    }
}

/// The one shared pure projection of the bounded visible tree.
///
/// Both the sidebar's rendered rows and the workspace's selection validation are
/// derived from this projection, so what the user sees and what may become the
/// selection can never diverge. It walks only the current listing plus
/// already-loaded listings of expanded directories — no provider work, no
/// recursion beyond the bounded expansion depth, no per-entry task.
public struct RemoteWorkspaceVisibleEntryProjection: Sendable {
    /// Derived from the workspace's one expansion bound so projection and
    /// selection validation cannot drift from the state machine limit.
    public static let maximumDepth = RemoteWorkspace.maximumExpandedDirectoryCount

    public let rows: [RemoteWorkspaceVisibleRow]
    /// The stable order of every selectable row. This is the only ordering used
    /// by range selection and batch selection; `selectablePaths` is retained for
    /// membership checks.
    public let orderedSelectablePaths: [RemotePath]
    public let selectablePaths: Set<RemotePath>

    private let entriesByPath: [RemotePath: RemoteFileEntry]

    public init(
        currentListing: RemoteDirectoryListing?,
        expandedDirectories: Set<RemotePath>,
        directoryStates: [RemotePath: RemoteDirectoryLoadState]
    ) {
        var rows: [RemoteWorkspaceVisibleRow] = []
        var entriesByPath: [RemotePath: RemoteFileEntry] = [:]
        if let currentListing {
            Self.append(
                entries: currentListing.entries,
                depth: 0,
                expandedDirectories: expandedDirectories,
                directoryStates: directoryStates,
                rows: &rows,
                entriesByPath: &entriesByPath
            )
        }
        self.rows = rows
        self.entriesByPath = entriesByPath
        orderedSelectablePaths = rows.compactMap { row in
            guard case let .entry(entry, _, _) = row.kind else { return nil }
            return entry.path
        }
        selectablePaths = Set(orderedSelectablePaths)
    }

    public func entry(for path: RemotePath) -> RemoteFileEntry? {
        entriesByPath[path]
    }

    public func isSelectable(_ path: RemotePath) -> Bool {
        entriesByPath[path] != nil
    }

    private static func append(
        entries: [RemoteFileEntry],
        depth: Int,
        expandedDirectories: Set<RemotePath>,
        directoryStates: [RemotePath: RemoteDirectoryLoadState],
        rows: inout [RemoteWorkspaceVisibleRow],
        entriesByPath: inout [RemotePath: RemoteFileEntry]
    ) {
        guard depth <= maximumDepth else { return }
        for entry in entries {
            let isDirectory = entry.kind == .directory
            let isExpanded = isDirectory
                && expandedDirectories.contains(entry.path)
            let childState = isDirectory ? directoryStates[entry.path] : nil
            rows.append(
                RemoteWorkspaceVisibleRow(
                    depth: depth,
                    kind: .entry(
                        entry,
                        isExpanded: isExpanded,
                        childState: childState
                    )
                )
            )
            entriesByPath[entry.path] = entry

            guard let childState, depth < maximumDepth else { continue }
            guard isExpanded else {
                // A collapsed directory whose last load failed or was cancelled
                // still displays that outcome honestly beneath its row
                // (FILE-NAV-002); retry there is re-opening or re-expanding.
                if isFailedOrCancelled(childState) {
                    rows.append(
                        RemoteWorkspaceVisibleRow(
                            depth: depth + 1,
                            kind: .childStatus(
                                entry.path,
                                childState,
                                allowsRetry: false
                            )
                        )
                    )
                }
                continue
            }
            if let children = childState.visibleListing?.entries, !children.isEmpty {
                append(
                    entries: children,
                    depth: depth + 1,
                    expandedDirectories: expandedDirectories,
                    directoryStates: directoryStates,
                    rows: &rows,
                    entriesByPath: &entriesByPath
                )
            }
            if !isLoaded(childState) {
                rows.append(
                    RemoteWorkspaceVisibleRow(
                        depth: depth + 1,
                        kind: .childStatus(
                            entry.path,
                            childState,
                            allowsRetry: true
                        )
                    )
                )
            }
        }
    }

    private static func isLoaded(_ state: RemoteDirectoryLoadState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    private static func isFailedOrCancelled(
        _ state: RemoteDirectoryLoadState
    ) -> Bool {
        switch state {
        case .failed, .cancelled: true
        case .notLoaded, .loading, .loaded, .empty: false
        }
    }
}
