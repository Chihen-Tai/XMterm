### Task 4: Documentation, manual verification, and full regression gate

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `INTERACTIONS.md`
- Modify: `PLANS.md`
- Modify: `TESTING.md`
- Modify: `docs/design-docs/index.md`
- Modify: `docs/design-docs/session-tabs-ux.md`
- Modify: `docs/design-docs/macos-app-behavior.md`
- Modify: `docs/checklists/interaction-parity.md`
- Create: `docs/audits/0004-phase-2-tab-strip-polish-evidence.md`
- Modify: `docs/exec-plans/0006-phase-2-tab-strip-polish.md`

**Interfaces:**
- Consumes: final tested behavior and rendered observations.
- Produces: requirement-aligned implementation status and evidence without claiming
  Session Manager, SFTP, Settings, drag reorder, or unperformed checks.

- [ ] **Step 1: Update architecture and interaction status**

Document the pure sizing boundary, non-greedy viewport, pinned sibling `+`, stable
lazy tab sequence, active reveal triggers, Reduce Motion behavior, and toolbar
separation. Mark the overflow/reveal subset of `TAB-002` implemented while keeping
drag reorder and shortcut gaps partial.

- [ ] **Step 2: Update design/index/status documents**

Add `tab-strip-redesign.md` to the design index; update the session-tab and macOS
behavior documents plus `PLANS.md` with a completed Phase 2 polish slice. Keep
Phase 3 Session Manager as the next product phase.

- [ ] **Step 3: Update testing and parity documentation**

Record deterministic policy/reveal tests and add manual checklist rows for pinned
`+`, trackpad overflow, active reveal, long-title truncation, keyboard focus,
VoiceOver, Reduce Motion, and local/relay regression.

- [ ] **Step 4: Run canonical verification**

Run `./scripts/verify.sh`.

Expected: repository validation and every existing/new test suite pass.

- [ ] **Step 5: Run warning-clean debug and release builds**

Run clean SwiftPM debug and release builds with warnings treated as errors using
scratch paths under `/tmp`. Expected: both builds pass with no warnings.

- [ ] **Step 6: Stage and manually inspect the native app**

Run `./script/build_and_run.sh --verify`, then verify:

1. one to three tabs stay 180 pt and `+` hugs the final tab;
2. repeated creation shrinks tabs equally to 120 pt, then scrolls;
3. `+` remains visible and opens the unchanged local/relay menu;
4. the newest/selected tab is revealed, including after resize and closure;
5. long titles truncate to one line and close targets remain usable;
6. pointer, keyboard focus, accessibility labels, and Reduce Motion behave;
7. local and relay tabs retain Phase 1/2 focus, close, process, and isolation
   behavior.

- [ ] **Step 7: Record honest evidence and gaps**

Write exact automated counts/build outcomes and only the manual observations that
were performed. Record XCUITest or VoiceOver gaps explicitly rather than inferring
them.

- [ ] **Step 8: Run final review and verification**

Dispatch independent code/requirements review, address all critical/high findings,
then rerun `./scripts/verify.sh`. Mark this plan complete only after the final run
passes.
