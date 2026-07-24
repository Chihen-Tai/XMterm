# Phase 4B subagent-driven progress

Baseline: `eb5ebed`, clean before Phase 4B documentation, 471 tests / 59 suites.
User constraint: no commit, merge, push, or tag. Task reviews use working-tree
diffs plus explicit file manifests instead of commit ranges.

- Planning: complete (design, ADR 0008, plan 0010, acceptance checklist; adversarial review READY).
- Task 1 — Phase 4B.1 selection model and workspace migration: complete.
  Independent review found and the implementer repaired an empty-selection arrow
  off-by-one bug plus a multi-selection compatibility-projection inconsistency.
  Root re-verification: 51 focused tests / 4 suites passed; implementer full
  verification: 487 tests / 60 suites, `XMterm verification: OK`.
- Task 2 — Phase 4B.2 capability contracts and codec: complete. Security pre-review
  and independent code review completed. The implementer repaired stream-handle
  failure settlement, removed destination-destructive public writer modes, and
  removed generic EXTENDED payload emission. Re-review: no Critical/Important/Minor
  findings, Ready to proceed. Root re-verification: 64 tests / 6 suites passed;
  full verifier: 512 tests / 61 suites, `XMterm verification: OK`.
- Task 3 — Phase 4B contract repair: complete. Task 3A split the request,
  endpoint, snapshot, retry, checkpoint, and exact-bounds contracts into focused
  model files. Task 3B added dedicated transfer endpoint providers, one-directory
  listing, immutable endpoint factories, and exactly one coordinator/engine per SSH
  workspace with none for local runtimes. Task 3C migrated the engine/coordinator
  to complete requests, full UUID+generation attempt identity, bounded snapshots,
  recursive checkpoint/cleanup validation, conflict slot release, capability
  downgrade re-entry, and safe fail-closed production composition. Evidence:
  Task 3C focused tests passed 32/32; targeted Task 3C gate passed 8/8; ownership
  gate passed 6/6; concurrency stress passed x5; the 10,000-retry stale-callback
  test passed; combined Task 3 suites passed 89 tests x3; independent architecture,
  concurrency, security, and code-quality reviews approved with no unresolved
  Critical/High finding; file-cap and diff/build checks passed. The user no-commit,
  no-merge, no-push, no-tag rule remains active.
- Task 4 — Phase 4B.4 production streaming workers and mutations: in progress next.
- Task 5 — Phase 4B.5 recursive/batch/collision execution: pending. Known Medium
  debt before Task 5 acceptance: `RemoteTransferItemFailure` must become
  descendant-capable so recursive/batch failures retain exact descendant identity.
- Task 6 — Phase 4B.6 actual multi-selection UI plus clipboard/action policy:
  pending. This must pass before drag-and-drop acceptance begins.
- Task 7 — Phase 4B.7 drag-and-drop built on proven multi-selection and transfer
  execution: pending.
- Task 8 — Phase 4B.8 UX/accessibility/lifecycle/performance hardening: pending.
- Task 9 — Phase 4B.9 security, packaged acceptance, real Relay acceptance, and
  closeout: pending. Do not cite an unlocated item-count closeout source; close
  only from direct evidence in the canonical plan/checklist.
