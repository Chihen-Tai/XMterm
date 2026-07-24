# ADR 0008: Extend System OpenSSH SFTP v3 for Bounded Mutations and Transfers

- **Status:** Accepted; Task 3 contract repair in progress
- **Date:** 2026-07-18

## Context

ADR 0007 accepted a dependency-free, read-only SFTP v3 codec over a system OpenSSH
subsystem process. Phase 4B requires structured remote mutation and streaming file
transfer while preserving exact raw path identity, OpenSSH configuration and host
verification, bounded memory, cancellation, and per-runtime isolation.

The existing codec has no `OPEN`, `READ`, `WRITE`, mutation, attribute, or atomic-
replace operation. The browsing channel serializes one outstanding request, so a
large transfer on that channel would also starve navigation.

## Options considered

1. Run shell, SCP, or human `sftp` commands for each operation.
2. Adopt a second SSH/SFTP dependency.
3. Expand the in-tree bounded codec narrowly and use dedicated transfer channels.

## Decision

Select option 3. System `/usr/bin/ssh` remains the only SSH implementation and is
launched with the ADR 0007 noninteractive structured argument forms. No shell or
human output parser is introduced. No dependency is added.

Keep the Phase 4A browsing provider and channel separate. Each SSH
`RemoteWorkspace` owns exactly one `RemoteTransferCoordinator` and engine with at
most two active workers; a local runtime owns none. The workspace creates that
composition from the immutable runtime launch snapshot and awaits coordinator
settlement before settling its browsing provider during close. No global manager,
`RootView`, SwiftUI view, or `TerminalWorkspaceStore` owns operational queue state.
Task 3 establishes this ownership with deterministic workers; Task 4 wires the
production workers.

Each worker factory receives an execution-only immutable
`RemoteTransferEndpointSnapshot`. The snapshot carries a non-sensitive presentation
summary plus trusted opaque system-OpenSSH or simulated connection material; it is
never encoded or projected to UI. Each factory call creates a fresh dedicated
`RemoteTransferEndpointProvider`. That single provider contract supplies structured
one-directory listing, `lstat`, bounded reads, exclusive staging writes, the
allowlisted mutations below, and cancellation/close. Provider listing never
recurses. Its inherited `RemoteFileMutationProvider.capabilities` value comes from
that provider's completed channel handshake and is rechecked after reacquisition.
A worker never borrows another workspace, coordinator, browsing provider,
or channel. Closing or invalidating a worker therefore never closes the browsing
provider or terminal process.

Every admitted `RemoteTransferRequest` contains its stable job ID, exact
`RemoteTransferOwnerIdentity(runtimeID: TerminalSessionID, workspaceID: RemoteWorkspaceID)`,
`RemoteTransferJobKind`, immutable local/remote requested-item sources, executable
source/destination endpoint snapshots, exact raw paths, and explicit collision,
metadata, symlink, recursive, and cross-runtime policies. Logical item UUIDs remain
stable keys but are never the only description of work. A cross-runtime copy is
owned by the destination and captures exactly one source endpoint before admission;
one job never batches paths from multiple source endpoint snapshots.

The codec may add only:

- requests: `OPEN`, `READ`, `WRITE`, `LSTAT`, `SETSTAT`, `REMOVE`, `MKDIR`,
  `RMDIR`, `RENAME`, and `EXTENDED` for an advertised
  `posix-rename@openssh.com` operation;
- responses: `DATA` and `ATTRS`, plus the already accepted `STATUS` and `HANDLE`;
- open flags and the v3 attribute fields required for size and POSIX mode.

`READLINK`, `SYMLINK`, ownership changes, arbitrary extensions, remote shell copy,
and protocol versions other than 3 remain out of scope. Symlink transfer is rejected
honestly; rename/remove operate on link identity without following its target.

## Bounds and integrity

- Existing 1 MiB packet, 32 KiB path, 4 KiB component, 256-byte handle, and bounded
  diagnostic limits remain.
- Transfer chunks are exactly bounded to 64 KiB, including cross-runtime drag-copy
  streams with one immutable source endpoint snapshot/channel and one destination
  channel owned solely by the destination job.
- Requests are serialized per channel with exactly one outstanding request ID.
- A runtime has at most two active jobs. A same-runtime job owns one channel; a
  cross-runtime drag-copy job owns one channel per endpoint, so the bounded worker
  pool owns at most four transfer channels in addition to browsing.
- An engine retains at most 1,000 nonterminal jobs plus the 500 most-recent terminal
  records after preserving all nonterminal jobs.
- One job admits at most 20,000 top-level request items. Discovered work items,
  checkpoints, and failures share one combined 20,000-record job limit and one
  combined 40,000-record engine limit; retries do not multiply those records.
- Cleanup manifests are separately bounded to 40,000 entries per job and 80,000
  per engine. A job retains at most one current collision.
- Variable-size retained execution identity is checked at 16 MiB per job and 64
  MiB per engine. Local URLs are at most 32 KiB UTF-8, file/volume identifiers 4
  KiB each, security-scoped bookmarks 64 KiB, and one relative raw work path 32
  KiB; trusted endpoint material reports its retained byte cost.
- Recursive jobs are additionally bounded to depth 128 and 1,024 pending
  directories. All counters use checked arithmetic and fail `limitExceeded` before
  insertion or wraparound.
- A job retains only its current attempt UUID plus checked `UInt64` generation and
  constant-memory counters, never UUID history. Generation exhaustion is
  `limitExceeded`. Every stale callback comparison uses both UUID and generation.
- Current-item, source-summary, and destination-summary presentation strings are
  independently bounded to 4 KiB of UTF-8. UI snapshots contain summaries only,
  never endpoint material, bookmarks, unrestricted raw paths, or handles.
- Every upload item uses a uniquely named same-directory
  `.xmterm-partial-<attempt-id>-<item-id>` staging file recorded for cleanup, closes
  it, applies supported mode, verifies size, then publishes by rename.
- Download uses a user-only same-directory local staging file and descriptor-
  relative publication.
- Replace uses advertised `posix-rename` when available. Otherwise the coordinator
  uses the design's exact non-atomic destination-to-backup, stage-to-destination,
  restore-on-failure, cleanup sequence and reports that reduced guarantee.

Recursive checkpoints use a stable top-level logical key plus bounded relative raw
components. They distinguish discovered descendants, committed descendants,
failed/unstarted work, and attempt-owned staging cleanup. Retry excludes committed
descendants, revalidates remaining work, and restarts incomplete files at byte zero;
byte-range resume is not claimed.

Cancellation before send leaves a healthy channel usable. Cancellation, timeout,
EOF, malformed framing, unknown response, request-ID mismatch, or any uncertainty
after bytes may have entered the stream invalidates and reaps that channel. A job
does not become cancelled until its worker and owned staging cleanup settle.

A job in conflict owns no worker, endpoint provider/channel, or active slot.
Resolution preserves the visible job and current attempt, retains bounded
checkpoints, requeues deterministically, acquires fresh providers, and revalidates
the destination. If a reacquired provider has lost the atomic-replace capability
under which Replace was confirmed, the job returns to conflict. It must obtain a
new explicit decision before the documented non-atomic fallback and never silently
downgrades the guarantee.

## Security boundary

OpenSSH continues to own configuration, authentication, cryptography, agent/
Keychain use, and known-host policy. `BatchMode=yes` remains mandatory. XMterm does
not store or log credentials, environment data, raw stderr, packet streams, or
remote path contents. Remote paths are structured binary values and never shell
interpolation. Temporary objects are random, attempt-bound, user-only where local,
and cleanup targets only exact names created by that attempt.

## Consequences

- The custom SFTP surface grows, but remains an allowlisted protocol subset with
  explicit malformed-response and request-ID tests.
- Browsing remains responsive during large transfers at the cost of up to two
  additional lazy OpenSSH subsystem processes per runtime.
- A destination-owned cross-runtime copy may need one source and one destination
  channel per active job, so two workers own at most four endpoint channels in
  addition to browsing.
- Server-side copy is not assumed in SFTP v3. Copy streams through one worker;
  same-session move uses structured rename.
- Atomic Replace depends on advertised server support; the fallback is honest and
  rollback-oriented rather than silently destructive.
- Phase 5 terminal-directory synchronization and Phase 6 editor sync remain
  separate decisions.

## Acceptance gates

ADR 0008 is complete only after codec/provider tests, local disposable-server
integration, bounded-memory evidence, cancellation/reaping tests, independent
security review, packaged Finder drag/drop acceptance, and safe real Relay
acceptance pass with no unresolved Critical/High issue.
