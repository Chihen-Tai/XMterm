# Phase 4B Task 3 Brief — Contract Repair

**Status:** Task 3 architecture-contract repair complete. Tasks 3A, 3B, and 3C
passed focused gates, repeated combined Task 3 verification, review, and closeout.
Production streaming workers remain Task 4 work.

**Approved source:** the 2026-07-22 contract-first repair approved in the active
task history.

**Canonical references:**

- `docs/design-docs/phase-4b-remote-file-mutations-and-transfers.md`
- `docs/decisions/0008-remote-file-mutation-and-transfer-transport.md`
- `docs/exec-plans/0010-phase-4b-remote-file-mutations-and-transfers.md`
- `docs/checklists/remote-file-mutations-and-transfers-acceptance.md`

## Scope

Repair Task 3 before production streaming workers begin. Preserve completed Task 1
selection behavior and completed Task 2 capability/codec behavior. Do not wire
Task 4 production workers, Task 5 recursive execution, Task 6 actual UI
multi-selection, or Task 7 drag-and-drop as part of Task 3.

Task 3 is split into:

1. **Task 3A:** Transfer request, endpoint, snapshot, retry, checkpoint, and bounds
   contracts.
2. **Task 3B:** Dedicated provider/listing capability and session/workspace
   ownership.
3. **Task 3C:** Engine/coordinator migration, tests, review, and closeout.

## Closeout Evidence

- Task 3C focused tests passed 32/32.
- Targeted Task 3C state/race gate passed 8/8.
- Runtime/workspace ownership gate passed 6/6.
- Transfer concurrency stress passed x5.
- The 10,000-retry stale-callback test passed with full UUID+generation identity.
- Combined Task 3 suites passed 89 tests x3.
- Independent architecture, concurrency, security, and code-quality reviews
  approved the repair with no unresolved Critical/High finding.
- File caps, build, and diff checks passed. The user no-commit/no-push/no-merge/
  no-tag rule remains binding.

## Binding Contracts

- A `RemoteTransferRequest` is an immutable executable snapshot. It carries job
  kind, stable job ID, owning runtime/workspace identity, immutable source
  endpoint(s), immutable destination endpoint, exact raw `RemotePath` identities,
  local URL/file identity where applicable, collision policy, metadata policy,
  symlink policy, recursive policy, and cross-runtime policy.
- Logical item IDs remain stable UI/job keys, but they are never the only
  description of the requested work and never require a mutable UI lookup table.
- One job accepts exactly one remote source endpoint snapshot. Same-runtime copy,
  move, and rename reuse it as the destination endpoint; destination-owned copy
  adds exactly one request-owner destination endpoint. Mixed source endpoints are
  rejected before admission so the per-worker channel bound remains exact.
- A job separates visible stable job identity, stable logical item identity, and
  the current attempt identity. Retry creates a fresh attempt UUID with checked
  generation increment. The engine retains no unbounded attempt UUID history.
- Stale callbacks are rejected by comparing both attempt UUID and generation.
- Recursive checkpoints distinguish top-level request items, discovered descendant
  work, committed descendants, failed/unstarted descendants, and attempt-owned
  staging cleanup. Retry excludes committed descendants and restarts incomplete
  files at byte zero; Task 3 must not claim byte-range resume. Cleanup retry may
  act only on exact current-attempt cleanup entries whose top-level keys belong to
  the request, and must retain safe cleanup failure evidence instead of deriving or
  deleting fallback paths.
- Endpoint snapshots are execution-only immutable values derived from the
  `RuntimeSession` launch snapshot and trusted provider composition. UI snapshots
  never expose endpoint material, credentials, bookmarks, raw provider values,
  handles, unrestricted raw paths, or local resource IDs.
- Dedicated transfer endpoint providers must support structured one-directory
  listing, `lstat`, bounded reads, exclusive staging writes, required structured
  mutations, cancellation, and close. Provider listing is non-recursive; bounded
  recursive traversal belongs to later workers.
- Every SSH `RemoteWorkspace` owns exactly one session-scoped
  `RemoteTransferCoordinator`/engine composition. Local runtimes own none. No
  global queue, `RootView`, SwiftUI view, or `TerminalWorkspaceStore` owns
  operational queue state.
- A conflict job owns no worker, provider/channel set, or active concurrency slot.
  Resolution preserves job identity, preserves the current attempt identity,
  retains bounded checkpoints, revalidates the destination, reacquires fresh
  providers, and requeues deterministically.
- Actor slot/clock race repairs are part of the Task 3 contract: conflict and
  cancellation release active slots before publication, ordinary current-item
  progress is coalesced to 10 Hz, and state/phase/conflict/error edges publish
  immediately with monotonic timestamps.

## Exact Bounds

- 1,000 nonterminal jobs per engine.
- 500 most-recent terminal records after all nonterminal jobs are preserved.
- 20,000 top-level requested items per job.
- 20,000 combined discovered work items, checkpoints, and item failures per job.
- 40,000 combined discovered work items, checkpoints, and item failures per engine.
- 40,000 cleanup entries per job.
- 80,000 cleanup entries per engine.
- One current collision per job.
- One current attempt UUID plus checked `UInt64` generation per job.
- 32 KiB UTF-8 per local URL, 4 KiB per local file/volume identifier, 64 KiB per
  bookmark, and 32 KiB per relative raw work path.
- 16 MiB checked retained variable-size execution data per job and 64 MiB per
  engine, including endpoint material, identities, paths, failures, cleanup, and
  presentation strings.
- Recursive depth 128 and 1,024 pending directories where recursive policy applies.
- 4 KiB UTF-8 each for source summary, destination summary, and current-item
  presentation text.
- All aggregate counters use checked arithmetic and fail with `limitExceeded`
  before insertion or wraparound.

## Task 3A Acceptance

Acceptance IDs: `APP-007`, `APP-008`, `FILE-XFER-001`, `FILE-XFER-003`,
`SESS-011`.

- [x] Add RED tests for complete request identity, owner/policy validation, endpoint
  snapshot independence from later workspace/profile mutation, and admitted
  requests needing no UI lookup.
- [x] Implement validating model values and presentation-only snapshots only.
- [x] Add RED/GREEN tests for attempt generation, stale callback rejection after many
  retries, recursive checkpoint exclusion, incomplete-file restart from byte zero,
  presentation redaction, and every exact bound/boundary+1 case.
- [x] Run related Task 1/2 regressions so completed selection and provider/codec
  behavior remains intact.

## Task 3B Acceptance

Acceptance IDs: `FILE-XFER-001` through `FILE-XFER-004`, `SESS-004`,
`SESS-006`, `SESS-011`.

- [x] Add RED/GREEN tests for dedicated endpoint provider listing, `lstat`, read,
  exclusive staging write, mutations, fresh provider/capability handshake per
  factory call, snapshot-derived SSH/simulated composition, no browsing-provider
  borrowing, and fail-closed untrusted material.
- [x] Add RED/GREEN tests proving every SSH workspace owns exactly one
  coordinator/engine, local runtime composition owns none, two workspaces are
  isolated, close rejects new work, workspace close awaits transfer settlement
  before browsing-provider settlement, and closing one runtime cannot cancel
  another.

## Task 3C Acceptance

Acceptance IDs: `APP-007`, `APP-008`, `FILE-XFER-001`, `FILE-XFER-003`,
`SESS-011`.

- [x] Add RED/GREEN tests for FIFO scheduling, maximum two active jobs, state and phase
  publication, 10 Hz ordinary progress coalescing, one failure not corrupting
  another, two-engine isolation, cancellation settlement, conflict slot release,
  retry checkpoint behavior, stale callback rejection, and atomic-replace
  capability downgrade after provider reacquisition.
- [x] Migrate the engine/coordinator to store complete admitted requests and bounded
  checkpoint state, publish presentation-only snapshots, and use injected UUID,
  clock, endpoint-provider, and staging factories.
- [x] Close Task 3 only after combined focused Task 3 tests pass repeatedly, the full
  verifier passes, whitespace passes, and independent architecture/concurrency/
  security/code-quality review has no unresolved Critical/High finding.

## Known Follow-up Debt

- Task 5 must make `RemoteTransferItemFailure` descendant-capable before recursive
  or batch acceptance can close. Current Task 3 failure retention is sufficient for
  top-level deterministic engine behavior but is intentionally not final recursive
  descendant presentation.

## Required Order After Task 3

Task 4 production streaming workers and mutations; Task 5 recursive/batch/collision
execution; Task 6 actual multi-selection UI plus clipboard/action policy; Task 7
drag-and-drop built on proven multi-selection and transfer execution; Task 8
hardening; Task 9 security, packaged acceptance, real Relay acceptance, and
closeout.
