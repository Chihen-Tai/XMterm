# Phase 4B Remote File Mutations and Transfers

- **Status:** Approved for implementation from the locked Phase 4B handoff
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
    └── transfers: RemoteTransferCoordinator
        └── RemoteTransferEngine actor
            ├── RemoteFileOperationService
            ├── LocalTransferStaging
            └── RemoteTransferChannelPool (maximum 2 jobs / 4 endpoint channels)
```

Every object above is created for one launched runtime from its immutable launch
snapshot. Nothing is keyed by profile name or display text. Local runtimes own none
of these remote capabilities. `TerminalWorkspaceStore` remains a registry and
close coordinator; it does not own operation or queue internals. `RootView` and
SwiftUI rows display snapshots and send typed intents only.

`RemoteWorkspace.close()` rejects new actions, asks the transfer coordinator to
cancel and settle every owned job, closes the operation/transfer channels, then
settles the browsing provider and clears workspace state. Another runtime is never
addressed by this path.

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

## 3. Remote operation API

The Phase 4A `RemoteFileProvider` listing protocol remains stable. Phase 4B adds
transport-neutral capability protocols used only by coordinators:

- `RemoteFileMutationProvider`: `lstat`, create empty file, create directory,
  rename, remove file/link, remove empty directory, and set supported attributes;
- `RemoteFileTransferProvider`: open/read/write/close opaque remote file streams;
- `RemoteTransferProviderFactory`: lazily creates one independent provider per
  active worker from the immutable SSH target.

The UI never receives a packet type, handle byte string, process, file descriptor,
or shell command. Production composition can claim write/transfer capability only
for the concrete reviewed OpenSSH provider. Unavailable and simulated providers
advertise typed capabilities rather than being inferred by type name or UI copy.

## 4. Transfer operation API

Typed top-level requests are:

- download remote entries to one chosen local directory;
- upload local URLs to one exact remote directory;
- copy remote entries to one exact directory in the same runtime;
- move remote entries to one exact directory in the same runtime;
- recursive delete after explicit confirmation;
- create, rename, and simple delete mutation requests.

Requests contain immutable source/destination identity, collision policy, metadata
policy, and the owning runtime/workspace IDs. A request is validated before it can
enter the queue. Remote paste remains same-runtime only. Cross-runtime remote drag
is supported as a bounded copy owned solely by the destination runtime. At drop
commit, the application validates the source workspace and captures an immutable
`RemoteTransferEndpointSnapshot` derived from its launch snapshot; it does not
retain or borrow the source workspace, browsing provider, or transfer coordinator.
The destination job opens its own source read channel and destination write channel,
streams 64 KiB chunks through XMterm, and never deletes the source. Closing the
source runtime after enqueue does not cancel or detach the destination job. Closing
the destination runtime cancels it. A source closed before drop commit is stale and
the drop is rejected. Cross-runtime cut/paste remains rejected clearly.

## 5. Transfer queue ownership

Each `RemoteWorkspace` owns one `RemoteTransferCoordinator` and one engine. The
coordinator publishes immutable jobs and routes enqueue/cancel/retry/collision
decisions. The engine actor schedules execution. The queue supports at most 1,000
top-level jobs and two active jobs per runtime. Terminal and browsing work are not
part of this limit.

An active job is one that owns an executing worker task and transfer channel set.
Entering `conflict` closes/releases that worker's channel set and frees its active
slot; conflict-waiting jobs therefore cannot monopolize both workers or deadlock the
queue. Resolving the collision requeues the same job/attempt in its original FIFO
position with the explicit decision attached, and the destination is revalidated
when a worker resumes it.

Transfer records in terminal states are retained up to a bounded 500 most-recent
jobs after all nonterminal jobs are preserved. The UI can clear completed records
without touching remote or local content.

## 6. Progress representation

`RemoteTransferJobSnapshot` contains job/attempt IDs, kind, sources, destination,
state, bytes completed, optional total bytes, completed/total item counts, current
item display, collision, per-item failures, retry eligibility, and timestamps.

States are `queued`, `preparing`, `running`, `conflict`, `cancelling`, `cancelled`,
`completed`, and `failed`. A running snapshot carries a phase of `transferring` or
`verifying`; collision decisions use `conflict`. `preparing` performs bounded
traversal and metadata discovery; totals become determinate when discovery
completes. Pause is not exposed. Byte and item counters are monotonic within an
attempt. Engine-to-UI publication is throttled to at most 10 Hz except for state,
phase, conflict, and error transitions.

## 7. Cancellation model

Cancelling marks a job `cancelling`, cancels its owned task, and prevents further
publication. If SFTP request bytes may be in flight, that worker channel is
invalidated and reaped before cancellation settles. The engine then removes only
staging objects carrying the exact job/attempt-generated name. It never removes a
pre-existing destination.

The job becomes `cancelled` only after channel settlement and cleanup finish. Local
and remote final publication is guarded by attempt ID and a final cancellation
check. Cancelling one job or runtime never cancels another runtime.

## 8. Retry model

Retry creates a new immutable attempt ID under the same visible job. Completed
items remain committed and are excluded. Failed, cancelled, or not-started items
are rediscovered and have source metadata and collisions revalidated. Every staging
name is attempt-specific, so an older completion cannot publish into a newer
attempt. Authentication, host-key, permission, invalid-path, and limit failures are
not automatically retried. Phase 4B exposes explicit user retry; it does not claim
resume and restarts an incomplete file from byte zero.

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
items, depth 128, and 1,024 pending directories per job. Crossing a limit fails
before mutation of undiscovered items and reports the exact limit.

Discovery records deterministic parent-before-child order for creation/download
and child-before-parent order for directory removal. Each active job transfers one
file at a time on one channel; the runtime-level two-job bound supplies
concurrency. Symlinks are never traversed.

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
shows aggregate counts and all item failures up to the 20,000-item job bound.
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

- Maximum two active transfer jobs and one SFTP channel per active job, separate
  from browsing.
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

## Self-review

- No placeholder or open product decision remains in the locked Phase 4B scope.
- Runtime/workspace ownership is consistent with ADR 0006 and `SESS-011`.
- The transport expansion is isolated in ADR 0008 and does not rewrite Phase 4A
  historical evidence.
- Cross-runtime remote clipboard/cut is explicitly unsupported; cross-runtime drag
  performs copy only. Metadata beyond permission bits and symlink transfer are
  explicitly unsupported rather than silently omitted.
- Phase 5 and Phase 6 boundaries remain intact.
