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
- Interruption recovery (2026-07-17): prior session lost after committing Task 7
  Step 1 RED tests referencing `RemoteWorkspaceCommandRoute` and
  `RemoteWorkspaceKeyboardCommand`; recovery confirmed clean tree == origin/main,
  production build green, and test target failing to compile as the expected RED
- Task 7: complete (RED confirmed by missing-type compile failures, then
  `RemoteEntryRow`, `RemoteWorkspaceSidebar` + interaction seam, RootView
  240...420 sidebar with compact Saved Sessions, Remote command menu, performer/
  route/focus-owner guards; 18 focused command tests, 80 focused tests across the
  9 related suites, full verifier 401 tests in 50 suites passing; terminal pane
  identity untouched — detail column and `TerminalPane` keying unchanged)
- Cross-task review (Tasks 5–7): complete inline (subagent workflows hit session
  limits and produced no usable result — recorded honestly, not claimed as a
  multi-agent pass); two Medium findings fixed (empty-directory context menu;
  FILE-NAV-002 honest display of a failed collapsed navigation target); no
  Critical/High; Tasks 5–6 not reimplemented
- Task 8 closeout: complete (env-gated `RemoteWorkspaceDeveloperFixture` seam +
  3 tests; coverage XMtermRemote 93.27%/94.25%, logic-only app scope
  94.49%/82.54%, UI-inclusive 42.29%, whole-source 58.11% — reported separately;
  security/source scans clean except tracked `default.profraw` hygiene finding;
  clean-state verify 404 tests in 51 suites OK; warnings-as-errors debug 82.55 s
  and release 147.59 s clean; packaged simulated manual pass recorded in Audit
  0006 with explicit not-performed rows)
- Task 10: complete (ARCHITECTURE/PRODUCT/README/TESTING/SECURITY/PERFORMANCE/
  PLANS/INTERACTIONS updated; interaction-parity + remote-workspace acceptance
  checklists walked; Audit 0006 created; verify.sh required-file gate extended
  with the six Phase 4A documents; post-change verify 404/51 OK)
- Final status: Phase 4A **PARTIAL** — production structured SFTP transport and
  real Relay Host listing remain blocked by ADR 0007 (Proposed). Task 9 not
  started. No Phase 4B/5/6 work exists. Exact recommended next task: Complete
  Phase 4A production SFTP transport under ADR 0007.
