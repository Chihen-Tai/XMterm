# Phase 4A Remote Workspace Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task-by-task,
> `superpowers:test-driven-development` for every behavior change, and
> `superpowers:verification-before-completion` before any completion claim.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate each launched tab to a session-centric runtime aggregate and add
a native, read-only, lazily loaded Remote Workspace with exact path identity,
bounded per-session state, deterministic providers, native navigation/copy
behavior, and complete cancellation/isolation tests.

**Architecture:** Keep saved profiles as immutable launch templates. Replace the
window store's tab-to-terminal registry with tab-to-`RuntimeSession`; compose the
existing retained `TerminalSession` and an optional `RemoteWorkspace` as isolated
siblings. Put path/entry values, provider protocol, deterministic providers,
bounded cache, and workspace state machine in a dependency-free `XMtermRemote`
target. Keep SwiftUI/AppKit presentation and pasteboard routing in `XMtermApp`.

**Tech Stack:** Swift 6, SwiftUI/AppKit on macOS 14+, Observation, Foundation,
Swift Testing, SwiftPM, existing SwiftTerm/PTY/OpenSSH terminal boundary.

---

- **Status:** Active — foundation execution approved; production transport blocked
- **Started:** 2026-07-16
- **Design:** [`../design-docs/remote-workspace.md`](../design-docs/remote-workspace.md)
- **Architecture ADR:**
  [`../decisions/0006-session-centric-runtime-architecture.md`](../decisions/0006-session-centric-runtime-architecture.md)
- **Transport ADR:**
  [`../decisions/0007-remote-file-provider-transport.md`](../decisions/0007-remote-file-provider-transport.md)
- **Checklist:**
  [`../checklists/remote-workspace-acceptance.md`](../checklists/remote-workspace-acceptance.md)
- **Baseline:** `./scripts/verify.sh` passed 268 tests in 35 suites on 2026-07-16
- **Repository state:** `XMterm-starter` is an untracked directory inside an
  unrelated parent repository; this plan uses direct inspection and verification,
  not misleading parent-repository commits

## Locked acceptance requirements

Existing applicable requirements:

- global/native: `APP-001` through `APP-004`, `APP-007`, `APP-008`, `A11Y-001`
  through `A11Y-003`, `MAC-001`, `MAC-002`, `MAC-006`;
- tab/session: `TAB-002`, `TAB-003`, `SESS-002` through `SESS-007`, `SESS-010`;
- remote files: the single-selection/read-only portions of `FILE-SEL-001`,
  `FILE-NAV-001`, `FILE-OPS-001`, `FILE-LIST-001`, `FILE-PERF-001`,
  `FILE-META-001`, and `FILE-XFER-004`.

Phase 4A additions, inserted in `INTERACTIONS.md` before production code:

- `SESS-011`: exact launched-runtime ownership of sibling capabilities;
- `FILE-WORKSPACE-001`: one read-only workspace per SSH runtime and none for local;
- `FILE-NAV-002`: success-only navigation publication, history, refresh,
  cancellation, and stale-response ordering;
- `FILE-CACHE-001`: bounded per-runtime immediate-child cache;
- `FILE-STATE-001`: honest workspace and child-directory states;
- `FILE-COPY-001`: exact path/name/parent/shell-quoted text actions.

`FILE-SEL-001`, `FILE-NAV-001`, `FILE-OPS-001`, `FILE-LIST-001`, `SESS-002`
through `SESS-006`, `MAC-001`, and related broad requirements remain Partial where
Phase 4A intentionally implements only a subset.

## Current architecture assessment

The implemented window architecture is:

```text
RootView
└── TerminalWorkspaceStore
    ├── TerminalTabsState
    └── [TerminalTab.ID: TerminalSession]
        ├── TerminalSessionID
        ├── immutable SessionLaunchSpecification
        ├── retained SwiftTerm view
        └── PTY or /usr/bin/ssh terminal process
```

`SessionProfileStore` is app-scoped and owns saved templates. A validated profile
becomes an immutable `SessionLaunchSpecification` before publication. The
workspace store prepares a terminal, creates a distinct tab/session pair, publishes
them, then starts the terminal. `TerminalSession` owns terminal-only state and
cleanup. `RootView` observes the store and keys the retained terminal presentation
by terminal-session identity.

This foundation is correct for profile isolation and terminal retention. It lacks
an aggregate that can own a provider/cache/navigation capability independently.
Phase 4A preserves `SessionProfile`, `SessionProfileStore`, launch snapshots,
`TerminalTab`, `TerminalSession`, `TerminalPane`, PTY behavior, and exact SSH
terminal arguments unless a focused compilation change proves necessary.

## Session-centric migration plan

The migrated ownership is:

```text
TerminalWorkspaceStore
└── [TerminalTab.ID: RuntimeSession]
    ├── id: TerminalSessionID
    ├── launchSpecification
    ├── terminal: TerminalSession
    └── remoteWorkspace: RemoteWorkspace?
        ├── provider
        ├── navigation/history/selection
        ├── bounded directory cache
        └── owned cancellable tasks
```

`RuntimeSession` is composed in `XMtermApp`, the only target that needs both
terminal and remote modules. The existing `TerminalSessionID` is retained as the
runtime identity for the incremental migration. Workspace eligibility comes from
the immutable `.ssh` launch target, never from profile ID or mutable profile data.

Starting and failing capabilities are isolated. Closing a tab requests close on its
terminal, cancels/closes its workspace, and publishes aggregate cleanup only after
both are settled. Switching tabs changes only which runtime's workspace is
presented. No workspace result may replace the runtime registry or recreate the
retained terminal view.

## Remote workspace ownership and state

Each SSH runtime constructs exactly one `RemoteWorkspace`; each local runtime has
`nil`. The workspace is `@MainActor`, owns every task it starts, and calls a
sendable provider for remote work. It stores only immutable listing values returned
from off-main work.

Owned state includes availability, current/pending paths, Back/Forward stacks,
per-location restoration values, selected path, expanded paths, per-directory
states, LRU cache, request generations, and explicit tasks for initial load,
navigation, refresh, and expansion. Closing the runtime invalidates generations,
cancels tasks, calls provider cancellation/close, and clears its cache.

## Provider and transport decision

`RemoteFileProvider` exposes initial-directory resolution, immediate-child listing,
cancellation, and close. Phase 4A builds a deterministic
`InMemoryRemoteFileProvider` and an honest `UnavailableRemoteFileProvider` used by
shipping composition while the production gate is blocked.

The stock `/usr/bin/sftp` path is rejected: it has no structured listing mode and
human `ls` output cannot safely frame newline/control/non-UTF-8 filenames. A custom
SFTP implementation is prohibited. Existing standalone Swift SSH libraries do not
preserve system OpenSSH config/agent/Keychain/known-host semantics and require a
separate dependency/distribution decision.

The eventual safe transport is a reviewed packet adapter over binary pipes from:

```text
/usr/bin/ssh -T -s [-i identity] -p port user@host sftp
/usr/bin/ssh -T -s alias sftp
```

ADR 0007 defines its handshake, `REALPATH`/`OPENDIR`/`READDIR`/`CLOSE`, prompt
channel, bounds, cancellation, timeout, and process-reaping gate. No implementation
step below may substitute textual parsing or a fake Relay listing.

## Path, entry, navigation, and cache policies

- Paths are absolute raw-byte component lists; identity never depends on lossy
  Unicode conversion, URL normalization, localized comparison, or display text.
- Safe display escapes invalid/control bytes while preserving raw identity.
- Exact text copy is enabled only for a lossless Unicode representation.
- Entries preserve optional metadata and completeness; absent data is not guessed.
- Ordering groups kind, then uses raw name bytes and full path as stable ties.
- Current directory changes only after a successful target listing.
- Open pushes history and clears Forward; Back/Forward are reciprocal; Parent and
  breadcrumbs use the same transaction; Refresh changes no history.
- Refresh keeps selection only if the exact raw path survives.
- Newer request generations win; cancelled/stale completions are ignored.
- Cache bounds are 32 directories and 20,000 total entries; one response is capped
  at 10,000 entries and 32 MiB.
- Only requested immediate children load. No prefetch, recursive traversal,
  symlink recursion, polling, or descendant size calculation is permitted.
- At most two provider requests run per workspace and one per directory.

## UI and interaction policy

Keep `NavigationSplitView`. Resize the sidebar within 240...420 points, preserving
terminal dominance. Keep Saved Sessions compact and place Remote Workspace for the
selected runtime below it.

Local sessions show an explicit no-workspace explanation. SSH sessions show
availability, Back/Forward/Parent/Refresh, structured breadcrumbs, and a native
single-selection listing with lazy directory disclosures. Single click/arrows
select; double-click and `Command-Down` open a directory; `Command-Up` opens the
parent. Return remains reserved for future Finder-style Rename and does nothing in
the read-only listing. File rows have no open/edit action.

The selected entry/current directory expose Copy Path, Copy Name, Copy Parent, and
Copy Shell-Quoted Path in focused commands/context menus. All paths go through one
availability policy and a pasteboard protocol. No copy action sends Return or
creates a remote-object clipboard payload.

Loading, refreshing, empty, failed, cancelled, unavailable, disconnected, and
transport-blocked states remain explicit. Child errors stay scoped to the child.
Retry is available when meaningful. Accessibility names include entry kind and
state; breadcrumbs identify their destinations; focus restoration follows the
canonical contract.

## Exact file map

### Canonical contracts, design, and evidence

- Modify `AGENTS.md`.
- Modify `README.md`.
- Modify `PRODUCT.md`.
- Modify `ARCHITECTURE.md`.
- Modify `INTERACTIONS.md`.
- Modify `PERFORMANCE.md`.
- Modify `SECURITY.md`.
- Modify `TESTING.md`.
- Modify `PLANS.md`.
- Create `docs/design-docs/remote-workspace.md`.
- Modify `docs/design-docs/index.md`.
- Modify `docs/design-docs/remote-files-ux.md`.
- Modify `docs/design-docs/session-tabs-ux.md`.
- Modify `docs/design-docs/ssh-connection-lifecycle.md`.
- Modify `docs/design-docs/macos-app-behavior.md`.
- Modify `docs/design-docs/v0.1-mvp.md`.
- Create `docs/decisions/0006-session-centric-runtime-architecture.md`.
- Create `docs/decisions/0007-remote-file-provider-transport.md`.
- Create `docs/checklists/remote-workspace-acceptance.md`.
- Modify `docs/checklists/interaction-parity.md`.
- Create `docs/audits/0006-phase-4a-remote-workspace-evidence.md`.
- Modify `scripts/verify.sh` when required-file, coverage, or source-policy gates
  need the new module/docs.

### Package and remote domain

- Modify `Package.swift`: add `XMtermRemote`, `XMtermRemoteTests`, and the app
  dependency; add no external package.
- Create `Sources/XMtermRemote/Domain/RemotePath.swift`.
- Create `Sources/XMtermRemote/Domain/RemoteFileEntry.swift`.
- Create `Sources/XMtermRemote/Domain/RemoteDirectoryListing.swift`.
- Create `Sources/XMtermRemote/Domain/RemoteFileError.swift`.
- Create `Sources/XMtermRemote/Domain/RemoteUnicodeSafety.swift`.

### Provider boundary and deterministic providers

- Create `Sources/XMtermRemote/Providers/RemoteFileProvider.swift`.
- Create `Sources/XMtermRemote/Providers/InMemoryRemoteFileProvider.swift`.
- Create `Sources/XMtermRemote/Providers/UnavailableRemoteFileProvider.swift`.

### Cache and observable workspace

- Create `Sources/XMtermRemote/Workspace/RemoteDirectoryCache.swift`.
- Create `Sources/XMtermRemote/Workspace/RemoteWorkspaceState.swift`.
- Create `Sources/XMtermRemote/Workspace/RemoteWorkspace.swift`.

### Runtime composition and window registry

- Create `Sources/XMtermApp/Sessions/RuntimeSession.swift`.
- Modify `Sources/XMtermApp/TerminalWorkspaceStore.swift`.
- Modify `Sources/XMtermApp/SessionManager/SessionProfileLaunchCoordinator.swift`
  only if the public store result name must change after runtime migration.

### Native presentation and commands

- Create `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspacePresentation.swift`.
- Create `Sources/XMtermApp/RemoteWorkspace/RemotePathPasteboard.swift`.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceFocusedValues.swift`.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteEntryRow.swift`.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceSidebar.swift`.
- Modify `Sources/XMtermApp/RootView.swift`.
- Modify `Sources/XMtermApp/TerminalWorkspaceCommands.swift`.

Prefer leaving `SessionProfile.swift`, `SessionProfileStore.swift`,
`SessionLaunchSpecification.swift`, `TerminalTab.swift`, `TerminalTabsState.swift`,
`TerminalSession.swift`, `TerminalPane.swift`, and all PTY/C code unchanged. Touch
one only when a focused compilation/test proves the aggregate seam cannot be added
without it, and record the reason in this plan and audit first.

### Tests

- Create `Tests/XMtermRemoteTests/RemotePathTests.swift`.
- Create `Tests/XMtermRemoteTests/RemoteFileEntryTests.swift`.
- Create `Tests/XMtermRemoteTests/RemoteDirectoryCacheTests.swift`.
- Create `Tests/XMtermRemoteTests/RemoteFileProviderContractTests.swift`.
- Create `Tests/XMtermRemoteTests/RemoteWorkspaceTests.swift`.
- Create `Tests/XMtermRemoteTests/RemoteWorkspacePerformanceTests.swift`.
- Create `Tests/XMtermRemoteTests/TestSupport/ControllableRemoteFileProvider.swift`.
- Create `Tests/XMtermAppTests/RuntimeSessionTests.swift`.
- Create `Tests/XMtermAppTests/RemoteWorkspacePresentationTests.swift`.
- Create `Tests/XMtermAppTests/RemotePathPasteboardTests.swift`.
- Create `Tests/XMtermAppTests/RemoteWorkspaceSidebarPolicyTests.swift`.
- Modify `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`.
- Modify `Tests/XMtermAppTests/TerminalWorkspaceStoreProfileTests.swift`.
- Modify `Tests/XMtermAppTests/TerminalWorkspaceStoreSSHTests.swift`.
- Modify `Tests/XMtermAppTests/TerminalWorkspaceCommandTests.swift`.
- Modify `Tests/XMtermAppTests/SessionProfileLaunchCoordinatorTests.swift` only if
  the launch result name changes.

## Explicit deferrals

Do not implement remote mutation; upload/download; transfer queues/progress;
multiple/range selection; remote-object Copy/Cut/Paste; drag-and-drop; rename;
delete; create; duplicate; collision UI; recursive search; preview/Quick Look;
file open/editor launch; local cache mapping; save watching; auto-upload; conflict
resolution; terminal-directory following; `Open Terminal Here`; app-owned
multiplexing; reconnect; or settings redesign.

Do not parse human `ls` output, add a shell wrapper, implement SFTP packets, add an
unreviewed dependency, contact the Relay in automated tests, or label a mock fixture
as real remote state.

---

### Task 1: Freeze the Phase 4A contract and raw remote values

**Files:**
- Modify: `INTERACTIONS.md`
- Modify: `Package.swift`
- Create: `Sources/XMtermRemote/Domain/RemotePath.swift`
- Create: `Sources/XMtermRemote/Domain/RemoteFileEntry.swift`
- Create: `Sources/XMtermRemote/Domain/RemoteDirectoryListing.swift`
- Create: `Sources/XMtermRemote/Domain/RemoteFileError.swift`
- Create: `Sources/XMtermRemote/Domain/RemoteUnicodeSafety.swift`
- Test: `Tests/XMtermRemoteTests/RemotePathTests.swift`
- Test: `Tests/XMtermRemoteTests/RemoteFileEntryTests.swift`

- [x] **Step 1: Add the six stable requirement IDs and Phase 4A status note**

Resolve `SESS-006` so a workspace is independently recoverable but closes with its
owning runtime, never with another tab. Mark broader Phase 4B interactions Partial
or Deferred rather than rewriting them.

- [x] **Step 2: Add the empty `XMtermRemote` and test targets**

Depend only on `XMtermCore`; add no external package.

- [x] **Step 3: Write RED raw-path tests**

Cover root, parent, append, repeated-slash parsing, slash/NUL rejection, absolute
input, 32 KiB/4 KiB limits, ASCII, composed/decomposed Unicode, CJK, emoji, spaces,
apostrophes, leading hyphens, dotfiles, control bytes, invalid UTF-8, stable hash,
lossless string availability, escaped display, breadcrumbs, and shell quoting.

- [x] **Step 4: Run and confirm RED**

Run `swift test --filter RemotePathTests`.

Expected: compile failures for missing remote path types.

- [x] **Step 5: Implement minimal immutable path/component values**

Store `[UInt8]`/`Data` per component, validate at construction, and return new
values for parent/append. Do not mutate component arrays exposed to callers.

- [x] **Step 6: Write RED entry/listing/error tests**

Cover stable path identity, all kinds, partial metadata, hidden/executable behavior,
symlink target, deterministic kind/raw-byte/path ordering, immutable listing, and
bounded user-facing error copy.

- [x] **Step 7: Implement minimal values and confirm GREEN**

Run:

```bash
swift test --filter RemotePathTests
swift test --filter RemoteFileEntryTests
```

### Task 2: Define the provider contract and deterministic implementations

**Files:**
- Create: `Sources/XMtermRemote/Providers/RemoteFileProvider.swift`
- Create: `Sources/XMtermRemote/Providers/InMemoryRemoteFileProvider.swift`
- Create: `Sources/XMtermRemote/Providers/UnavailableRemoteFileProvider.swift`
- Create: `Tests/XMtermRemoteTests/RemoteFileProviderContractTests.swift`

- [x] **Step 1: Write RED provider-contract tests**

Cover provider-resolved initial directory, immediate-child listings, explicit empty
listing, all typed failures, attempt recording without sensitive values, independent
provider instances, configurable latency, cancellation, close rejecting new work,
and 10,000-entry/32 MiB/path/component limits.

- [x] **Step 2: Run and confirm RED**

Run `swift test --filter RemoteFileProviderContractTests`.

- [x] **Step 3: Implement the sendable protocol and in-memory actor**

The in-memory actor receives an immutable directory graph and optional deterministic
responses. It never recursively enumerates that graph. Cancellation and close are
observable and testable.

- [x] **Step 4: Implement the shipping unavailable provider**

It returns `.transportUnavailable` with bounded guidance referencing the separate
OpenSSH/SFTP adapter requirement. It must never return an empty/mock listing.

- [x] **Step 5: Confirm GREEN and inspect forbidden transport patterns**

Run:

```bash
swift test --filter RemoteFileProviderContractTests
rg -n 'sh -c|bash -c|zsh -c|StrictHostKeyChecking=no|ls -' Sources/XMtermRemote
```

Expected: tests pass and the source scan reports no match.

### Task 3: Build the bounded per-runtime directory cache

**Files:**
- Create: `Sources/XMtermRemote/Workspace/RemoteDirectoryCache.swift`
- Create: `Tests/XMtermRemoteTests/RemoteDirectoryCacheTests.swift`

- [x] **Step 1: Write RED cache tests**

Cover miss/hit, immutable replacement, LRU recency, 32-directory eviction,
20,000-total-entry eviction, oversized-single-list rejection, pinned current item,
targeted invalidation, cached selection restoration input, and clear-on-close.

- [x] **Step 2: Run and confirm RED**

Run `swift test --filter RemoteDirectoryCacheTests`.

- [x] **Step 3: Implement minimal value-oriented LRU**

Use explicit monotonically increasing access order, return new listing values, and
perform bound accounting before publication. Do not retain tasks or providers.

- [x] **Step 4: Confirm GREEN**

Run `swift test --filter RemoteDirectoryCacheTests`.

### Task 4: Implement the observable workspace state machine

**Files:**
- Create: `Sources/XMtermRemote/Workspace/RemoteWorkspaceState.swift`
- Create: `Sources/XMtermRemote/Workspace/RemoteWorkspace.swift`
- Create: `Sources/XMtermRemote/Workspace/RemoteWorkspaceRequest.swift`
- Create: `Sources/XMtermRemote/Workspace/RemoteWorkspaceProviderOperations.swift`
- Create: `Sources/XMtermRemote/Workspace/RemoteWorkspaceHistoryPolicy.swift`
- Create: `Sources/XMtermRemote/Workspace/RemoteWorkspaceDirectoryStatePolicy.swift`
- Create: `Tests/XMtermRemoteTests/TestSupport/ControllableRemoteFileProvider.swift`
- Create: `Tests/XMtermRemoteTests/RemoteWorkspaceTests.swift`
- Create: focused lifecycle, close-settlement, boundedness, and provider-contract
  suites under `Tests/XMtermRemoteTests/`

- [x] **Step 1: Write RED initial-state/load tests**

Cover idle, connecting, provider-resolved initial path, success-only current
publication, explicit empty, typed failure, Retry, cancellation, and close.

- [x] **Step 2: Write RED navigation/history tests**

Cover child open, Back, Forward, Parent, breadcrumb ancestor, Forward clearing,
failed target preserving current/history, root parent disabled, refresh no history,
selection retained/cleared by exact raw path, and cached revisit.

- [x] **Step 3: Write RED expansion/race/isolation tests**

Cover lazy expansion, collapse without recursive work, child-scoped failure/retry,
two-request workspace bound, one request per path, refresh/open races, stale result
rejection, cancellation latency, inactive continuation, and two completely
independent workspaces.

- [x] **Step 4: Run and confirm RED**

Run `swift test --filter RemoteWorkspaceTests`.

- [x] **Step 5: Implement the smallest `@MainActor @Observable` workspace**

Every load captures workspace identity plus generation; publication verifies both.
Keep explicit task references and use structured child tasks only. Provider calls
must not synchronously execute remote work on `MainActor`.

- [x] **Step 6: Confirm GREEN and repeat race tests**

Run `swift test --filter RemoteWorkspaceTests` at least three times, recording all
runs in the audit. No sleep-based nondeterminism is acceptable in state tests.

### Task 5: Migrate to the session-centric runtime aggregate

**Files:**
- Create: `Sources/XMtermApp/Sessions/RuntimeSession.swift`
- Modify: `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- Modify when required: `Sources/XMtermApp/SessionManager/SessionProfileLaunchCoordinator.swift`
- Create: `Tests/XMtermAppTests/RuntimeSessionTests.swift`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceStoreProfileTests.swift`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceStoreSSHTests.swift`
- Modify when required: `Tests/XMtermAppTests/SessionProfileLaunchCoordinatorTests.swift`

- [x] **Step 1: Write RED aggregate ownership tests**

Cover local runtime without workspace; SSH runtime with a fresh workspace;
immutable launch snapshot; same-profile independent workspaces; independent start;
workspace failure preserving terminal; profile edit/delete isolation; and aggregate
close waiting for both capabilities.

- [x] **Step 2: Run and confirm RED**

Run `swift test --filter RuntimeSessionTests`.

- [x] **Step 3: Implement `RuntimeSession` as a narrow composition owner**

Keep terminal lifecycle and workspace state separate. Reuse `TerminalSessionID`.
Inject a remote-workspace factory into the store so tests never require network.

- [x] **Step 4: Write RED store migration tests**

Assert selected runtime/session projections, terminal retention, SSH eligibility by
launch target, local no-provider behavior, same-profile isolation, switching state,
close cancellation, stale close-disposition guards, and full-window shutdown.

- [x] **Step 5: Replace the registry and update close orchestration**

Store `[TerminalTab.ID: RuntimeSession]`. Preserve a read-only `sessions` terminal
projection only while existing tests/callers migrate. Publish a prepared runtime
before independent start, as the current terminal path does.

- [x] **Step 6: Confirm focused and Phase 1–3 regressions GREEN**

Run:

```bash
swift test --filter RuntimeSessionTests
swift test --filter TerminalWorkspaceStoreTests
swift test --filter TerminalWorkspaceStoreProfileTests
swift test --filter TerminalWorkspaceStoreSSHTests
swift test --filter SessionProfileLaunchCoordinatorTests
```

### Task 6: Implement pure presentation, copy, and command policies

**Files:**
- Create: `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspacePresentation.swift`
- Create: `Sources/XMtermApp/RemoteWorkspace/RemotePathPasteboard.swift`
- Create: `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceFocusedValues.swift`
- Create: `Tests/XMtermAppTests/RemoteWorkspacePresentationTests.swift`
- Create: `Tests/XMtermAppTests/RemotePathPasteboardTests.swift`
- Create: `Tests/XMtermAppTests/RemoteWorkspaceSidebarPolicyTests.swift`

- [x] **Step 1: Write RED presentation-policy tests**

Cover local explanation, transport blocked, connecting/loading/refreshing/empty/
failed/cancelled labels, metadata formatting without guesses, accessibility names,
Back/Forward/Parent/Refresh/open/retry enablement, root behavior, safe display, and
file-open disabled.

- [x] **Step 2: Write RED pasteboard/quoting tests**

Use an injected fake pasteboard. Cover exact path, name, parent, root unavailable,
spaces, apostrophes, Unicode, leading hyphen, no trailing Return, no shell
execution, write failure, invalid UTF-8 disabling exact copy, and focus ownership.

- [x] **Step 3: Run and confirm RED**

Run:

```bash
swift test --filter RemoteWorkspacePresentationTests
swift test --filter RemotePathPasteboardTests
swift test --filter RemoteWorkspaceSidebarPolicyTests
```

- [x] **Step 4: Implement immutable presentation/command values and AppKit adapter**

One policy must drive buttons, menu items, context items, shortcuts, help text, and
accessibility availability. The AppKit adapter writes one plain-text item and does
not log its content.

- [x] **Step 5: Confirm GREEN**

Repeat all three focused suites.

### Task 7: Add the native Remote Workspace sidebar

**Files:**
- Create: `Sources/XMtermApp/RemoteWorkspace/RemoteEntryRow.swift`
- Create: `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceSidebar.swift`
- Modify: `Sources/XMtermApp/RootView.swift`
- Modify: `Sources/XMtermApp/TerminalWorkspaceCommands.swift`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceCommandTests.swift`

- [x] **Step 1: Write RED focused-command/store policy tests**

Cover selected-runtime routing, no stale previous-tab workspace, local disabled
commands, SSH Back/Forward/Parent/Refresh, `Command-Down`, `Command-Up`, focused
Copy, context-menu parity, and terminal command routing remaining unchanged.

- [x] **Step 2: Run and confirm RED**

Run `swift test --filter TerminalWorkspaceCommandTests`.

- [x] **Step 3: Implement the sidebar in small views**

Keep Saved Sessions compact. Observe only the selected runtime's workspace in the
remote subview. Use native `List`/selection/disclosure behavior, structured
breadcrumbs, 240...420 resizable width, explicit states, Retry, double-click open,
keyboard open/parent, context actions, and accessibility labels. Do not add a full
toolbar, settings redesign, transfer affordance, or file-open action.

- [x] **Step 4: Preserve terminal identity and focus**

Keep `TerminalPane` keyed by the existing terminal-session identity. Workspace
publication must not recreate or refocus it. Switching to a local tab clears the
remote presentation immediately.

- [x] **Step 5: Confirm focused GREEN and build**

Run:

```bash
swift test --filter TerminalWorkspaceCommandTests
swift build
```

### Task 8: Performance, security, regression, and packaged foundation evidence

**Files:**
- Create: `Tests/XMtermRemoteTests/RemoteWorkspacePerformanceTests.swift`
- Modify: `scripts/verify.sh`
- Update: `docs/checklists/remote-workspace-acceptance.md`
- Create: `docs/audits/0006-phase-4a-remote-workspace-evidence.md`

- [x] **Step 1: Write the 1,000-entry benchmark before optimization**

Measure fixture construction separately from ordering/cache/publication. Require
the model/order/publication segment below 100 ms on the verification host. Include
Unicode, CJK, emoji, spaces, apostrophes, leading hyphens, dotfiles, symlinks, and
partial metadata.

- [x] **Step 2: Run focused benchmark and inspect memory bounds**

Run `swift test --filter RemoteWorkspacePerformanceTests`. Record repeated timings,
cache counts, process memory delta where measurable, and whether debug/test overhead
is included.

- [x] **Step 3: Run focused coverage**

Run `swift test --enable-code-coverage` and report coverage for testable
`XMtermRemote` plus new app policy/state files separately from whole-source
coverage. The project target remains at least 80%; never conflate scoped and whole
source values.

- [x] **Step 4: Run security/source policy scans**

Inspect for secrets, logging, shell wrappers, command interpolation, host-key
bypass, `sftp ls` parsing, unbounded task creation, polling, recursive enumeration,
remote mutation verbs, and generated artifacts. Review every dependency license;
the expected new external dependency count is zero.

- [x] **Step 5: Run full verification from a clean build state**

Run:

```bash
swift package clean
./scripts/verify.sh
```

Record test/suite counts and wall times. A clean build and all Phase 1–3 regression
checks must pass.

- [x] **Step 6: Build/package and exercise the foundation manually**

Using deterministic developer injection only, verify local no-workspace state,
mock SSH loading/listing/empty/error/navigation/refresh/copy/tab-switch/close,
keyboard-only traversal, VoiceOver labels/roles, Light/Dark, Reduce Motion,
responsive 1,000-entry scrolling, idle CPU, no terminal recreation, and cancellation.
Label every fixture as simulated; never present it as Relay evidence.

### Task 9: Production-provider acceptance gate

**Files:**
- Modify only after an explicit dependency decision: `Package.swift`
- Create only after ADR 0007 acceptance: production adapter/process files under
  `Sources/XMtermRemote/Providers/OpenSSH/`
- Create only after ADR 0007 acceptance: focused adapter/integration fixtures under
  `Tests/XMtermRemoteTests/OpenSSH/`
- Modify: `docs/decisions/0007-remote-file-provider-transport.md`
- Modify: `docs/checklists/remote-workspace-acceptance.md`
- Modify: `docs/audits/0006-phase-4a-remote-workspace-evidence.md`

- [ ] **Blocked — select and review a mature packet adapter**

It must operate over system OpenSSH subsystem binary streams without replacing
OpenSSH config/auth/known-host semantics. Record source maintenance, security,
license, transitive dependencies, package size, signing, and distribution impact.

- [ ] **Blocked — implement through TDD only after the adapter gate passes**

Write malformed/oversized packet, raw-name, metadata, symlink, handshake, exact
argv, no-shell, cancellation, timeout, prompt-channel, process-reaping, and local
disposable `sftp-server` tests before production code.

- [ ] **Blocked — perform real Relay manual acceptance**

Launch the saved Relay Host snapshot, resolve the server-reported initial directory,
list real immediate children, navigate/refresh/copy, switch among local and two SSH
tabs, close one session, inspect child processes, and verify no credentials or path
payloads entered logs. Never automate Relay access in CI.

If these rows remain blocked, mark Phase 4A Partial and do not begin Phase 4B.

### Task 10: Canonical documentation, audit, and handoff

**Files:** all contract/design/evidence files listed in the file map

- [x] **Step 1: Update current architecture and product status honestly**

Document the aggregate, new target, path/entry/provider/cache/state seams, sidebar,
test counts, performance, security, and exact blocked transport boundary. Preserve
historical audit text.

- [x] **Step 2: Update roadmap phase split**

Rename current Phase 4A to Remote Workspace Foundation. Move mutation, transfers,
multi-selection, remote-object clipboard, drag/drop, collision, and integrity work
to Phase 4B. Keep terminal-directory synchronization and editor sync later.

- [x] **Step 3: Walk the interaction checklist**

Mark only direct evidence `[x]`; every other row says Partial, Deferred, Blocked,
Not applicable, Not performed, or Not encountered.

- [x] **Step 4: Run independent correctness and security review**

Review runtime cleanup, stale results, path identity, selection/history, cache
bounds, MainActor isolation, accessibility/focus, forbidden Phase 4B surface, and
all error/logging paths. Fix Critical/High findings test-first.

- [x] **Step 5: Run final verification and inspect the complete change set**

Run `./scripts/verify.sh` again, inspect every changed/new file, confirm no secret,
machine-specific fixture path, build artifact, or parent-repository change was
introduced, and record exact final results.

- [x] **Step 6: Publish the exact completion status and next task**

If Task 9 passes, mark Phase 4A complete and recommend exactly **Phase 4B — Remote
File Mutations and Transfers**. If Task 9 remains blocked, mark Phase 4A Partial and
recommend exactly **Complete Phase 4A production SFTP transport under ADR 0007**;
do not claim the broader phase is complete.
