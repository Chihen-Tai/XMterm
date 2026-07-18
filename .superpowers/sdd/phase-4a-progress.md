# Phase 4A Subagent-Driven Development Ledger

- Planning: complete (design, ADR 0006, ADR 0007, checklist, Execution Plan 0008,
  and six stable requirement IDs written before production code)
- Baseline: `./scripts/verify.sh` passed 268 tests in 35 suites
- Historical isolation exception: at plan start `XMterm-starter` was an untracked
  directory in the unrelated `/Applications/codes` repository, so the early tasks
  used before/after snapshots instead of misleading parent-repository commits. By
  the 2026-07-18 handoff it was its own repository with stable base `2f7ffb1` and
  handed-off HEAD `16ef945`.
- Production transport: complete under Accepted ADR 0007 using system OpenSSH and
  the bounded read-only SFTP v3 codec; no human-output parser or fake Relay listing.
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
- Historical Task 8 closeout status: Phase 4A **PARTIAL** — production structured SFTP transport and
  real Relay Host listing remain blocked by ADR 0007 (Proposed). Task 9 not
  started. No Phase 4B/5/6 work exists. Exact recommended next task: Complete
  Phase 4A production SFTP transport under ADR 0007.
- Hardening handoff recovery (2026-07-18): independently reviewed stable base
  `2f7ffb1` through handed-off HEAD `16ef945`, then continued on
  `codex/phase-4a-hardening-review` without starting Task 9 or Phase 4B/5/6.
  Pre-edit review kept the focus-gating and shared-projection designs, required
  stronger eviction/history/performance evidence, and rejected the provider
  composition because an arbitrary provider could still be paired with a trusted
  production mode.
- Hardening correction: `RemoteProviderComposition` now has a private raw
  pairing, public unavailable-only construction, a typed package-only simulated
  fixture seam, and an explicit `.packageTest` mode for ordinary test providers.
  No production constructor exists until ADR 0007 introduces a concrete reviewed
  transport. The release fixture gate is compile-time fail-closed. Provider TDD
  recorded the original missing-composition RED, an external compiler probe that
  reproduced arbitrary-production construction, a package-test-mode RED, then
  debug **8/1** and actual release **9/1** GREEN. Independent security and code
  reviews approved the corrected boundary.
- Selection/projection correction: the projection depth derives from the single
  workspace expansion bound. New tests cover deterministic cache-eviction repair
  to the nearest visible ancestor, exact history selection clearing after
  eviction/reload, and a nested completion hidden behind a collapsed ancestor
  while expansion intent is restored on re-expand. Focused GREEN: descendant
  selection **12/1**, projection **8/1**, performance **2/1**, commands **23/1**.
  The original 1,000-entry publication p90 gate remains, with a separate
  1,000-entry projection plus 1,000 exact-lookup-iteration p90 gate.
- Handoff verification: a 12-suite combined run had one pre-existing real-PTY
  timeout under parallel load (122/123); the exact case, its full suite, and the
  clean verifier all passed separately. After `swift package clean`, the full
  verifier passed **436 tests / 53 suites** and reported `XMterm verification:
  OK`; debug/release warnings-as-errors builds, release fail-closed packaged
  acceptance, static security/policy scans, and independent final code/security
  reviews passed. The final post-documentation verifier repeated **436/53 in
  7.755 s** and reported OK. The historical Audit 0006 `default.profraw` finding
  remains recorded as resolved in `2f7ffb1`.
- Historical hardening status at that checkpoint remained Phase 4A **PARTIAL**;
  Task 9 had not yet started. The later closeout below supersedes that status.

## Task 9 production transport closeout (2026-07-18)

- TDD complete: bounded SFTP v3 codec, exact OpenSSH target argv, conservative
  failures, serialized client, nonblocking subsystem process, concrete production
  provider, and release-safe composition. RED evidence included missing-type
  compile failures and the review regression that exposed signal 13 on the old
  synchronous large write.
- Review complete: all initial High/Medium code and Medium security findings were
  fixed; independent code and security re-review found no remaining Critical,
  High, or Medium finding.
- Automated verification complete: focused production suites **22/6 in 0.135 s**;
  pre-closeout verifier **471/59 in 7.672 s**; warnings-as-errors debug and release
  builds passed; performance **2/1 in 0.235 s**, with both p90 gates below 100 ms.
- Final stable clean gate complete: `swift package clean` succeeded and the full
  verifier passed **471/59 in 7.891 s**, ending with `XMterm verification: OK`.
- Package/Relay acceptance complete: exact independent SFTP argv observed, real
  listings/navigation/lazy expansion/four copy actions/permission error passed,
  two runtimes were independent, nested `ssh g207` did not retarget the workspace,
  release ignored simulated injection, and tab/app close reaped provider children.
- Authentication evidence: public key through a configured OpenSSH key; no agent
  identity, app-owned `ControlMaster`, host-key bypass, or Keychain claim.
- Scope remained Phase 4A read-only. No Phase 4B mutation/transfer, Phase 5, or
  Phase 6 implementation was added.
- Final status: Phase 4A **COMPLETE**. Exact next task: **Phase 4B — Remote File
  Mutations and Transfers**.
