# Phase 4A Production SFTP Transport Implementation Plan

**Status:** COMPLETE — all production, package, real Relay, lifecycle, review, and
closeout gates passed on 2026-07-18.

> **For agentic workers:** Use test-driven development for every production slice,
> preserve unrelated worktree changes, and do not stage, commit, push, contact the
> Relay, or run packaged GUI acceptance unless the controller assigns that exact
> step.

**Goal:** Complete Phase 4A Task 9 with a production read-only SFTP provider over
system OpenSSH, real Relay evidence, and truthful Phase 4A closeout.

**Architecture:** Keep terminal PTY SSH unchanged. Each SSH runtime owns an
independent lazy `/usr/bin/ssh -T -o BatchMode=yes -s ... sftp` process and one
serialized bounded SFTP v3 codec/provider actor. Preserve raw paths and tear down
on desynchronization. Local sessions own no transport.

**Tech stack:** Swift 6, Foundation `Process`/`Pipe`, system OpenSSH,
`/usr/libexec/sftp-server` for local integration, Swift Testing, SwiftPM.

**Global constraints:** No dependency, shell, human-output parsing, host-key
weakening, credentials, polling, recursion, mutation, transfer, Phase 5/6 work,
staging, commit, or push. Applicable requirements: `SESS-004`, `SESS-006`,
`SESS-011`, `APP-007`, `APP-008`, `FILE-WORKSPACE-001`, `FILE-NAV-002`,
`FILE-CACHE-001`, `FILE-STATE-001`, `FILE-COPY-001`, `FILE-LIST-001`,
`FILE-META-001`, `FILE-PERF-001`, read-only `FILE-XFER-004`.

The implementation kept the plan's responsibilities but consolidated proposed
helper/test filenames where cohesion was better: byte-channel behavior lives in
`SFTPProcessChannel.swift`, typed transport failures in `OpenSSHSFTPFailure.swift`,
and disposable-server coverage in the client/provider/process suites.

## Starting evidence

- Branch: `codex/phase-4a-hardening-review`
- HEAD: `16ef945`
- Existing hardening worktree: 21 modified files and one untracked provider helper;
  preserve and integrate it.
- Baseline: `./scripts/verify.sh` passed 436 tests in 53 suites and printed
  `XMterm verification: OK` before Task 9 edits.

## Task 1: Freeze the approved decision and plan

**Files:**
- Create: `docs/design-docs/production-sftp-transport.md`
- Create: `docs/exec-plans/0009-phase-4a-production-sftp-transport.md`
- Modify: `docs/design-docs/index.md`
- Modify: `docs/decisions/0007-remote-file-provider-transport.md`
- Modify: `docs/exec-plans/0008-phase-4a-remote-workspace-foundation.md`

- [x] Record the independent process, exact argv, BatchMode, codec scope, bounds,
  raw identity, request serialization, fatal desynchronization, typed errors,
  runtime composition, real Relay gate, nested-SSH boundary, and scope deferrals.
- [x] Keep ADR 0007 Proposed until local, packaged, security, lifecycle, and real
  Relay gates pass; then make it Accepted or leave it Proposed/Blocked honestly.

## Task 2: TDD the bounded SFTP v3 codec

**Files:**
- Create: `Sources/XMtermRemote/Providers/OpenSSH/SFTPBinaryCodec.swift`
- Create: `Sources/XMtermRemote/Providers/OpenSSH/SFTPProtocolTypes.swift`
- Create: `Tests/XMtermRemoteTests/OpenSSH/SFTPBinaryCodecTests.swift`
- Create: `Tests/XMtermRemoteTests/OpenSSH/SFTPPacketTests.swift`

- [x] RED: test big-endian primitives, INIT, VERSION and extensions, unsupported
  version, packet underflow/oversize/truncation/type/trailing data, checked string
  lengths, opaque handles, request-ID mismatch, NAME 0/1/many/count limits,
  UTF-8/Unicode/space/apostrophe/leading-dash/hidden/non-UTF-8 names, partial attrs,
  symlink kind, ignored `longname`, and unsupported flags.
- [x] Run the focused filter and capture the expected compile/test failures.
- [x] GREEN: implement the smallest immutable readers/writers and packet parser;
  validate all bounds before allocation and publish no partial result.
- [x] Run focused tests, then `swift test --filter XMtermRemoteTests`.

## Task 3: TDD target-to-argv construction and typed failures

**Files:**
- Create: `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPTarget.swift`
- Create: `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPError.swift`
- Modify: `Sources/XMtermRemote/Domain/RemoteFileError.swift`
- Create: `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSFTPTargetTests.swift`
- Modify related exhaustive error/presentation tests.

- [x] RED: exact direct, identity, alias, Relay argv; separate arguments; mandatory
  `-T`, `BatchMode=yes`, `-s`; no shell, host-key bypass, credentials, or remote
  filenames; reject invalid immutable targets.
- [x] RED: stable bounded mapping for authentication, host key, unsupported
  interactive auth, permission, not found, unsupported version/server, cancelled,
  timeout, malformed, unavailable, limit, and unknown failures.
- [x] GREEN: implement validated immutable target/launch values and conservative
  typed mappings. Run focused and domain regressions.

## Task 4: TDD the process transport and fatal desynchronization

**Files:**
- Create: `Sources/XMtermRemote/Providers/OpenSSH/SFTPByteTransport.swift`
- Create: `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSubsystemProcess.swift`
- Create: `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPClient.swift`
- Create: `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSubsystemProcessTests.swift`
- Create: `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSFTPClientTests.swift`

- [x] RED: split reads/writes, stdout/stderr separation, 64 KiB diagnostic cap,
  handshake/request/close timeouts, EOF/exit/write/read failures, one outstanding
  ID, cancellation before send, cancellation after send, ID mismatch, malformed
  response, teardown, lazy reconnect, idempotent close, escalation, and reaping.
- [x] GREEN: actor-serialize work; use bounded async byte delivery; never block
  `MainActor`; make every potentially desynchronized state invalidate and settle
  the process before another request.
- [x] Run process/client tests repeatedly and inspect for live child leaks.

## Task 5: Disposable local `sftp-server` integration

**Files:**
- Create: `Tests/XMtermRemoteTests/OpenSSH/LocalSFTPServerIntegrationTests.swift`
- Create only bounded temporary fixture helpers under the same test directory.

- [x] RED/GREEN: drive the production codec/client over a direct
  `/usr/libexec/sftp-server` process abstraction without SSH.
- [x] Resolve initial directory; list empty and populated directories; preserve raw
  non-UTF-8/newline/control names; map file/directory/symlink and partial metadata;
  enforce entry/payload limits; cancel a stalled/in-flight request; close/reap.
- [x] Use `mktemp`-scoped fixtures and remove them after evidence; do not touch user
  files or network.

## Task 6: TDD the production provider and trusted composition

**Files:**
- Create: `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPRemoteFileProvider.swift`
- Modify: `Sources/XMtermRemote/Providers/RemoteProviderMode.swift`
- Modify: `Sources/XMtermRemote/Workspace/RemoteWorkspace+PackageProvider.swift`
- Create: `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSFTPRemoteFileProviderTests.swift`
- Modify: provider contract/composition tests.

- [x] RED: initial `REALPATH(".")`; bounded immediate-child
  `OPENDIR`/sequential `READDIR`/`CLOSE`; skip dot entries; preserve raw components;
  never recursively list or issue per-entry metadata calls; cancel/close settle.
- [x] RED: `.production` is constructible only from the concrete production
  provider; arbitrary/simulated providers cannot claim production; release fixture
  injection remains fail-closed.
- [x] GREEN: implement the provider and narrow trusted constructor; run provider,
  workspace, projection, focus, fixture, and performance regressions.

## Task 7: TDD app/runtime launch integration

**Files:**
- Modify: `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- Modify only if required: launch-spec mapping helpers in `XMtermApp`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceStoreProfileTests.swift`
- Modify: `Tests/XMtermAppTests/TerminalWorkspaceStoreSSHTests.swift`
- Modify: runtime and developer-fixture tests.

- [x] RED: local snapshot -> nil workspace; direct/identity/alias SSH snapshot ->
  exact independent production provider; two runtimes -> two providers; terminal
  process remains unchanged; nested terminal activity cannot retarget workspace;
  runtime/tab/app close settles only its owned provider.
- [x] GREEN: map the immutable validated launch specification at the existing
  `RemoteWorkspaceFactory` boundary. Run all app/runtime/terminal launch regressions.

## Task 8: Focused, full, performance, and security verification

- [x] Run Task 9 codec/transport/provider/local-integration suites.
- [x] Run provider contract, workspace, runtime, all store, descendant selection,
  projection, focus, fixture, and performance suites; preserve the 1,000-entry
  p90 budget below 100 ms and separate network latency from projection time.
- [x] Run `swift build -Xswiftc -warnings-as-errors`.
- [x] Run `swift build -c release -Xswiftc -warnings-as-errors`.
- [x] Run `./scripts/verify.sh` and `git diff --check`.
- [x] Scan for secrets, logging, host-key bypass, human parsing, shells, polling,
  recursion, unchecked lengths, mutation verbs, and process leaks.
- [x] Obtain independent code and security review; resolve every Critical/High
  finding before production acceptance.

## Task 9: Package and real Relay acceptance

**Target:** actual packaged debug/release app and
`allen921103@140.109.226.155:54426` using only existing user authentication.

- [x] Verify release ignores simulated injection, has no badge/fake listing, gives
  local tabs no transport, and gives supported SSH tabs the production provider.
- [x] Verify terminal focus/keyboard, remote-list focus/shortcuts, direct controls,
  process isolation, per-tab close, and app-quit reaping.
- [x] On the real Relay, record the exact noninteractive authentication mechanism;
  resolve the real initial directory; list real children; navigate, Back, Forward,
  Parent, breadcrumb, refresh, lazy expand, nested select, and four copy actions.
- [x] If safely available, observe an honest permission error. Do not manufacture a
  destructive condition or infer this row when unavailable.
- [x] Verify two SSH runtimes remain independent and no transport is orphaned.
- [x] If practical after terminal connection, enter `ssh g207` manually and prove
  the workspace remains attached to the immutable Relay target.
- [x] If secure noninteractive auth or host-key state blocks acceptance, preserve
  the exact blocker and leave ADR/Phase 4A Proposed/PARTIAL without weakening it.

## Task 10: Final clean verification and closeout

**Files:**
- Modify: `docs/decisions/0007-remote-file-provider-transport.md`
- Modify: `docs/exec-plans/0008-phase-4a-remote-workspace-foundation.md`
- Modify: `docs/checklists/remote-workspace-acceptance.md`
- Modify: `docs/audits/0006-phase-4a-remote-workspace-evidence.md`
- Modify: `.superpowers/sdd/phase-4a-progress.md`
- Modify: `ARCHITECTURE.md`, `SECURITY.md`, `TESTING.md`, `PERFORMANCE.md`,
  `PLANS.md`, `PRODUCT.md`, `README.md`

- [x] At the final stable checkpoint, run `swift package clean` and
  `./scripts/verify.sh`; it passed **471 tests / 59 suites in 7.891 s** and all
  unperformed checks are recorded in Audit 0006.
- [x] If and only if every required production gate passes, mark ADR 0007 Accepted
  and Phase 4A COMPLETE. Otherwise retain Proposed/PARTIAL with the exact blocker.
- [x] Walk `docs/checklists/interaction-parity.md` and
  `docs/checklists/remote-workspace-acceptance.md`; update Audit 0006 rather than
  replacing historical evidence.
- [x] Confirm no Phase 4B, Phase 5, or Phase 6 surface was added. Stop after Phase
  4A closeout; do not begin Phase 4B.
