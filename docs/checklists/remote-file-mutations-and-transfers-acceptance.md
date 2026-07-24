# Phase 4B Remote File Mutations and Transfers Acceptance Checklist

- **Status:** Task 3 architecture-contract repair complete; Task 4 production
  streaming workers and mutations are next/in progress
- **Design:**
  [`../design-docs/phase-4b-remote-file-mutations-and-transfers.md`](../design-docs/phase-4b-remote-file-mutations-and-transfers.md)
- **Plan:**
  [`../exec-plans/0010-phase-4b-remote-file-mutations-and-transfers.md`](../exec-plans/0010-phase-4b-remote-file-mutations-and-transfers.md)
- **Transport:**
  [`../decisions/0008-remote-file-mutation-and-transfer-transport.md`](../decisions/0008-remote-file-mutation-and-transfer-transport.md)

Do not mark a row complete from source inspection alone where the row requires
rendered, packaged, local-filesystem, or real-host evidence.

Current implementation checkpoint: Task 1 selection model/workspace migration,
Task 2 capability contracts/codec, and Task 3A/3B/3C architecture-contract repair
are recorded complete in the Phase 4B progress ledger. Production streaming
workers begin in Task 4. Checklist rows below remain unchecked until their required
implementation and acceptance evidence exists.

Task order is binding: Task 3A request/endpoint/snapshot/retry/checkpoint/bounds
contracts; Task 3B dedicated endpoint-provider/listing capability plus
session/workspace ownership; Task 3C engine/coordinator migration and closeout;
Task 4 production workers and mutations; Task 5 recursive/batch/collision
execution; Task 6 actual multi-selection UI plus clipboard/action policy; Task 7
drag-and-drop; Task 8 hardening; Task 9 security, packaged acceptance, real Relay
acceptance, and closeout.

## Recovery and baseline

- [x] Actual worktree recovered before edits: clean
  `codex/phase-4a-hardening-review` at `eb5ebed`.
- [x] Unmodified baseline verifier passed 471 tests in 59 suites.
- [x] Phase 4A contracts, evidence, implementation, and progress ledger reviewed.
- [x] Phase 4B design and ADR written before production implementation.
- [x] Phase 4B execution plan written before production implementation.
- [x] Task 3A immutable request, endpoint, snapshot, retry, checkpoint, and bounds
  contracts pass focused RED/GREEN tests and preserve Task 1/2 regressions.
- [x] Task 3B dedicated endpoint-provider/listing capability and SSH workspace
  ownership pass focused RED/GREEN tests.
- [x] Task 3C engine/coordinator migration, retry/conflict behavior, focused
  repetition, full verifier, whitespace, and independent review pass.

## Task 3 repaired contract gates

- [x] Every admitted request contains executable immutable source/destination
  endpoint snapshots, owner identity, exact raw paths or local file identity,
  operation kind, and collision/metadata/symlink/recursive/cross-runtime policies.
- [x] Logical item IDs remain stable job/item keys but never the only description
  of work and never require a mutable UI lookup table.
- [x] A job accepts one remote source endpoint snapshot only; same-runtime
  copy/move/rename reuse it, while destination-owned copy adds one destination
  endpoint, preserving the four-channel runtime bound.
- [x] Retry separates visible job ID, stable logical item identity, and the current
  attempt UUID plus checked `UInt64` generation without unbounded attempt history.
- [x] Recursive checkpoints distinguish top-level items, discovered descendants,
  committed descendants, failed/unstarted descendants, and attempt-owned cleanup;
  retries exclude committed descendants and restart incomplete files at byte zero.
- [x] Endpoint snapshots are executable, immutable, derived from the runtime launch
  snapshot/trusted composition, and never exposed through UI snapshots.
- [x] Dedicated endpoint providers offer structured one-directory listing, `lstat`,
  bounded reads, exclusive staging writes, required mutations, cancellation, and
  close without borrowing the browsing provider.
- [x] Every SSH workspace owns exactly one coordinator/engine; local runtimes own
  none; no global queue, RootView, SwiftUI view, or TerminalWorkspaceStore owns
  operational queue state.
- [x] Bounds are enforced exactly: 1,000 nonterminal jobs, 500 terminal records,
  20,000 top-level request items/job, 20,000 combined work/checkpoint/failure
  records/job, 40,000 combined such records/engine, 40,000 cleanup entries/job,
  80,000 cleanup entries/engine, one collision/job, one current attempt/generation
  per job, depth 128, 1,024 pending directories, and 4 KiB UTF-8 presentation
  strings.
- [x] Variable-sized execution identity is checked at 16 MiB/job and 64 MiB/engine;
  local URLs are at most 32 KiB, file/volume identifiers 4 KiB, bookmarks 64 KiB,
  and one relative raw work path 32 KiB.
- [x] Conflict owns no worker, provider/channel, or active slot; resolution
  preserves job/current attempt/checkpoint, revalidates destination, reacquires
  providers, and requeues deterministically.

Task 3 evidence: Task 3C focused tests passed 32/32; targeted Task 3C gate passed
8/8; ownership gate passed 6/6; concurrency stress passed x5; the 10,000-retry
stale-callback test passed; combined Task 3 suites passed 89 tests x3; independent
architecture, concurrency, security, and code-quality reviews approved with no
unresolved Critical/High finding; file caps, build, and diff checks passed.

Task 5 debt: `RemoteTransferItemFailure` must become descendant-capable before
recursive/batch acceptance can close.

## Selection and action policy

- [ ] Click, Command-click, Shift-click, Command-Shift-click, arrows, Shift-arrows,
  Command-A, Escape, and context-click follow the locked semantics.
- [ ] Selection uses exact raw paths and the shared ordered visible projection.
- [ ] Refresh/collapse/cache/history repair preserves only surviving exact identity.
- [ ] Two runtimes restore independent selection and selection performs no I/O.
- [ ] Menu, toolbar, context menu, and shortcuts share one availability policy.
- [ ] Terminal and text-field clipboard/keyboard behavior is unchanged.

## Mutation

- [ ] Rename validates one component and handles collision/permission/errors.
- [ ] New Folder and exclusive New File work without silent overwrite.
- [ ] Same-runtime move uses structured rename and rejects self/descendant moves.
- [ ] Delete confirms count/location/permanence and reports each item.
- [ ] Nonempty recursive delete requires stronger confirmation, is bounded and
  cancellable, and never follows a symlink.
- [ ] Successful mutations refresh only affected loaded parents.

## Transfers and queue

- [ ] Small, empty, large, Unicode/raw-name, hidden, spaced, quoted, apostrophe,
  and leading-dash upload/download cases pass.
- [ ] Directory upload/download/copy uses bounded iterative traversal.
- [ ] At most two jobs run per runtime; browsing remains responsive.
- [ ] 64 KiB chunks keep file memory bounded; no whole-file buffer exists.
- [ ] Progress is monotonic; totals/states/errors are honest and accessible.
- [ ] Cancellation stops publication, settles the worker, and cleans owned staging.
- [ ] Retry creates a new attempt and never republishes an older completion.
- [ ] Replace/Skip/Keep Both/Cancel/Apply-to-All never silently overwrite.
- [ ] Local and remote complete destinations survive failures/cancellation.
- [ ] Executable/permission bits are preserved where supported.
- [ ] Symlink/package policy is rejected visibly and never silently follows targets.

## Clipboard and drag-and-drop

Task 6 actual multi-selection UI plus clipboard/action policy must pass before
Task 7 drag-and-drop acceptance begins.

- [ ] Private Copy/Cut/Paste handles one/many exact same-runtime paths.
- [ ] Stale/deleted/private malformed payloads fail safely.
- [ ] Cross-runtime remote paste/cut is rejected honestly; cross-runtime remote drag
  performs a bounded copy and leaves the source intact.
- [ ] Finder file/directory/multi-item drop uploads to the highlighted/current dir.
- [ ] Remote file/directory drag to Finder fulfills promised content asynchronously.
- [ ] Remote same-workspace drag moves by default and Option-copies.
- [ ] Invalid targets show forbidden feedback before network work.
- [ ] Drag cancellation and promise/staging cleanup leave no orphan normal-case data.

## Lifecycle, UX, accessibility, and performance

- [ ] Queue status remains compact and terminal detail remains dominant.
- [ ] Rename/create/delete/collision/close sheets restore sensible focus.
- [ ] Icon controls, selection count, progress, error, and conflict states have
  accessibility labels and are not color-only.
- [ ] Close tab/window/quit with queued/running upload/download/collision work uses
  one explicit aggregate decision and awaits cleanup.
- [ ] Closing one runtime never affects another runtime's jobs/provider/terminal.
- [ ] A cross-runtime drag-copy is destination-owned: source close after enqueue
  does not cancel it, destination close does, and quit settles it exactly once.
- [ ] 1,000-job model and large-chunk pipeline performance gates pass.
- [ ] No MainActor network or filesystem I/O and no transfer-caused >100 ms local
  model stall is observed in the defined deterministic gates.

## Security and production acceptance

- [ ] No shell/SCP/human-SFTP parsing, host-key bypass, credential storage/logging,
  raw stderr/path logging, unsafe temp permissions, or unbounded work exists.
- [ ] Every new packet has bounded encode/decode, exact ID validation, malformed
  tests, typed status mapping, and fatal desynchronization behavior.
- [ ] Debug and release warnings-as-errors builds pass.
- [ ] Full verifier and clean verifier pass with recorded exact counts.
- [ ] Independent code/security review has no unresolved Critical/High finding.
- [ ] Packaged Finder upload/download, clipboard, mutation, collision, cancel/retry,
  close/quit, appearance, and accessibility acceptance is recorded.
- [ ] Real Relay acceptance uses one recorded unique directory only.
- [ ] Upload/download/directory/rename/move/create/copy/cut/delete/collision/cancel/
  retry/two-session cases pass inside that directory.
- [ ] Manual `ssh g207` does not retarget Remote Workspace operations.
- [ ] Only the exact acceptance directory is cleaned; unrelated user data is not
  touched.
- [ ] Phase 5 was not started.
- [ ] Phase 6 was not started.
