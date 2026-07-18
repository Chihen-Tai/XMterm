# ADR 0008: Extend System OpenSSH SFTP v3 for Bounded Mutations and Transfers

- **Status:** Accepted for Phase 4B implementation
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

Keep the Phase 4A browsing provider and channel separate. Each RuntimeSession's
Remote Workspace owns one transfer coordinator with at most two active workers.
Each worker lazily creates one independent system-OpenSSH SFTP channel from the
same immutable launch snapshot and reuses it across the files in that job. Closing
or invalidating a worker never closes the browsing provider or terminal process.

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
- Recursive jobs are bounded to 20,000 items, depth 128, and 1,024 pending
  directories.
- Every upload item uses a uniquely named same-directory
  `.xmterm-partial-<attempt-id>-<item-id>` staging file recorded for cleanup, closes
  it, applies supported mode, verifies size, then publishes by rename.
- Download uses a user-only same-directory local staging file and descriptor-
  relative publication.
- Replace uses advertised `posix-rename` when available. Otherwise the coordinator
  uses the design's exact non-atomic destination-to-backup, stage-to-destination,
  restore-on-failure, cleanup sequence and reports that reduced guarantee.

Cancellation before send leaves a healthy channel usable. Cancellation, timeout,
EOF, malformed framing, unknown response, request-ID mismatch, or any uncertainty
after bytes may have entered the stream invalidates and reaps that channel. A job
does not become cancelled until its worker and owned staging cleanup settle.

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
