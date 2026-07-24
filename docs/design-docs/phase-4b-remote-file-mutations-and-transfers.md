# Phase 4B Remote File Mutations and Transfers

- **Status:** Approved behavior; Task 3 architecture-contract repair complete;
  Task 4 production streaming workers and mutations are next/in progress
- **Owner:** XMterm
- **Date:** 2026-07-18
- **Decision scope:** Finder-style selection, remote mutation, streaming transfers,
  queues, collisions, clipboard operations, drag-and-drop, and transfer lifecycle
- **Transport decision:**
  [`ADR 0008`](../decisions/0008-remote-file-mutation-and-transfer-transport.md)
- **Prior foundation:** [`remote-workspace.md`](remote-workspace.md) and
  [`production-sftp-transport.md`](production-sftp-transport.md)

## Goal and acceptance boundary

Phase 4B turns the Phase 4A read-only Remote Workspace into a safe native remote
file manager without coupling it to the terminal or beginning editor sync. It adds
Finder-style selection, structured mutations, bounded streaming upload/download,
recursive transfer, an observable transfer queue, collision decisions, a private
remote-entry clipboard, and Finder drag-and-drop.

The phase is governed by `APP-001` through `APP-008`, `FILE-SEL-001`,
`FILE-NAV-001`, `FILE-CLIP-001`, `FILE-DND-001`, `FILE-DND-002`,
`FILE-OPS-001` through `FILE-OPS-003`, `FILE-LIST-001`, `FILE-PERF-001`,
`FILE-WORKSPACE-001`, `FILE-NAV-002`, `FILE-CACHE-001`, `FILE-STATE-001`,
`FILE-COPY-001`, `FILE-META-001`, `FILE-XFER-001` through `FILE-XFER-004`,
`SESS-004`, `SESS-006`, `SESS-011`, `A11Y-001` through `A11Y-003`, and
`MAC-001`, `MAC-002`, and `MAC-006`.

The locked Phase 4B scope excludes terminal cwd synchronization, OSC 7, nested-SSH
retargeting, shell integration, Open Terminal Here, editor launch, download-on-open,
file watching, upload-on-save, and a permanent editor working-copy cache. Those
remain Phase 5 or Phase 6 work. Quick Look preview and unrelated listing polish are
not prerequisites for the mutation-and-transfer acceptance gate.

The broad existing requirements are scoped explicitly for this phase:

| Requirement | Included in Phase 4B | Deferred without weakening the canonical requirement |
|---|---|---|
| `FILE-NAV-001` | directory open/expand, Return rename, Command-Down for directories, Command-Up, existing breadcrumbs/path copy | file open is Phase 6; editable direct path entry is later listing polish |
| `FILE-OPS-001` | Download, Upload Here, Copy, Cut, Paste, Move, Rename, Duplicate, Delete, New File, New Folder, Refresh, exact Copy Remote Path actions | Open/Open With are Phase 6; Open Terminal Here is Phase 5; Copy SSH/SCP Reference and Show Hidden Files are later listing polish |
| `FILE-LIST-001` | existing metadata/kind display and deterministic loaded ordering | user sorting and hidden-file toggle are later listing polish |

Duplicate is same-parent streaming copy with Keep Both naming. This table scopes
Phase 4B evidence; it does not mark the deferred portions complete.

## Considered architectures

### 1. Expand `RemoteWorkspace` into a monolithic file manager

This would put selection, navigation, packet operations, queue execution, local
filesystem I/O, collision prompts, and transfer state in one main-actor object. It
would minimize initial routing work but mix presentation state with long-running
I/O and make a large transfer more likely to interfere with navigation.

### 2. Add a global transfer manager

A window- or application-owned manager could coordinate cross-session transfers,
but it would make session closure and identity ambiguous. Two tabs from one profile
could accidentally share queue, cancellation, or error state. This violates
`SESS-011` and ADR 0006.

### 3. Use per-runtime workspace coordinators and split transports

This is the selected architecture. `RemoteWorkspace` remains the session-owned
remote-file capability and owns narrow selection, operation, and transfer
coordinators. Coordinators delegate I/O to actors and publish immutable snapshots;
they do not encode SFTP packets. Browsing keeps its Phase 4A provider/channel.
Transfer jobs use a separate bounded channel pool created from the same immutable
launch snapshot. Terminal, browsing, mutation, and transfer failures stay isolated.

## Ownership and component structure

```text
RuntimeSession
├── TerminalSession
└── RemoteWorkspace
    ├── browsingProvider: RemoteFileProvider
    ├── selection: RemoteSelectionState
    ├── operations: RemoteFileOperationCoordinator
    └── transfers: RemoteTransferCoordinator (exactly one for an SSH workspace)
        └── RemoteTransferEngine actor
            ├── RemoteTransferEndpointProvider workers
            ├── LocalTransferStaging
            └── RemoteTransferChannelPool (maximum 2 jobs / 4 endpoint channels)
```

Every object above is created for one launched runtime from its immutable launch
snapshot. Nothing is keyed by profile name or display text. Every SSH
`RemoteWorkspace` owns exactly one coordinator/engine composition. Local runtimes
create no Remote Workspace and no remote transfer coordinator. Production and
simulated compositions must supply trusted endpoint snapshots and factories or fail
closed. `TerminalWorkspaceStore` remains a registry and close coordinator; it does
not own operation or queue internals. `RootView` and SwiftUI rows display
presentation snapshots and send typed intents only. Task 3 establishes this
ownership with deterministic workers; Task 4 wires production streaming workers.

`RemoteWorkspace.close()` rejects new actions, awaits its one transfer coordinator
while that coordinator cancels and settles every owned job and closes every
job-owned provider, and only then settles the browsing provider and clears
workspace state. The browsing provider is never borrowed by a transfer worker.
Another runtime is never addressed by this path.

## 1. Selection ownership

`RemoteSelectionState` is an immutable value owned by `RemoteWorkspace`. It stores:

- an ordered selection of exact `RemotePath` values;
- a membership set derived from those values;
- an optional range anchor;
- an optional keyboard-focused path.

The ordered rows in `RemoteWorkspaceVisibleEntryProjection` remain the single
authoritative visible ordering. Selection receives a projection snapshot and never
performs provider I/O. Views do not maintain a second selection model.

## 2. Multi- and range-selection semantics

- Click replaces selection with the clicked visible entry and moves the anchor.
- Command-click toggles the clicked visible entry and moves the anchor to it when
  selected.
- Shift-click replaces selection with the inclusive visible range from the anchor;
  Command-Shift-click unions that range with the existing selection.
- Arrow keys move the keyboard focus through visible rows. Without Shift they
  select only the destination; with Shift they extend from the retained anchor.
- Command-A selects every loaded visible selectable row in the projection.
- Escape clears selection and anchor when the remote listing owns focus.
- Context-click on an unselected row selects only that row. Context-click on any
  selected row preserves the complete selection.
- Collapse removes hidden descendants and selects the collapsed ancestor once when
  it hid selected descendants. Refresh preserves only surviving exact raw paths.
  Cache eviction and history restoration use the same exact-identity repairs.

Batch actions consume the projection-ordered selection. Rename requires exactly one
entry. No display name is ever used for identity or reconciliation.

## 3. Executable endpoint and provider API

The Phase 4A browsing `RemoteFileProvider` and its channel remain stable and are
never loaned to transfer work. Phase 4B defines one dedicated transport-neutral
worker boundary:

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

The inherited `capabilities` value belongs to that provider's completed channel
handshake, so a resumed worker rechecks `supportsAtomicReplace` on the provider it
actually reacquired. `listDirectory` returns one structured immediate-child
listing. `openFileForWriting` keeps the Task 2 contract: it exclusively creates a
new staging file and never truncates or appends to an existing path. Provider code
never recurses; the bounded worker owns traversal. Each factory call creates a
fresh, dedicated provider/channel from its endpoint snapshot. The endpoint snapshot is an
execution-only immutable value containing a non-sensitive
`RemoteTransferEndpointSummary` and package-internal trusted opaque connection
material. That material is either a validated system-OpenSSH target captured from
the immutable runtime launch snapshot or deterministic simulated material. It is
not `Codable`, is never placed on the pasteboard, and is never projected to UI.

```swift
public enum RemoteTransferEndpointKind: Equatable, Sendable {
    case openSSH, simulated, packageTest
}

public struct RemoteTransferPresentationText: Equatable, Sendable {
    public static let maximumUTF8ByteCount = 4 * 1_024
    public let value: String             // validated by a throwing initializer
    public init(_ value: String) throws
}

package protocol RemoteTransferTrustedConnectionMaterial: Sendable {
    var retainedByteCount: Int { get }
}

public struct RemoteTransferEndpointSummary: Equatable, Sendable {
    public let displayName: RemoteTransferPresentationText
    public let kind: RemoteTransferEndpointKind // no credentials or host-key data
}

public struct RemoteTransferEndpointSnapshot: Equatable, Sendable {
    public let id: UUID
    public let owner: RemoteTransferOwnerIdentity
    public let summary: RemoteTransferEndpointSummary
    package let trustedConnectionMaterial: any RemoteTransferTrustedConnectionMaterial

    // Trusted snapshot identity is explicit because the material is opaque.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
```

The UI never receives trusted connection material, a packet type, handle byte
string, process, file descriptor, shell command, raw endpoint configuration, or
unrestricted raw path. Production composition can claim mutation/transfer
capability only for the reviewed OpenSSH material and factory. Unavailable or
untrusted composition fails closed.

## 4. Complete immutable transfer request contract

An admitted request is sufficient to execute and retry without consulting a
mutable workspace, profile, view, selection, or logical-ID lookup table. The exact
domain vocabulary is:

```swift
public enum RemoteTransferJobKind: Equatable, Sendable {
    case upload, download, remoteCopy, remoteMove, delete
    case createFile, createDirectory, rename
}

public struct RemoteTransferOwnerIdentity: Equatable, Hashable, Sendable {
    public let runtimeID: TerminalSessionID
    public let workspaceID: RemoteWorkspaceID
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
    public let id: UUID                  // stable visible job identity
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
```

The throwing initializer validates distinct logical keys, exact typed owner,
absolute file URLs with nonempty resource identifiers, trusted endpoint material,
all bounds, and this complete operation matrix before admission:

| Kind | Requested items | Destination | Required policy/ownership rules |
|---|---|---|---|
| `upload` | one or more local regular files/directories | `remoteDirectory` | destination endpoint owner equals request owner; same-runtime; symlinks rejected |
| `download` | one or more remote paths from one source endpoint snapshot | `localDirectory` | source endpoint owner equals request owner; same-runtime; symlinks rejected |
| `remoteCopy` | one or more remote paths from one source endpoint snapshot | `remoteDirectory` | same-runtime uses that same endpoint for source/destination; destination-owned copy uses exactly one declared-owner source endpoint and one request-owner destination endpoint |
| `remoteMove` | one or more remote paths from one source endpoint snapshot | `remoteDirectory` | source/destination are the same endpoint owned by request owner; same-runtime; link identity allowed |
| `delete` | one or more remote target paths | `none` | every target endpoint owner equals request owner; recursive policy says nonrecursive or confirmed bounded delete; link identity allowed |
| `createFile` / `createDirectory` | exactly one remote target path carried by `source` | `none` | target endpoint owner equals request owner; nonrecursive; same-runtime; no overwrite |
| `rename` | exactly one remote source path | exact `remotePath` | source and destination use the same endpoint owned by request owner; nonrecursive; same-runtime; link identity allowed |

The initializer rejects policies that are irrelevant or unsafe for the chosen row,
including recursive rename, cross-runtime move, non-directory local download
destinations, mixed source endpoint snapshots, a recursive maximum-item count below
the top-level item count, and Replace on delete. A logical item key is stable identity, never
the sole description of work. Create operations use the requested item's remote
path as the exact mutation target; they do not claim that source content exists.

Remote paste remains same-runtime only. Cross-runtime remote drag is a
`destinationOwnedCopy` whose destination owner admits the job after validating the
live source at drop commit and capturing the source endpoint and raw paths. The job
never retains or borrows the source workspace, browsing provider, or coordinator.
Source close after admission does not cancel it; destination close does. A source
closed before admission makes the drop stale. Cross-runtime cut/paste remains
rejected.

## 5. Work, checkpoint, attempt, and retention contracts

Stable requested-item identity and attempt identity are separate:

```swift
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

`RemoteTransferWorkItemKey` uses the top-level logical key plus at most 128 bounded
relative raw components. Components are exact identity, never display strings.
The engine retains one current `RemoteTransferAttemptIdentity` per job plus
constant-memory counters; it retains no UUID or generation history. Generation
starts at 1. Retry creates a fresh UUID and uses checked `generation + 1`;
generation zero, reuse of the current UUID, and `UInt64` exhaustion are rejected.

A bounded checkpoint map distinguishes top-level requested items, discovered
descendants, committed descendants, and failed/unstarted descendants. A separate
typed cleanup manifest records full attempt identity, work-item identity, and the
exact local or remote staging object; cleanup never derives a target from display
text. Checkpoint keys and cleanup identities are unique, and the manifest enforces
the same 16 MiB job byte budget before retaining them. Retry reconstructs or
rediscovers only necessary work, excludes every committed descendant, and restarts
incomplete files at byte zero. Cleanup retry may act only on exact current-attempt
cleanup entries whose top-level keys belong to the request; failed cleanup remains
bounded evidence for recovery and never authorizes derived fallback deletion. A
callback, completion, cleanup, collision decision, or publication is
accepted only when its complete attempt UUID and generation equal the current
identity. This rejects stale work after arbitrarily many retries without retaining
attempt history.

Retained-state limits are exact and checked before insertion:

- at most 1,000 nonterminal jobs per engine and 500 terminal records after all
  nonterminal jobs are preserved;
- at most 20,000 top-level requested items in one job;
- at most 20,000 combined discovered work items, checkpoints, and item-failure
  records in one job, and 40,000 combined across the engine;
- at most 40,000 cleanup entries in one job and 80,000 across the engine;
- exactly zero or one current collision per job;
- one current attempt UUID, one `UInt64` generation, and constant-memory counters
  per job, with no attempt UUID history;
- local file URLs are at most 32 KiB UTF-8, local file/volume identifiers are at
  most 4 KiB each, security-scoped bookmarks are at most 64 KiB, and one work-item
  relative raw path is at most 32 KiB in addition to its depth-128 limit;
- checked retained variable-size execution data is at most 16 MiB per job and 64
  MiB per engine. The budget includes unique endpoint summaries/material, raw
  paths, local identities/bookmarks, work/checkpoint identity, cleanup locations,
  safe failure text, and presentation strings; it does not rely on array count
  alone;
- each current-item, source-summary, and destination-summary presentation string is
  independently bounded to 4 KiB of UTF-8.

All aggregate record and byte counters use checked arithmetic. Crossing any limit
produces the typed `limitExceeded` result without partial insertion or integer
wraparound. The 20,000 recursive bound therefore cannot multiply by retry count or
by retaining parallel copies of discovered work, checkpoints, and failures.

## 6. Transfer queue ownership and conflict behavior

Each SSH `RemoteWorkspace` owns exactly one `RemoteTransferCoordinator` and one
engine. The coordinator publishes immutable presentation snapshots and routes
enqueue/cancel/retry/collision decisions. The engine actor owns admitted execution
requests, checkpoints, cleanup manifests, scheduling, and current attempts. It
runs at most two jobs per runtime; terminal and browsing work are outside this
limit.

An active job owns an executing worker task, provider/channel set, and active slot.
Entering `conflict` cancels/settles the worker, closes/releases every provider, and
frees the slot. A conflict owns no worker, provider/channel, or concurrency slot.
Resolution preserves job identity and the current attempt identity, retains its
bounded checkpoint, and requeues deterministically at its original FIFO position.
The resumed worker obtains fresh providers and revalidates the actual destination.

If Replace was confirmed with atomic-replace capability but a newly acquired
provider no longer advertises that capability, the job must re-enter `conflict`
and explain the non-atomic fallback. It may use that fallback only after a new
explicit decision; it never silently downgrades the guarantee.

## 7. Presentation snapshot contract

`RemoteTransferJobSnapshot` is a presentation projection, not an executable
request. It contains only stable job ID, current attempt identity, job kind,
bounded source/destination summaries, state, running phase, byte/item counters,
bounded current-item display, the one current collision summary, bounded safe
per-item failures, retry eligibility, and `RemoteTransferTimestamps`. It never
contains endpoint connection material, bookmarks, file resource identifiers,
unrestricted raw paths, provider references, handles, or credentials.

States are `queued`, `preparing`, `running`, `conflict`, `cancelling`, `cancelled`,
`completed`, and `failed`. A running snapshot carries `transferring` or `verifying`.
Byte and item counters are monotonic within an attempt. Engine-to-UI publication is
throttled to at most 10 Hz for ordinary current-item progress except for state,
phase, conflict, and error edges. Task 3 repaired actor slot and clock races so
conflict/cancellation release active slots before publication and snapshots keep
monotonic timestamps across coalesced progress.

## 8. Cancellation and retry model

Cancelling marks a job `cancelling`, cancels its owned task, and rejects subsequent
publication unless it bears the current full attempt identity. If request bytes may
be in flight, every affected provider/channel is invalidated and reaped before
cancellation settles. Cleanup removes only exact attempt-owned staging entries and
never removes a pre-existing destination. The job becomes `cancelled` only after
provider settlement and cleanup finish.

Explicit retry preserves the visible job and logical requested-item keys, creates
the next checked attempt identity, and uses the bounded checkpoint to exclude
committed descendants. Failed, cancelled, or unstarted work is revalidated and may
be rediscovered. Authentication, host-key, permission, invalid-path, and limit
failures are not automatically retried. Phase 4B does not claim byte-range resume.

## 9. Collision handling

No operation silently overwrites. `CollisionDecision` supports Replace, Skip, Keep
Both, and Cancel; batch UI can apply Replace/Skip/Keep Both to all remaining
collisions of that job. Apply-to-all is never persisted beyond the job.

Keep Both creates a deterministic destination-valid raw component by inserting
` copy`, then ` copy 2`, and so on before a lossless extension when possible, or by
appending the ASCII suffix to raw bytes otherwise. Every candidate is checked at
the actual destination because local and remote case sensitivity may differ.

Replace always publishes complete staged content. When the server advertises
`posix-rename@openssh.com`, the provider uses it. Otherwise XMterm uses this exact
non-atomic fallback:

1. Finish and verify the new staging item.
2. Generate an absent same-directory
   `.xmterm-backup-<attempt-id>-<item-id>` path.
3. Enter a bounded non-cancellable publication section and rename the current
   destination to the backup.
4. Rename the staging item to the destination.
5. If step 4 fails, restore backup to destination. A successful restore leaves the
   original destination intact and the item failed. A failed restore is a
   high-severity failure that retains both known paths for manual recovery.
6. If step 4 succeeds, delete the backup. Backup deletion failure reports a cleanup
   failure while retaining the complete new destination and backup; it never rolls
   back or deletes the published destination.
7. Honor cancellation requested during steps 3–6 only after finalize/rollback and
   cleanup reach a known state.

Backup and staging collisions fail before replacement. Tests cover every boundary,
including cancellation before and during the publication section. The UI labels
this fallback non-atomic before the user confirms Replace.

## 10. Recursive transfer strategy

Recursive work is created only by an explicit upload, download, copy, or confirmed
delete. A breadth-first iterative work queue discovers immediate children through
structured operations; it never creates one task per entry. Limits are 20,000
combined discovered-work/checkpoint/failure records, depth 128, and 1,024 pending
directories per job, within the separate 40,000 engine aggregate. Crossing a limit
fails before mutation of undiscovered items and reports the exact limit.

Discovery records deterministic parent-before-child order for creation/download
and child-before-parent order for directory removal. A committed descendant is
checkpointed by its `RemoteTransferWorkItemKey` and excluded from retry. Each active
job transfers one file at a time on one provider/channel; the runtime-level two-job
bound supplies concurrency. Symlinks are never traversed.

## 11. Temporary and local staging policy

Downloads use a `LocalTransferStaging` infrastructure actor. It opens the chosen
destination directory, creates
`.xmterm-partial-<attempt-id>-<item-id>` with mode `0600` and exclusive/no-follow
semantics, records the exact created component in the attempt cleanup manifest,
streams bytes, verifies size, applies supported mode bits, then publishes with
descriptor-relative rename. It refuses `.`/`..`,
absolute injection, separators, local symlink escapes, and unsafe destination
replacement.

Remote names that are not safe lossless local components use a deterministic
bijective `~HH` byte escape; literal `~` is escaped too. The UI shows the resulting
local name before transfer. Transfer staging is temporary and separate from the
future Phase 6 editor cache.

## 12. Atomicity guarantees

- A new local destination becomes visible only after a complete staging file is
  closed and renamed in its destination directory.
- A new remote destination is uploaded to the exact same-directory
  `.xmterm-partial-<attempt-id>-<item-id>` component recorded in the cleanup
  manifest, closed, mode-adjusted, size-verified, then renamed.
- Existing local content is never opened and truncated in place.
- Remote Replace is atomic only when advertised `posix-rename` support is used;
  otherwise the rollback sequence is explicitly non-atomic.
- Directory transfers are item-atomic, not transaction-atomic. Completed items
  remain completed after another item fails or the user cancels.

## 13. Remote mutation semantics

Rename validates one user-entered Unicode component, rejects empty, `.`, `..`,
slash, NUL, and components over 4 KiB, and never derives the source from display
text. A direct SFTP rename is used for same-runtime moves. Moving a directory into
itself or a descendant is rejected before I/O.

Delete uses one batch confirmation with count and exact parent/location. Files and
symlinks use structured remove; symlink targets are never followed. Empty
directories use rmdir. Non-empty directory deletion requires a second explicit
recursive-delete choice and runs as a bounded cancellable job.

New Folder and New File are included. Their names use the rename validation rules;
the server's umask supplies initial permissions. A new empty file is created
exclusively and is never an overwrite shortcut. Successful operations refresh only
affected loaded parent listings and preserve surviving exact selections.

## 14. Drag-and-drop semantics

Finder-to-Remote accepts security-scoped local file URLs where needed, validates
them off `MainActor`, and enqueues uploads to the highlighted directory or current
directory. Multiple top-level files/directories are one job. Local symbolic links
and packages/bundles are rejected with guidance in Phase 4B rather than silently
followed or recursively expanded.

Remote-to-Finder uses an AppKit `NSFilePromiseProvider` adapter. A promise starts a
download only after Finder supplies its destination, invokes its completion only
after final publication, and propagates cancellation/error. Remote directories are
fulfilled recursively. No fake local URL represents a remote raw path.

Remote-to-remote private drags within the same workspace move by default and copy
with Option. Across workspaces they copy through a bounded source-read/destination-
stage pipeline owned by the destination runtime; move is never implied across
runtimes. A directory and the current directory are valid targets; a file, self,
descendant, stale source, or unavailable capability shows a forbidden operation
before network work.

## 15. Pasteboard representation

The private versioned pasteboard payload contains an owning runtime ID, workspace
ID, immutable exact raw paths, copy-or-move intent, and creation timestamp. It is
encoded with a bounded schema and validated against the current visible/cached
source entries before paste. It is never exposed as plain binary text.

Command-C/X/V route only when Remote Workspace owns focus. Terminal and text-field
clipboard routing remains unchanged. Exact Copy Path/Name/Parent/Shell-Quoted Path
remains a separate single plain-text operation. Cross-runtime remote paste is
rejected honestly in Phase 4B; the separately required cross-runtime drag-copy
pipeline does not reinterpret clipboard content.

## 16. Session-close behavior during active transfers

A runtime reports queued, preparing, running, collision-waiting, and cancelling
jobs to the existing close/quit decision coordinator. Closing a live SSH runtime
with transfer work produces one aggregate confirmation that states the transfer
count and that partial staging will be cancelled and cleaned. The choices are
Cancel Transfers and Close, or Keep Session Open. Quit/window close similarly uses
one aggregate sheet rather than one prompt per job.

On confirmation, the runtime is hidden from new actions, all owned transfers settle,
the workspace/provider processes reap, and the terminal follows its existing close
policy. Closing another tab does not affect these jobs. In particular, a cross-
runtime drag copy is counted only by its destination runtime; closing its source
tab after enqueue leaves the destination-owned endpoint snapshot/channel and job
running. Closing the destination cancels both job-owned channels. App quit cancels
the destination job exactly once while settling all runtimes.

## 17. Error aggregation

Every item result retains exact internal identity, a safe bounded user-facing path,
stage, typed category, retry eligibility, and recovery guidance. A batch snapshot
shows aggregate counts and safe failures within the combined 20,000-record job and
40,000-record engine bounds.
Successes are not removed because another item fails. Errors never include raw
stderr, credentials, unescaped control bytes, or an environment dump.

## 18. SFTP protocol extension scope

ADR 0008 adds only the packet surface needed by Phase 4B: `OPEN`, `READ`, `WRITE`,
`LSTAT`, `SETSTAT`, `REMOVE`, `MKDIR`, `RMDIR`, `RENAME`, `EXTENDED` for advertised
`posix-rename@openssh.com`, plus `DATA` and `ATTRS` responses. Existing `CLOSE`,
`OPENDIR`, `READDIR`, `REALPATH`, `STATUS`, `HANDLE`, `NAME`, and version framing
remain.

Every request is bounded, serialized per channel, request-ID checked, and covered
by success/status/malformed/oversized/trailing-data tests. A timeout, cancellation
after send, unknown response, mismatch, or framing uncertainty invalidates that
channel. No shell command, SCP command, human SFTP command, READLINK/SYMLINK,
ownership change, or unrequired extension is added.

## 19. Performance bounds

- Maximum two active transfer jobs. A same-endpoint job uses one dedicated SFTP
  channel and a cross-runtime copy uses one per endpoint, for at most four
  job-owned channels per engine, all separate from browsing.
- 64 KiB file chunks; at most one read or write chunk in memory per active file.
- No whole-file `Data`, per-chunk task, per-file process, polling timer, or network/
  filesystem I/O on `MainActor`.
- A 1,000-job snapshot projection remains under the existing 100 ms local model
  budget on the verification host.
- A realistically large sparse/local fixture demonstrates bounded chunk memory;
  network throughput is reported separately from local model and disk behavior.
- Transfer snapshot publication is coalesced to 10 Hz except at state boundaries.

## 20. Security boundaries

Remote/local names and drag payloads are untrusted. All operations use structured
paths and direct argument arrays. System OpenSSH retains configuration,
authentication, cryptography, and known-host authority with `BatchMode=yes`; no
password, OTP, private-key material, environment, raw stderr, or path content is
logged. Temporary objects use user-only permissions and random attempt-bound names.

Local publication uses descriptor-relative no-follow operations to contain path
traversal and symlink races. Upload source inspection rejects symlinks and packages,
then revalidates file identity before opening. Remote recursive traversal never
follows symlinks. Delete/collision/replace dialogs show safe exact destinations and
require explicit action. No downloaded file is executed automatically.

## Metadata and symlink policy

Phase 4B preserves regular permission bits, including executable bits, for file and
directory transfers where SFTP attributes permit it. New items respect server umask.
Owner, group, ACLs, extended attributes, resource forks, and modification-time
preservation are not promised in Phase 4B and are reported as unsupported rather
than guessed.

Remote symlinks remain visible and may be renamed, moved, or deleted as links.
Upload/download/copy of a symlink and every recursive symlink traversal are rejected
in Phase 4B because the accepted protocol scope does not add `READLINK`/`SYMLINK`.
Local upload symlinks and packages are also rejected. This prevents cycles and
silent target following.

## UI and accessibility

The terminal remains dominant. Remote Workspace adds compact toolbar/context
actions and a transfer-status button/popover showing aggregate state; it does not
replace the terminal with a file-manager screen. Collision, rename, create, and
delete use native sheets/alerts. Menu bar, toolbar, context menu, and shortcuts
derive enablement from one `RemoteWorkspaceActionPolicy` extended with selection,
focus, capability, clipboard, and operation-conflict inputs.

Icon-only controls have accessibility labels/help. Selection count, transfer state,
progress, conflicts, and destructive warnings are not color-only. Keyboard paths
include Command-C/X/V/A, Shift-arrow, Return rename, Command-Delete, Command-Shift-N,
Command-Down, Command-Up, Escape, and existing focus scoping.

## Test and acceptance strategy

Each implementation slice follows RED, focused GREEN, related regression, then
review. Deterministic providers model progress, slow transfer, cancellation,
permission denial, quota/disk-full-like failure, collision, malformed transport,
and partial batch failure. Disposable `/usr/libexec/sftp-server` integration covers
the production codec without external credentials.

Final evidence includes debug and release warnings-as-errors builds, the full and
clean verifier, whitespace/security/forbidden-transport scans, interaction-parity
walkthrough, performance measurements, packaged-app Finder workflows, close/quit
lifecycle, and real Relay acceptance inside one dedicated uniquely named directory.
No acceptance action may touch unrelated remote data.

The implementation order is locked: Task 3A request/endpoint/snapshot/attempt/
checkpoint/bounds models; Task 3B dedicated provider plus SSH workspace ownership;
Task 3C engine/coordinator migration and closeout; Task 4 production workers and
mutations; Task 5 recursive/batch/collision execution; Task 6 actual multi-selection
UI plus clipboard/action policy; Task 7 drag-and-drop; Task 8 hardening; and Task 9
security and acceptance. Tasks 3A, 3B, and 3C are complete; Task 4 is the next
production implementation gate. Task 6 must pass before Task 7 drag acceptance.

## Self-review

- The product behavior is locked; the Task 3 contract repair is complete. Evidence:
  Task 3C focused tests passed 32/32; targeted Task 3C gate passed 8/8; ownership
  gate passed 6/6; concurrency stress passed x5; the 10,000-retry stale-callback
  test passed; combined Task 3 suites passed 89 tests x3; independent architecture,
  concurrency, security, and code-quality reviews approved with no unresolved
  Critical/High finding; file caps, build, and diff checks passed.
- Runtime/workspace ownership is consistent with ADR 0006 and `SESS-011`.
- The transport expansion is isolated in ADR 0008 and does not rewrite Phase 4A
  historical evidence.
- Cross-runtime remote clipboard/cut is explicitly unsupported; cross-runtime drag
  performs copy only. Metadata beyond permission bits and symlink transfer are
  explicitly unsupported rather than silently omitted.
- Phase 5 and Phase 6 boundaries remain intact.
- Known Medium debt for Task 5: `RemoteTransferItemFailure` must become
  descendant-capable before recursive/batch acceptance can close.
