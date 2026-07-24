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
and transfer coordinators. Every SSH workspace owns exactly one transfer
coordinator/engine; a local runtime owns none. Transfer actors create fresh
dedicated endpoint providers from complete execution snapshots in a maximum-two-
worker pool separate from the Phase 4A browsing provider. UI code sends typed
intents and displays presentation-only immutable snapshots; it never handles SFTP
packets, endpoint connection material, processes, file descriptors, or buffers.

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
- Browsing and endpoint-provider listing remain lazy/immediate-child-only. Recursion
  occurs only for an explicit operation and is bounded to 20,000 combined work/
  checkpoint/failure records per job, depth 128, and 1,024 pending directories.
- At most two active transfer jobs per runtime. A same-runtime job owns one channel;
  a cross-runtime drag-copy job owns one channel per endpoint, for at most four
  job-owned channels. Browsing uses its existing independent channel.
- Retention is exact: 1,000 nonterminal jobs, 500 most-recent terminal records,
  20,000 top-level request items per job, 20,000 combined discovered-work/
  checkpoint/failure records per job and 40,000 per engine, 40,000 cleanup entries
  per job and 80,000 per engine, and zero or one current collision per job.
- Variable-size execution identity is bounded with checked byte accounting at 16
  MiB per job and 64 MiB per engine. Local URLs are at most 32 KiB UTF-8,
  file/volume identifiers 4 KiB each, bookmarks 64 KiB, and one relative raw work
  path 32 KiB. Unique endpoint material reports its retained byte cost.
- Each job retains one current attempt UUID plus checked `UInt64` generation and
  constant-memory counters, never attempt UUID history. Generation exhaustion and
  every checked aggregate overflow fail `limitExceeded`.
- Current-item, source-summary, and destination-summary presentation strings are
  each bounded to 4 KiB of UTF-8. Presentation snapshots never contain trusted
  endpoint material, bookmarks, handles, credentials, or unrestricted raw paths.
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

### Focused Swift Testing command prefix

This Command Line Tools host requires the repository's `Testing.framework` search
and runtime paths. In the same `zsh` used for the focused commands, define this
task-specific array exactly once; an unflagged `swift test` failure with `no such
module 'Testing'` is an environment failure, not valid RED evidence:

```sh
xmterm_testing_flags=(
  -Xswiftc -warnings-as-errors
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)
```

No task includes a commit step because the user prohibited commit, merge, push,
tag, and staging operations.

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
- Modify `Sources/XMtermRemote/Transfer/RemoteFileTransferProvider.swift`: replace
  the incomplete worker boundary with `RemoteTransferEndpointProvider` (structured
  one-directory listing, lstat, read, exclusive staging write, mutations, cancel/
  close) and `RemoteTransferEndpointProviderFactory` accepting an immutable
  executable endpoint snapshot.
- Create `Sources/XMtermRemote/Transfer/RemoteTransferModels.swift`: complete
  request, endpoint, owner, local-file, requested-item, destination, policy, work-
  key, checkpoint, attempt, timestamps, state, progress, collision, and bounded
  presentation values.
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
- Modify `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPTransferProviderFactory.swift`:
  lazy independent worker creation from a trusted endpoint snapshot; production
  streaming workers remain Task 4 work.
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

## Task 3A — Complete execution, retry, checkpoint, and snapshot contracts

**Status:** complete.

**Acceptance:** `APP-007`, `APP-008`, `FILE-XFER-001`, `FILE-XFER-003`,
`SESS-011`. Preserve every completed Task 1 and Task 2 behavior and test.

**Files:**

- Create/modify `Sources/XMtermRemote/Transfer/RemoteTransferModels.swift`.
- Create/modify `Tests/XMtermRemoteTests/RemoteTransferModelsTests.swift`.
- Create/modify `Tests/XMtermRemoteTests/RemoteTransferBoundsTests.swift`.

**Interfaces produced:**

```swift
public enum RemoteTransferJobKind: Equatable, Sendable {
    case upload, download, remoteCopy, remoteMove, delete
    case createFile, createDirectory, rename
}

public struct RemoteTransferOwnerIdentity: Equatable, Hashable, Sendable {
    public let runtimeID: TerminalSessionID
    public let workspaceID: RemoteWorkspaceID
}

public enum RemoteTransferEndpointKind: Equatable, Sendable {
    case openSSH, simulated, packageTest
}

public struct RemoteTransferPresentationText: Equatable, Sendable {
    public static let maximumUTF8ByteCount = 4 * 1_024
    public let value: String
    public init(_ value: String) throws
}

package protocol RemoteTransferTrustedConnectionMaterial: Sendable {
    var retainedByteCount: Int { get }
}

public struct RemoteTransferEndpointSummary: Equatable, Sendable {
    public let displayName: RemoteTransferPresentationText
    public let kind: RemoteTransferEndpointKind
}

public struct RemoteTransferEndpointSnapshot: Equatable, Sendable {
    public let id: UUID
    public let owner: RemoteTransferOwnerIdentity
    public let summary: RemoteTransferEndpointSummary
    package let trustedConnectionMaterial: any RemoteTransferTrustedConnectionMaterial
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

public enum RemoteTransferLocalItemKind: Equatable, Sendable {
    case regularFile, directory
}

public struct RemoteTransferLocalFileIdentity: Equatable, Sendable {
    public let url: URL
    public let fileResourceIdentifier: Data
    public let volumeIdentifier: Data?
    public let kind: RemoteTransferLocalItemKind
    public let observedSize: UInt64?
    public let observedModificationNanoseconds: Int64?
    package let securityScopedBookmark: Data?
}

public enum RemoteTransferItemSource: Equatable, Sendable {
    case remote(endpoint: RemoteTransferEndpointSnapshot, path: RemotePath)
    case local(RemoteTransferLocalFileIdentity)
}

public struct RemoteTransferRequestedItem: Equatable, Sendable {
    public let logicalKey: RemoteTransferLogicalItemKey
    public let source: RemoteTransferItemSource
}

public enum RemoteTransferDestination: Equatable, Sendable {
    case remoteDirectory(endpoint: RemoteTransferEndpointSnapshot, path: RemotePath)
    case remotePath(endpoint: RemoteTransferEndpointSnapshot, path: RemotePath)
    case localDirectory(RemoteTransferLocalFileIdentity)
    case none
}

public enum RemoteTransferCollisionPolicy: Equatable, Sendable {
    case notApplicable, ask, replace, skip, keepBoth
}
public enum RemoteTransferMetadataPolicy: Equatable, Sendable {
    case notApplicable, preserveSupportedPermissions
}
public enum RemoteTransferSymlinkPolicy: Equatable, Sendable {
    case rejectTransfer, operateOnLinkIdentity
}
public enum RemoteTransferRecursivePolicy: Equatable, Sendable {
    case none
    case bounded(maximumItems: Int, maximumDepth: Int, maximumPendingDirectories: Int)
}
public enum RemoteTransferCrossRuntimePolicy: Equatable, Sendable {
    case sameRuntimeOnly
    case destinationOwnedCopy(sourceOwner: RemoteTransferOwnerIdentity)
}

public struct RemoteTransferRequest: Equatable, Sendable {
    public let id: UUID
    public let owner: RemoteTransferOwnerIdentity
    public let kind: RemoteTransferJobKind
    public let requestedItems: [RemoteTransferRequestedItem]
    public let destination: RemoteTransferDestination
    public let collisionPolicy: RemoteTransferCollisionPolicy
    public let metadataPolicy: RemoteTransferMetadataPolicy
    public let symlinkPolicy: RemoteTransferSymlinkPolicy
    public let recursivePolicy: RemoteTransferRecursivePolicy
    public let crossRuntimePolicy: RemoteTransferCrossRuntimePolicy
}

public struct RemoteTransferAttemptIdentity: Equatable, Hashable, Sendable {
    public let id: UUID
    public let generation: UInt64
}

public struct RemoteTransferWorkItemKey: Equatable, Hashable, Sendable {
    public let topLevelKey: RemoteTransferLogicalItemKey
    public let relativeRawComponents: [RemotePathComponent]
}

public enum RemoteTransferCheckpointDisposition: Equatable, Sendable {
    case discovered, committed, failed(RemoteFileError), unstarted
}

public struct RemoteTransferCheckpoint: Equatable, Sendable {
    public let key: RemoteTransferWorkItemKey
    public let disposition: RemoteTransferCheckpointDisposition
}

public enum RemoteTransferCleanupLocation: Equatable, Sendable {
    case remote(endpointID: UUID, path: RemotePath)
    case localDirectoryEntry(
        directory: RemoteTransferLocalFileIdentity,
        component: RemotePathComponent
    )
}

public struct RemoteTransferCleanupEntry: Equatable, Sendable {
    public let attempt: RemoteTransferAttemptIdentity
    public let workItemKey: RemoteTransferWorkItemKey
    public let location: RemoteTransferCleanupLocation
}

public struct RemoteTransferTimestamps: Equatable, Sendable {
    public let createdAtNanoseconds: UInt64
    public let startedAtNanoseconds: UInt64?
    public let updatedAtNanoseconds: UInt64
    public let settledAtNanoseconds: UInt64?
}
```

The Task 3A implementation must encode and test the design document's complete
operation matrix for upload, download, remote copy/move, delete, create file/
directory, and rename. No executor may infer create targets or whether a
destination is a directory from display text or operation naming. A job accepts
exactly one remote source endpoint snapshot; same-runtime copy/move/rename reuse it
as the destination endpoint, and destination-owned copy adds exactly one distinct
destination endpoint. Recursive maximum items may not be below the admitted
top-level item count.

`RemoteTransferJobSnapshot` is presentation-only and includes stable job ID,
current `RemoteTransferAttemptIdentity`, kind, bounded source/destination summaries,
state/running phase, byte/item counters, bounded current-item display, the current
collision summary, bounded safe failures, retry eligibility, and timestamps. It
must not expose endpoint material, security-scoped bookmarks, local resource IDs,
raw provider values, handles, credentials, or unrestricted raw paths.

- [x] **RED — request completeness and owner validation.** Add named tests proving
  every admitted kind carries executable immutable source/destination identity and
  policies, invalid owner/source/destination combinations fail before admission,
  logical UUIDs cannot require a UI lookup, and later profile/workspace mutation
  cannot alter a captured endpoint. Run:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteTransferModelsTests/(requestCarriesCompleteExecutionIdentity|rejectsOwnerAndPolicyMismatch|endpointSnapshotIsIndependentOfWorkspaceMutation|admittedRequestNeedsNoLookup)'
  ```

  Expected RED: compile failures for the missing contract types/fields or failing
  assertions against the incomplete request.

- [x] **GREEN — immutable model slice.** Implement only the values and validating
  initializers above. Endpoint equality uses its trusted snapshot `id`; the trusted
  material remains package-internal and non-encodable. Local identities require an
  absolute file URL plus nonempty resource ID. Re-run the same command and require
  all four tests to pass.

- [x] **RED — attempt/checkpoint/bounds.** Add tests for generation 1, fresh UUID
  plus checked generation on retry, `UInt64.max` exhaustion as `limitExceeded`,
  stale callback rejection after 10,000 generated attempts using full UUID+
  generation comparison, committed recursive descendant exclusion, incomplete-file
  restart from byte zero, and exact boundary/boundary+1 cases for every bound. Run:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteTransferBoundsTests|RemoteTransferModelsTests/(attempt|checkpoint|presentation)'
  ```

  Expected RED: missing work/checkpoint/attempt types and absent checked-limit
  behavior.

- [x] **GREEN — bounded model slice.** Retain one current attempt UUID/generation
  and constant-memory counters only. Add one bounded checkpoint map and a separate
  cleanup manifest. Enforce exactly 1,000 nonterminal jobs, 500 terminal records,
  20,000 top-level request items/job, 20,000 combined discovered-work/checkpoint/
  failure records/job, 40,000 combined such records/engine, 40,000 cleanup entries/
  job, 80,000 cleanup entries/engine, one collision/job, and 4 KiB UTF-8 for each
  current/source/destination presentation string. Enforce the 32 KiB local URL, 4
  KiB file/volume identifier, 64 KiB bookmark, 32 KiB relative raw work path, 16
  MiB/job retained-variable-data, and 64 MiB/engine retained-variable-data limits.
  Checkpoint and cleanup identities are unique. Attempt generation starts at one,
  rejects current-UUID reuse, and uses checked arithmetic. Use `limitExceeded` and
  never retain attempt UUID history. Re-run the bounds command and require all
  boundary tests to pass.

- [x] Run related Task 1/2 model/provider regressions with:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteSelectionStateTests|RemoteMutationTransferProviderContractTests|SFTPBinaryCodecTests|OpenSSHSFTPClientTests'
  ```

## Task 3B — Dedicated endpoint provider and workspace ownership

**Status:** complete.

**Acceptance:** `FILE-XFER-001`–`004`, `SESS-004`, `SESS-006`, `SESS-011`.

**Files:**

- Modify `Sources/XMtermRemote/Transfer/RemoteFileTransferProvider.swift`.
- Modify deterministic and OpenSSH provider factories only as required to accept
  endpoint snapshots; do not wire production transfer workers yet.
- Modify `Sources/XMtermRemote/Workspace/RemoteWorkspace.swift` and package
  composition seams.
- Modify `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceProductionComposition.swift`.
- Add focused provider-factory, workspace-ownership, and runtime-isolation tests.

**Interface produced:**

```swift
public protocol RemoteTransferEndpointProvider: RemoteFileMutationProvider {
    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing
    func openFileForReading(_ path: RemotePath) async throws -> any RemoteReadableFile
    func openFileForWriting(_ path: RemotePath) async throws -> any RemoteWritableFile
    func cancelAll() async
    func close() async
}

public protocol RemoteTransferEndpointProviderFactory: Sendable {
    func makeProvider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) async throws -> any RemoteTransferEndpointProvider
}
```

- [x] **RED — structured dedicated provider.** Add tests proving one-directory
  structured listing, lstat/read/exclusive staging write/mutations, a fresh provider
  and freshly handshaken capabilities for every factory call, snapshot-derived
  SSH/simulated composition, no browsing-
  provider borrowing, and fail-closed untrusted/unavailable material. Run:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteTransferEndpointProviderContractTests|RemoteTransferEndpointProviderFactoryTests'
  ```

  Expected RED: the old stream-only factory lacks endpoint input and dedicated
  structured listing/settlement.

- [x] **GREEN — provider boundary.** Introduce the exact protocols above and adapt
  the deterministic provider/factories. Reuse the reviewed Task 2 operations; do
  not duplicate the browsing state machine, add shell parsing, or implement Task 4
  streaming workers. Require the focused provider command to pass.

- [x] **RED — session ownership and close order.** Add tests proving every SSH
  workspace owns exactly one coordinator/engine, two workspaces are isolated, local
  runtime composition owns none, production and simulated composition are trusted
  and fail closed, close rejects new work, workspace close awaits coordinator job/
  provider settlement before browsing-provider settlement, and one runtime close
  cannot cancel another. Run:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteWorkspaceTransferOwnershipTests|RuntimeSessionTransferOwnershipTests|RemoteWorkspaceProductionCompositionTests'
  ```

  Expected RED: missing ownership/composition and settlement ordering.

- [x] **GREEN — ownership composition.** Create exactly one coordinator/engine in
  SSH workspace composition, inject deterministic workers, create none for local
  runtimes, and implement the required close ordering. `TerminalWorkspaceStore`,
  `RootView`, and SwiftUI views retain no engine. Require the ownership command and
  existing workspace/runtime close regressions to pass.

## Task 3C — Engine/coordinator migration, retry/conflict behavior, and closeout

**Status:** complete.

**Acceptance:** `APP-007`, `APP-008`, `FILE-XFER-001`, `FILE-XFER-003`,
`SESS-011`.

- [x] **RED — scheduling and publication.** Add tests for FIFO start, maximum two
  active jobs, monotonic attempt-local counters, transfer/verify phases, immediate
  state/conflict/error edges, 10 Hz ordinary coalescing, one failure not corrupting
  another, and two-engine isolation. Run:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteTransferEngineTests|RemoteTransferCoordinatorTests'
  ```

- [x] **GREEN — migrate the engine.** Store complete admitted requests and bounded
  checkpoints in the engine, publish presentation-only snapshots, use injected
  UUID/clock/endpoint-provider/staging factories, and pump without detached work,
  polling, per-chunk tasks, or production-only test hooks.

- [x] **RED — cancellation, conflict, retry, and capability downgrade.** Add named
  tests proving cancellation settles worker/provider/cleanup before `.cancelled`,
  stale callbacks compare UUID and generation, conflict owns no worker/channel/
  slot, resolution keeps job/current attempt/checkpoint and deterministic FIFO,
  retry excludes committed descendants, and atomic-replace capability loss after
  provider reacquisition re-enters conflict instead of silently using fallback.
  Run:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteTransferEngineTests/(cancellation|conflict|retry|stale|atomicReplaceDowngrade)'
  ```

- [x] **GREEN — settle state transitions.** Release and close all provider/channel
  state before publishing conflict or cancellation settlement. Revalidate the
  destination after reacquisition. Preserve the current attempt on collision
  resolution; create a checked new attempt only on explicit retry. Require the
  focused state-transition command to pass.

- [x] Run the combined Task 3 GREEN and repeat it three times:

  ```sh
  swift test "${xmterm_testing_flags[@]}" --filter 'RemoteTransferModelsTests|RemoteTransferBoundsTests|RemoteTransferEndpointProviderContractTests|RemoteTransferEndpointProviderFactoryTests|RemoteWorkspaceTransferOwnershipTests|RuntimeSessionTransferOwnershipTests|RemoteWorkspaceProductionCompositionTests|RemoteTransferEngineTests|RemoteTransferCoordinatorTests'
  ```

- [x] Run `./scripts/verify.sh`, then `git diff --check`. Perform independent
  architecture, concurrency, security, and code-quality review; repair every
  Critical/High finding and rerun its focused tests plus the full verifier.
- [x] Close Task 3 only after Tasks 3A, 3B, and 3C pass. Record exact test counts,
  remaining lower-severity risks, and changed-file manifest without committing,
  staging, merging, pushing, or tagging. Production worker wiring remains Task 4.

Task 3 closeout evidence:

- Task 3C focused tests passed 32/32.
- Targeted Task 3C gate passed 8/8.
- Runtime/workspace ownership gate passed 6/6.
- Transfer concurrency stress passed x5.
- The 10,000-retry stale-callback test passed with full UUID+generation identity.
- Combined Task 3 suites passed 89 tests x3.
- Independent architecture, concurrency, security, and code-quality reviews
  approved the repair with no unresolved Critical/High finding.
- File caps, build, and diff checks passed.
- The repair includes safe cleanup retry validation: cleanup retry may act only on
  exact current-attempt cleanup entries whose top-level keys belong to the request.
- The repair includes actor slot/clock race fixes: conflict/cancellation release
  active slots before publication; current-item progress is coalesced to 10 Hz;
  state, phase, conflict, and error edges publish immediately with monotonic
  timestamps.
- Medium Task 5 debt: `RemoteTransferItemFailure` must become descendant-capable
  before recursive/batch acceptance can close.

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
- [ ] Wire production workers through `RemoteTransferEndpointProviderFactory` from
  immutable endpoint snapshots. Do not change workspace ownership established in
  Task 3B or consult UI/workspace lookup state to execute an admitted request.
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
- [ ] When a worker/provider is reacquired after conflict or invalidation, recheck
  atomic-replace capability. A downgrade re-enters conflict and requires a new
  explicit non-atomic decision; it never silently selects the fallback.
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

## Task 6 — Phase 4B.6 multi-selection UI, Copy/Cut/Paste, and action policy

**Acceptance:** `APP-001`–`004`, `FILE-SEL-001`, `FILE-CLIP-001`,
`FILE-COPY-001`, `MAC-001`, `SESS-011`.

- [ ] Write RED presentation/interaction tests for exact multi-selection rendering,
  click, Command-click, Shift-click, Command-Shift-click, arrows, Shift-arrows,
  Command-A, Escape, context-click preservation, projection ordering, collapse/
  refresh reconciliation, selection counts, focus restoration, and batch targets.
- [ ] Replace the single-selection `List` binding with exact selection rendering
  plus explicit pointer/keyboard routing to the completed Task 1 domain model.
  Preserve projection order, focus, expansion, context-click, and terminal identity.
- [ ] Run the focused selection UI tests and existing Task 1 model/workspace
  regressions before beginning clipboard integration. Actual multi-selection UI is
  a Task 6 acceptance gate and must pass before Task 7 drag work begins.
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

**Entry gate:** Task 6 actual multi-selection UI, selection-preserving context
behavior, and batch action policy are GREEN. Drag acceptance cannot substitute for
or precede that UI integration.

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
- [ ] Stop before any real Relay mutation and present the exact acceptance command/
  action sequence, unique candidate directory, cleanup guard, and current local/
  packaged evidence for fresh user approval. Read-only connection validation may
  precede this gate; creation, mutation, transfer, rename, or deletion on Relay may
  not. Approval of this plan is not approval to mutate the real host later.
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
- [ ] Re-read this plan's global constraints, every Task 3A–9 acceptance item, and
  every row in the linked Phase 4B checklist line by line. Phase 4B may be marked
  COMPLETE only when each applicable item has direct evidence and no unresolved
  Critical/High issue. Otherwise report PARTIAL with the exact blocker. Do not cite
  an unlocated or external item count as the completion source.

## Plan self-review

- Spec coverage: all 20 design decisions and the repaired Task 3A–9 sequence map to
  tasks and acceptance IDs; Tasks 1/2 remain completed history.
- Type consistency: selection feeds the shared projection; complete requests and
  endpoint providers feed the engine; presentation-only snapshots feed app policy/
  UI; runtime close awaits the one workspace-owned coordinator before browsing.
- Scope: Phase 5/6 are explicitly excluded; no dependency or remote runtime is
  introduced.
- No placeholder implementation step remains. Exact request/attempt/work/checkpoint
  types, limits, states, focused commands, staging, conflict, retry, capability-
  downgrade, symlink, metadata, and cross-session policies are fixed.
- The no-commit user boundary overrides generic workflow commit steps.
- Task 3A, 3B, and 3C are complete; production workers are Task 4, actual
  multi-selection UI is Task 6, and drag acceptance begins only in Task 7.
