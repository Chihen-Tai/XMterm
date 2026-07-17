# Phase 4A Subagent-Driven Development Ledger

- Planning: complete (design, ADR 0006, ADR 0007, checklist, Execution Plan 0008,
  and six stable requirement IDs written before production code)
- Baseline: `./scripts/verify.sh` passed 268 tests in 35 suites
- Isolation exception: `XMterm-starter` is an untracked directory in the unrelated
  `/Applications/codes` repository, so no worktree, branch, task commit, or git
  review range can represent this work honestly. Per-task before/after snapshots
  and read-only file review replace commit ranges.
- Production transport: blocked by ADR 0007; no human `sftp ls` parsing, custom
  SFTP protocol, or fake Relay listing is permitted.
- Task 1: complete (untracked snapshot review clean; 19 focused tests and full
  verifier 287 tests/37 suites passing; Unicode bidi/format display and
  maximum-depth prefix findings fixed and re-reviewed)
- Task 2: complete (untracked snapshot review clean; 13 provider-contract tests,
  all 14 typed error categories, and full verifier 300 tests/38 suites passing;
  no forbidden transport pattern found)
- Task 3: complete (independent review approved with 0 findings; 10 focused cache
  tests, additional zero-bound/pinning edge harness, and full verifier 310
  tests/39 suites passing)
- Task 4: complete (29 focused tests in 5 suites; required race gate passed three
  consecutive runs; cancellation assertion passed 10 repeats; external close and
  off-main probes passed; all High/Medium review findings fixed; independent
  production re-review approved; final fixture cancellation waiter finding fixed;
  production and primary test files are below 800 lines)
- Task 5: complete pending final cross-task review (session-centric runtime registry;
  8 aggregate tests and 13 runtime-registry tests passing; 54-test Phase 1–3 focused
  regression matrix passing; pre-settled terminal, reused workspace, cross-domain
  UUID, and synchronous-shutdown review findings fixed test-first)
- Task 6: complete pending final cross-task review (immutable presentation/action
  policy, lossless plain-text pasteboard adapter, and exact focused-owner guards;
  26 focused tests passing; full verifier passed 387 tests in 50 suites)
- Task 8 performance gate: complete (deterministic 1,000-entry fixture; construction
  measured separately; one warm-up plus 11 publications; 20.84 ms p90 observed
  against the 100 ms model/order/cache-publication budget)
