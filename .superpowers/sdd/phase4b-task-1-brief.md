## Task 1 — Phase 4B.1 selection model and mutation domain

**Acceptance:** `APP-001`, `APP-004`, `FILE-SEL-001`, `FILE-NAV-002`,
`FILE-XFER-004`, `SESS-011`.

**Interfaces produced:**

```swift
public struct RemoteSelectionState: Equatable, Sendable {
    public let orderedPaths: [RemotePath]
    public let anchor: RemotePath?
    public let focusedPath: RemotePath?

    public func clicking(
        _ path: RemotePath,
        command: Bool,
        shift: Bool,
        visiblePaths: [RemotePath]
    ) -> Self
    public func movingFocus(by delta: Int, extending: Bool, visiblePaths: [RemotePath]) -> Self
    public func selectingAll(visiblePaths: [RemotePath]) -> Self
    public func clearing() -> Self
    public func reconciling(visiblePaths: [RemotePath], collapsedAncestor: RemotePath?) -> Self
}
```

- [ ] Add `RemoteSelectionStateTests` for click replace, Command toggle, Shift range,
  Command-Shift union, arrow movement, Shift-arrow, Command-A, Escape, context-click
  semantics, projection order, exact raw identity, duplicate lossy display names,
  collapse repair, refresh survivor/removal, and no provider I/O.
- [ ] Run the focused test and record RED caused by the missing type/API:
  `swift test -Xswiftc -warnings-as-errors --filter RemoteSelectionStateTests`.
- [ ] Implement the immutable selection value with ordered-array output and local
  transient sets only; every returned state is a new value.
- [ ] Replace `RemoteWorkspace.selectedEntry` storage with selection state. Keep a
  temporary read-only single-selection projection only for callers migrated later
  in this task; do not keep two mutable sources of truth.
- [ ] Update collapse, cache eviction, refresh, navigation/history, and visible-row
  repair to call `reconciling` without provider access.
- [ ] Add two-workspace tests proving selection/anchor isolation and selection-only
  call-count tests proving zero provider I/O.
- [ ] Run focused GREEN plus existing descendant/projection/workspace suites, then
  `./scripts/verify.sh`.
- [ ] Review exact identity, native context-click semantics, complexity, and
  interaction parity rows before marking the slice complete.

