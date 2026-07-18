# Phase 4B Remote File Mutations and Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> `superpowers:subagent-driven-development` task-by-task. Every production behavior
> follows RED → GREEN → refactor, and every task receives spec/compliance and code-
> quality review before the next task. The user explicitly prohibited commits,
> merges, pushes, and tags for this work; preserve all changes in the current tree.

**Goal:** Turn the Phase 4A read-only Remote Workspace into a safe session-owned
native remote file manager with Finder-style selection, structured mutations,
streaming transfers, queues, collisions, clipboard operations, and drag-and-drop.

**Architecture:** Each `RuntimeSession` retains terminal and Remote Workspace as
sibling capabilities. The workspace owns immutable selection plus narrow operation
and transfer coordinators; their I/O actors use a dedicated, maximum-two-worker
SFTP channel pool separate from the Phase 4A browsing provider. UI code sends typed
intents and displays immutable snapshots; it never handles SFTP packets, processes,
file descriptors, or transfer buffers.

**Tech stack:** Swift 6, Swift concurrency/actors, SwiftUI/AppKit, Swift Testing,
Foundation/Darwin filesystem APIs, system OpenSSH, bounded SFTP v3, SwiftPM. No new
dependency.

## Global constraints

- Requirements: `APP-001`–`APP-008`, `FILE-SEL-001`, `FILE-NAV-001`,
  `FILE-CLIP-001`, `FILE-DND-001`, `FILE-DND-002`, `FILE-OPS-001`–`003`,
  `FILE-LIST-001`, `FILE-PERF-001`, `FILE-WORKSPACE-001`, `FILE-NAV-002`,
  `FILE-CACHE-001`, `FILE-STATE-001`, `FILE-COPY-001`, `FILE-META-001`,
  `FILE-XFER-001`–`004`, `SESS-004`, `SESS-006`, `SESS-011`, `A11Y-001`–`003`,
  `MAC-001`, `MAC-002`, `MAC-006`.
- Exact raw `RemotePath` values remain the only remote identity. Display text and
  local filenames are not operation identity.
- Per-runtime state only: two launches from one profile have independent selection,
  queues, workers, cancellation, failures, and lifecycle.
- System OpenSSH remains the SSH/authentication/host-key authority. No shell, SCP,
  human `sftp`/`ls` parsing, host-key bypass, credential storage, raw stderr/path
  logging, remote daemon, or new dependency.
- Browsing remains lazy/immediate-child-only. Recursion occurs only for an explicit
  operation and is bounded to 20,000 items, depth 128, and 1,024 pending directories.
- At most two active transfer jobs per runtime. A same-runtime job owns one channel;
  a cross-runtime drag-copy job owns one channel per endpoint, for at most four
  job-owned channels. Browsing uses its existing independent channel.
- Transfer chunks are 64 KiB. No whole-file buffering, per-chunk task, per-file
  process, unbounded queue, polling loop, or network/filesystem I/O on `MainActor`.
- Downloads and uploads stage and publish complete content. No silent overwrite.
- Symlink upload/download/copy and recursive following are rejected. Link rename,
  move, and delete act on the link itself. Packages/bundles are rejected on upload.
- Preserve POSIX permission bits including executable bits where supported. Owner,
  group, ACL, xattr, resource-fork, and mtime preservation are not promised.
- Cross-runtime remote paste/cut is rejected honestly. Cross-runtime remote drag
  copies through a bounded source-read/destination-stage pipeline and never deletes
  the source.
- Phase 5 cwd/OSC/nested-host work and Phase 6 editor/cache/watch/save-sync work are
  prohibited.
- Keep functions focused, replace collections/values immutably, validate every
  external input, and surface typed errors.
- Do not commit, merge, push, or tag.

## Baseline recovery evidence

- Working directory: `/Applications/codes/XMterm-starter`.
- Branch: `codex/phase-4a-hardening-review`.
- Starting HEAD: `eb5ebed` (`v0.4.0`, `Complete Phase 4A production SFTP remote
  workspace`).
- Starting status/diff/cached diff: clean.
- Untouched baseline `./scripts/verify.sh`: **471 tests / 59 suites**, exit 0,
  `XMterm verification: OK` on 2026-07-18.

## File structure

### Remote domain and selection

- Create `Sources/XMtermRemote/Selection/RemoteSelectionState.swift`: immutable
  ordered multi/range selection policy.
- Create `Tests/XMtermRemoteTests/RemoteSelectionStateTests.swift`: pointer,
  keyboard, repair, raw-identity, and session-isolation behavior.
- Modify `Sources/XMtermRemote/Workspace/RemoteWorkspace.swift`: replace the single
  selected path with the value policy while retaining compatibility projections
  only where needed during migration.
- Modify `Sources/XMtermRemote/Workspace/RemoteWorkspaceVisibleEntryProjection.swift`:
  expose stable ordered selectable paths without a second ordering algorithm.

### Operation and transfer contracts

- Create `Sources/XMtermRemote/Operations/RemoteFileCapabilities.swift`: explicit
  read/mutate/transfer capability value.
- Create `Sources/XMtermRemote/Operations/RemoteFileMutationProvider.swift`: typed
  stat/create/rename/remove/set-attributes boundary.
- Create `Sources/XMtermRemote/Transfer/RemoteFileTransferProvider.swift`: opaque
  read/write stream and provider-factory protocols.
- Create `Sources/XMtermRemote/Transfer/RemoteTransferModels.swift`: request, job,
  attempt, item, state, progress, collision, and error values.
- Create `Sources/XMtermRemote/Transfer/RemoteCollisionResolver.swift`: pure Keep
  Both naming and Apply-to-All policy.
- Create `Sources/XMtermRemote/Transfer/RemoteRecursivePlanner.swift`: bounded
  iterative discovery/order policy.
- Create `Sources/XMtermRemote/Transfer/RemoteTransferEngine.swift`: actor-owned
  FIFO scheduler, two-worker execution, cancellation, retry, progress, and cleanup.
- Create `Sources/XMtermRemote/Transfer/RemoteTransferCoordinator.swift`: session-
  owned observable snapshots and typed command routing.
- Create `Sources/XMtermRemote/Transfer/LocalTransferStaging.swift`: protocol plus
  descriptor-relative production local staging implementation.
- Extend `Sources/XMtermRemote/Providers/InMemoryRemoteFileProvider.swift`: immutable
  replacement-backed mutation/transfer simulation and deterministic faults.

### Production SFTP

- Modify `Sources/XMtermRemote/Providers/OpenSSH/SFTPProtocolTypes.swift`: allowlisted
  Phase 4B packet/flag/attribute/extension types and 64 KiB chunk bound.
- Modify `Sources/XMtermRemote/Providers/OpenSSH/SFTPBinaryCodec.swift`: bounded
  encode/decode for the ADR 0008 request/response set.
- Modify `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPClient.swift`: serialized
  typed request methods and extension-aware final rename.
- Modify `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPRemoteFileProvider.swift`:
  mutation/stream protocols, staging, metadata, and safe cleanup.
- Create `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPTransferProviderFactory.swift`:
  lazy independent worker creation from the immutable target.
- Preserve `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSubsystemProcess.swift` and
  `OpenSSHSFTPTarget.swift` launch/security boundaries unless a test proves a
  narrowly required lifecycle correction.

### Runtime and application UI

- Modify `Sources/XMtermApp/Sessions/RuntimeSession.swift`: include workspace
  transfer activity in close settlement without making it terminal-owned.
- Modify `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceProductionComposition.swift`:
  concrete production capability/factory composition and fail-closed behavior.
- Modify `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceFocusedValues.swift` and
  `RemoteWorkspacePresentation.swift`: shared focus/action/capability policy.
- Modify `Sources/XMtermApp/TerminalWorkspaceCommands.swift`: exact-owner focused
  Copy/Cut/Paste/Select All/Rename/Delete/New Folder actions.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteEntryPasteboard.swift`: bounded
  versioned private payload plus separate plain-text path behavior.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteTransferPresentation.swift`: pure
  job/collision/delete/close copy and accessibility projection.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteTransferPopover.swift`: compact
  native transfer queue/status surface.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteMutationDialogs.swift`: rename,
  create, delete, and collision sheets.
- Create `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceDragDrop.swift`: private
  drag payload, Finder URL validation, and file-promise adapter.
- Modify `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceSidebar.swift` and
  `RemoteEntryRow.swift`: multi-selection gestures, batch/context/toolbar actions,
  drops, and transfer status.
- Modify `Sources/XMtermApp/TerminalWorkspaceStore.swift` and application shutdown
  coordination only for active-transfer confirmation/settlement.

### Documentation and evidence

- Create `docs/checklists/remote-file-mutations-and-transfers-acceptance.md`.
- Create `docs/audits/0007-phase-4b-remote-file-mutations-and-transfers-evidence.md`.
- Update root contracts and relevant design docs only when implementation evidence
  changes status; preserve Phase 4A historical numbers.

---

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

## Task 2 — Phase 4B.2 transfer and mutation capability contracts plus codec

**Acceptance:** `FILE-OPS-001`, `FILE-META-001`, `FILE-XFER-002`,
`FILE-XFER-004`, `SESS-004`, `SESS-006`.

**Interfaces produced:**

```swift
public struct RemoteFileCapabilities: Equatable, Sendable {
    public let canList: Bool
    public let canMutate: Bool
    public let canTransfer: Bool
    public let supportsAtomicReplace: Bool
}

public protocol RemoteFileMutationProvider: Sendable {
    func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes
    func createFile(_ path: RemotePath) async throws
    func createDirectory(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath, replace: Bool) async throws
    func removeFile(_ path: RemotePath) async throws
    func removeDirectory(_ path: RemotePath) async throws
    func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws
}

public protocol RemoteReadableFile: Sendable {
    func read(maximumBytes: Int) async throws -> Data?
    func close() async throws
}

public protocol RemoteWritableFile: Sendable {
    func write(_ data: Data) async throws
    func close() async throws
}
```

- [ ] Write provider-contract tests for capabilities, zero-byte create, open/read
  EOF, write/close, lstat, mode, rename collision, remove file/link, empty/nonempty
  rmdir, cancellation, and close.
- [ ] Write codec RED tests for every ADR 0008 request/response, exact IDs, 64 KiB
  chunks, malformed/trailing/oversized data, status mapping, short packet, and
  advertised `posix-rename@openssh.com` detection.
- [ ] Run the focused provider/codec suites and capture missing-symbol RED.
- [ ] Add the protocol/domain values and deterministic in-memory implementation.
- [ ] Extend SFTP protocol types/codec minimally: `OPEN`, `READ`, `WRITE`, `LSTAT`,
  `SETSTAT`, `REMOVE`, `MKDIR`, `RMDIR`, `RENAME`, one allowlisted `EXTENDED`,
  `DATA`, `ATTRS`, and required open flags/attributes.
- [ ] Ensure all lengths/counts are checked before allocation; reject unknown flags,
  responses, extensions, IDs, and trailing bytes.
- [ ] Extend `OpenSSHSFTPClient` typed methods while preserving one outstanding
  request and fatal desynchronization policy.
- [ ] Run focused GREEN, disposable `sftp-server` codec integration, all existing
  production transport suites, and `./scripts/verify.sh`.
- [ ] Perform an independent protocol/security review before this slice closes.

## Task 3 — Phase 4B.3 transfer queue, progress, cancellation, and retry

**Acceptance:** `APP-007`, `APP-008`, `FILE-XFER-001`, `FILE-XFER-003`,
`SESS-011`.

**Interfaces produced:**

```swift
public enum RemoteTransferJobState: Equatable, Sendable {
    case queued, preparing, running, conflict
    case cancelling, cancelled, completed
    case failed(RemoteFileError)
}

public struct RemoteTransferJobSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let attemptID: UUID
    public let state: RemoteTransferJobState
    public let runningPhase: RemoteTransferRunningPhase?
    public let bytesCompleted: UInt64
    public let bytesTotal: UInt64?
    public let itemsCompleted: Int
    public let itemsTotal: Int?
    public let itemFailures: [RemoteTransferItemFailure]
}
```

- [ ] Write RED tests for FIFO start order, maximum two active jobs, 1,000-job
  model capacity, 500 terminal-state transfer-record retention, monotonic
  bytes/items, transferring/verifying phases, conflict and state transitions,
  one failure not corrupting another, collision suspension, cancellation settlement,
  retry attempt identity, committed-item exclusion, and two-engine isolation.
- [ ] Add `RemoteTransferModels`, a pure collision resolver, engine actor, and
  main-actor coordinator. Use injected UUID/clock/provider/staging factories for
  deterministic tests without production-only test hooks.
- [ ] Implement queue pumping without detached work, polling, or per-chunk tasks.
  Coalesce progress publication to 10 Hz but publish state/collision/error edges
  immediately.
- [ ] Make cancellation await worker invalidation and staging cleanup before
  `.cancelled`; reject stale attempt completion.
- [ ] Make `conflict` release its worker/channel set and active slot; resolution
  requeues the same job/attempt in original FIFO order and revalidates the
  destination before publication.
- [ ] Make explicit retry create a new attempt, rediscover failed/unstarted items,
  and never republish a prior attempt.
- [ ] Run focused RED/GREEN, concurrency stress/repetition, Thread Sanitizer when
  practical, and `./scripts/verify.sh`.
- [ ] Review actor isolation, retained task ownership, unchecked continuations,
  cancellation latency, and memory bounds.

## Task 4 — Phase 4B.4 streaming upload/download and remote mutations

**Acceptance:** `FILE-OPS-001`–`003`, `FILE-META-001`, `FILE-XFER-001`–`004`,
`APP-006`–`008`.

- [ ] Write local-staging RED tests for exclusive `0600` creation, no-follow
  destination handling, `.`/`..`/absolute/separator rejection, invalid-byte name
  encoding, existing-destination preservation, cancel/failure cleanup, atomic new
  publication, and collision races.
- [ ] Write streaming RED tests for small, zero-byte, 64 KiB boundary, multi-chunk,
  sparse/large fixture, short local read, unexpected remote EOF, write/status
  failure, disconnect, timeout, cancellation at each stage, and bounded in-flight
  data.
- [ ] Implement `LocalTransferStaging` with descriptor-relative Darwin APIs behind
  a protocol. Keep all local file I/O inside its actor.
- [ ] Implement per-item upload staging as
  `.xmterm-partial-<attempt-id>-<item-id>` in the exact remote parent, record the
  component in the attempt cleanup manifest, `OPEN` exclusive, stream 64 KiB
  writes, close, mode, size verify, and final rename.
- [ ] Implement download with 64 KiB reads, local staging, size verify, mode, and
  publication.
- [ ] Implement rename, create folder, create exclusive empty file, delete file/link,
  empty rmdir, and same-session move as typed coordinator jobs.
- [ ] Implement Replace with advertised `posix-rename`; otherwise use the design's
  exact per-item backup/finalize/restore/cleanup sequence. Add tests for backup-name
  collision, destination-to-backup failure, final rename failure, successful and
  failed rollback, backup cleanup failure, and cancellation before/during the
  bounded publication section.
- [ ] Refresh affected loaded parent directories only after confirmed mutations;
  reconcile exact surviving selection.
- [ ] Run focused GREEN, local `sftp-server` integration for every packet-backed
  operation, production regressions, and `./scripts/verify.sh`.
- [ ] Review partial-publication, cleanup ownership, executable-bit preservation,
  path traversal, symlink, race, and error-redaction behavior.

## Task 5 — Phase 4B.5 recursive transfer, batch operations, and collisions

**Acceptance:** `FILE-PERF-001`, `FILE-OPS-002`, `FILE-OPS-003`,
`FILE-XFER-001`–`004`, `FILE-META-001`.

- [ ] Write RED tests for iterative breadth-first discovery, parent/child operation
  order, 20,000-item/depth-128/pending-1,024 bounds, no task explosion, regular and
  empty directories, hidden/raw names, permission failure, directory/file
  collision, symlink rejection, cycle refusal, cancellation latency, and partial
  batch results.
- [ ] Implement `RemoteRecursivePlanner` with an explicit deque and immutable item
  plan. No recursion through the Swift call stack and no implicit traversal from
  selection/listing.
- [ ] Implement recursive upload/download/copy one file at a time per active job;
  keep the runtime-wide two-job concurrency limit.
- [ ] Implement recursive delete only after the stronger nonempty-directory
  confirmation; remove children before parents and never follow links.
- [ ] Implement Replace/Skip/Keep Both/Cancel and per-job Apply-to-All. Recheck each
  actual destination and case behavior immediately before publication.
- [ ] Retain exact per-item failures and completed items after partial failure or
  cancellation. Retry only failed/unstarted items.
- [ ] Run focused GREEN, 20,000-item boundary fixtures, related provider/engine
  regressions, and `./scripts/verify.sh`.
- [ ] Review traversal memory, symlink policy, delete safety, name generation,
  partial success, and batch error aggregation.

## Task 6 — Phase 4B.6 remote Copy/Cut/Paste and shared action policy

**Acceptance:** `APP-002`–`004`, `FILE-CLIP-001`, `FILE-COPY-001`, `MAC-001`,
`SESS-011`.

- [ ] Write RED tests for private payload copy one/many, cut, schema/version/size
  validation, exact raw paths, timestamp, stale/deleted source, same-runtime paste,
  cross-runtime rejection, target selection/current directory, and terminal/text-
  field clipboard noninterference.
- [ ] Implement `RemoteEntryPasteboard` with a private UTI, bounded versioned binary
  property-list schema, injected reader/writer seam, and separate Phase 4A plain-
  text exact-path adapter.
- [ ] Extend `RemoteWorkspaceActionPolicy` to derive all menu/context/toolbar/
  shortcut availability from focus, exact owner, selection count/kinds, target,
  capabilities, clipboard, transfer state, and conflicts.
- [ ] Route Command-C/X/V/A, Return, Command-Delete, Command-Shift-N, Command-Down,
  Command-Up, and Escape only for the focused exact workspace owner.
- [ ] Make copy enqueue streaming copy and cut paste enqueue rename/move. Do not
  erase the cut payload until all sources commit; retain failed items for retry.
- [ ] Run focused GREEN plus terminal shortcut/paste regressions and full verifier.
- [ ] Review focus restoration, stale-owner guards, pasteboard trust boundary,
  private/plain-text separation, and action-policy parity.

## Task 7 — Phase 4B.7 Finder and remote drag-and-drop

**Acceptance:** `APP-005`, `FILE-DND-001`, `FILE-DND-002`, `A11Y-003`,
`MAC-001`, `MAC-006`.

- [ ] Write pure-policy RED tests for drag selection preservation, same-runtime
  default move and Option copy, cross-runtime forced copy, directory/current-
  directory targets, self/descendant/file/stale rejection, and exact operation
  feedback.
- [ ] Write adapter RED tests for Finder regular files/directories/multiple URLs,
  symlink/package/unreadable rejection, security-scoped access settlement, file-
  promise lifecycle, promised directory download, cancellation, cleanup, and
  completion-after-publication.
- [ ] Implement a bounded private remote drag payload using exact runtime/workspace/
  path identity. Never publish a fake local URL for a remote item.
- [ ] Implement Finder-to-Remote URL validation outside `MainActor` and enqueue one
  upload job at drop commit only.
- [ ] Implement Remote-to-Finder with `NSFilePromiseProvider` in an AppKit adapter;
  start only after Finder supplies a destination and call completion only after
  final publication.
- [ ] Implement same-workspace move/default and Option-copy. Implement cross-runtime
  copy as one destination-owned job. At drop commit validate the live source and
  capture an immutable source endpoint snapshot; do not retain its runtime,
  workspace, browsing provider, or coordinator. The job owns a bounded source read
  channel and destination staging channel. Source close after enqueue leaves it
  running; source close before enqueue rejects the stale drop; destination close
  cancels both channels and leaves the source content intact. Show a forbidden drop
  for every unsupported target before network work.
- [ ] Run focused GREEN, packaged manual drag workflows, cleanup inspection, and
  `./scripts/verify.sh`.
- [ ] Review security-scoped URL lifetime, promised-file ownership, UI blocking,
  drag cancellation, and path disclosure.

## Task 8 — Phase 4B.8 native UX, accessibility, lifecycle, and performance

**Acceptance:** `APP-001`–`008`, `FILE-SEL-001`, `FILE-NAV-001`,
`FILE-OPS-001`–`003`, `FILE-XFER-001`, `A11Y-001`–`003`, `MAC-001`, `MAC-002`.

For `FILE-NAV-001`, `FILE-OPS-001`, and `FILE-LIST-001`, acceptance is limited to
the explicit included/deferred table in the Phase 4B design. This task must not
claim deferred file-open/editor, Open Terminal Here, direct path entry, sorting,
hidden toggle, or SSH/SCP-reference behavior.

- [ ] Write presentation/action RED tests for multi-selection counts, rename/create
  validation, delete parent/count/permanence copy, nonempty recursive warning,
  collision choices/apply-all, compact queue states, per-item failures, progress,
  cancel/retry, and accessibility text.
- [ ] Replace the single-selection `List` binding with exact selection rendering
  plus explicit click/keyboard gesture routing to the domain model. Preserve
  projection order, focus, expansion, context-click, and terminal identity.
- [ ] Add native rename/create/delete/collision sheets and a compact transfer
  popover/status control. Keep terminal detail dominant and avoid a permanent large
  transfer panel.
- [ ] Extend tab/window/quit decisions so active transfer count produces one
  aggregate Cancel Transfers and Close / Keep Session Open choice. Await transfer,
  workspace provider, and terminal settlement; preserve other runtimes.
- [ ] Add deterministic tests for close with queued/upload/download/collision/
  cancelling jobs, app quit with transfers, stale decisions, and two-runtime
  isolation.
- [ ] Add cross-runtime copy lifecycle tests: source close before drop rejects;
  source close after enqueue does not cancel; destination close cancels/cleans both
  owned channels; app quit counts/cancels the destination job exactly once.
- [ ] Add performance tests for 1,000 queue records under 100 ms, 64 KiB bounded
  chunk pipeline, large-file bounded memory proxy, no MainActor I/O, and browsing
  progress during transfer.
- [ ] Walk every affected row in `docs/checklists/interaction-parity.md`, then run
  focused GREEN and `./scripts/verify.sh`.
- [ ] Perform independent code, concurrency, accessibility, and performance review.

## Task 9 — Phase 4B.9 production security, Relay acceptance, and closeout

**Acceptance:** every ID and global constraint above; the Phase 4B definition of
done in the handoff.

- [ ] Extend `scripts/verify.sh` required-file checks for ADR 0008, this plan, the
  Phase 4B design, checklist, and audit.
- [ ] Run focused production transport/integration suites and record exact counts.
- [ ] Run fresh full gates:
  `swift build -Xswiftc -warnings-as-errors`,
  `swift build -c release -Xswiftc -warnings-as-errors`,
  `./scripts/verify.sh`, and `git diff --check`.
- [ ] Run source scans for shell/human-SFTP parsing, host-key bypass, credentials,
  raw path/stderr logging, unsafe temp permissions, unbounded buffering/tasks,
  force unwraps, polling, Phase 5/6 symbols, generated artifacts, and machine paths.
- [ ] Run an independent security review. Resolve every Critical/High finding and
  rerun the covering tests/review; document Medium/Low dispositions honestly.
- [ ] Stage and launch the debug app plus a release build. Complete pointer,
  keyboard, context-menu, focus, progress, cancellation, collision, VoiceOver/
  accessibility-tree, appearance, and drag/promise checklist rows that the host can
  prove. Record unavailable XCUITest/VoiceOver evidence as a limitation.
- [ ] Revisit ADR 0004 with packaged Finder promise evidence and record whether its
  sandbox/distribution decision remains Proposed or can be narrowed; do not claim
  notarization/distribution completion without its separate gates.
- [ ] On the Relay Host, create exactly one unique user-owned acceptance directory
  such as `~/XMterm-Phase4B-Acceptance-<UUID>`. Record the resolved exact path before
  mutation. Exercise small/large/directory upload/download, rename, move, create,
  copy/cut/paste, collision, progress, cancellation, retry, delete, two-runtime
  isolation, nested `ssh g207` boundary, and close/quit settlement only inside it.
- [ ] Before cleanup, verify the candidate path is the exact recorded acceptance
  root and is neither empty, `/`, `~`, nor a parent. Remove only that directory
  through structured XMterm/SFTP operations. Confirm unrelated user data was not
  touched.
- [ ] Run `swift package clean` and a fresh `./scripts/verify.sh` if practical.
- [ ] Update `ARCHITECTURE.md`, `INTERACTIONS.md`, `SECURITY.md`, `TESTING.md`,
  `PERFORMANCE.md`, `PLANS.md`, Phase 4B checklist/audit, and only then current
  product/README status. Preserve historical Phase 4A evidence.
- [ ] Re-read the 38-item handoff definition of done line by line. Phase 4B may be
  marked COMPLETE only when every item has direct evidence and no unresolved
  Critical/High issue. Otherwise report PARTIAL with the exact blocker.

## Plan self-review

- Spec coverage: all 20 design decisions and all nine requested Phase 4B slices map
  to a task and acceptance IDs.
- Type consistency: selection feeds the shared projection; transfer providers feed
  the engine; coordinator snapshots feed app policy/UI; runtime close awaits the
  coordinator through the workspace owner.
- Scope: Phase 5/6 are explicitly excluded; no dependency or remote runtime is
  introduced.
- No placeholder implementation step remains. Exact limits, states, commands,
  staging, collision, retry, symlink, metadata, and cross-session policies are
  fixed.
- The no-commit user boundary overrides generic workflow commit steps.
