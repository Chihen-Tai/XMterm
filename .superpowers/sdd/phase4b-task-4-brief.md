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

