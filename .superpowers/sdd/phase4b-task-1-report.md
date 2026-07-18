# Phase 4B Task 1 — Selection Model and Workspace Migration

## Status

DONE. No commits, merges, pushes, or tags were created.

## Implementation

- Added immutable `RemoteSelectionState`, with ordered exact `RemotePath` output,
  range anchor, keyboard focus, and only transient local `Set` membership.
- Implemented click, Command-click, Shift-click, Command-Shift-click, focus
  movement, Shift-focus extension, Select All, clear, context-click, and visible
  projection reconciliation. The state never owns or contacts a provider.
- Added `orderedSelectablePaths` to the existing visible-entry projection. This
  projection remains the sole visible-row ordering used by ranges and batch paths.
- Replaced `RemoteWorkspace`'s mutable `selectedEntry` storage with
  `selection: RemoteSelectionState`. The remaining `selectedEntry` is a read-only
  compatibility projection that returns a path only for exactly one selected row.
- Added workspace selection intent methods while retaining `selectEntry` for the
  Phase 4A single-selection callers.
- Migrated refresh requests, history locations, navigation restoration, collapse,
  cache/visible-row repair, and close reset to selection values and reconciliation.
  Refresh and history preserve exact raw paths only. The existing Phase 4A cache
  eviction behavior remains: a hidden selected descendant repairs to the nearest
  visible ancestor directory, after reconciliation.
- Preserved history-budget behavior for the legacy single-selection form while
  accounting for unique multi-selection/anchor/focus paths.

## RED evidence

Required command, run first after adding the test:

```sh
swift test -Xswiftc -warnings-as-errors --filter RemoteSelectionStateTests
```

It failed before compiling the new test because the Command Line Tools Swift
invocation did not add the repository's existing `Testing.framework`:

```text
Tests/XMtermCoreTests/SSHTerminalTargetTests.swift:2:8: error: no such module 'Testing'
```

The repository verifier supplies that framework on this host. Re-running the same
focused test with those documented flags reached the intended RED:

```sh
swift test -Xswiftc -warnings-as-errors \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter RemoteSelectionStateTests
```

Expected missing-API output:

```text
Tests/XMtermRemoteTests/RemoteSelectionStateTests.swift:9:23: error: cannot find 'RemoteSelectionState' in scope
```

## GREEN evidence

- `RemoteSelectionStateTests`: **13 tests / 1 suite passed** after the review
  corrections.
- Final focused selection/workspace command (same framework flags), filtering
  `Remote(SelectionState|WorkspaceDescendantSelection|WorkspaceVisibleEntryProjection|WorkspaceTests)`: **48 tests / 4 suites passed** before the final history test.
- Final descendant-selection regression (same framework flags), filtering
  `RemoteWorkspaceDescendantSelectionTests`: **15 tests / 1 suite passed**,
  including complete ordered history restoration.
- `./scripts/verify.sh`: **487 tests / 60 suites passed**; output ended with
  `XMterm verification: OK`.

## Files changed

- `Sources/XMtermRemote/Selection/RemoteSelectionState.swift`
- `Sources/XMtermRemote/Workspace/RemoteWorkspace.swift`
- `Sources/XMtermRemote/Workspace/RemoteWorkspaceVisibleEntryProjection.swift`
- `Sources/XMtermRemote/Workspace/RemoteWorkspaceState.swift`
- `Sources/XMtermRemote/Workspace/RemoteWorkspaceHistoryPolicy.swift`
- `Sources/XMtermRemote/Workspace/RemoteWorkspaceRequest.swift`
- `Tests/XMtermRemoteTests/RemoteSelectionStateTests.swift`
- `Tests/XMtermRemoteTests/RemoteWorkspaceDescendantSelectionTests.swift`
- `Tests/XMtermRemoteTests/RemoteWorkspaceVisibleEntryProjectionTests.swift`
- `.superpowers/sdd/phase4b-task-1-report.md`

## Self-review

- Exact identity: every membership, range, reconciliation, projection, and history
  operation uses `RemotePath`; tests cover distinct lossy byte paths and same display
  names without display-name matching.
- Context-click: a selected visible row preserves the full selection; an unselected
  visible row replaces it. The workspace exposes the corresponding typed intent for
  the later sidebar migration.
- Complexity: projection ordering is built once from visible rows; each selection
  operation is linear in visible paths and uses only short-lived local sets. No
  provider call, task, or I/O appears in selection code.
- Interaction parity: the domain and workspace now cover the required pointer,
  keyboard, focus, Escape, context-click, collapse, refresh, history, and
  per-runtime isolation semantics for `FILE-SEL-001`, `FILE-NAV-002`, and
  `SESS-011`. Sidebar gesture/rendering work remains intentionally outside this
  selection-only task.
- Phase 4A regression: cache eviction still repairs an otherwise hidden selected
  descendant to its nearest visible ancestor; refresh/history remain strict exact
  raw-path reconciliation.
- Independent spec review found and verified two repaired issues: empty-state
  Down/Up/Shift-Down now start at the first/last visible row instead of applying
  the delta twice, and `RemoteWorkspaceLocation.selectedEntry` now returns a
  compatibility value only for exactly one selected path, matching live workspace
  behavior. Focused RED tests captured the former failure; both regressions pass
  in the final focused and full verification runs.

## Concerns

- Direct `swift test` on this Command Line Tools host needs the `Testing.framework`
  flags already embedded in `scripts/verify.sh`; the report records both the exact
  mandated command's environmental failure and the subsequent valid missing-type
  RED.
- None beyond the documented Command Line Tools `Testing.framework` invocation
  detail above.
