# Task 4 Report: Documentation and Regression Evidence

## Status

The bounded documentation update is complete. The source/automated Phase 2
tab-strip polish and the completed core rendered layout/reveal pass are documented,
while every broader requirement retains its Partial qualifier and every
unperformed specialized check remains open.

Execution Plan 0006 is intentionally **not complete**. The final independent
re-review is READY and Task 4 Step 8 is complete. Task 4 Step 6 is partially
complete: the staged app passed the core rendered matrix, while physical trackpad
momentum, long-title rendering, full keyboard traversal, actual VoiceOver, Reduce
Motion, relay invocation, and quantitative performance inspection remain open.

## Files changed

Modified only the Task 4-authorized documentation:

- `ARCHITECTURE.md`
- `INTERACTIONS.md`
- `PLANS.md`
- `TESTING.md`
- `docs/design-docs/index.md`
- `docs/design-docs/session-tabs-ux.md`
- `docs/design-docs/macos-app-behavior.md`
- `docs/design-docs/tab-strip-redesign.md`
- `docs/checklists/interaction-parity.md`
- `docs/exec-plans/0006-phase-2-tab-strip-polish.md`

Created:

- `docs/audits/0004-phase-2-tab-strip-polish-evidence.md`
- `.superpowers/sdd/task-4-report.md`

No Swift source, test, dependency, script, security, performance-budget, agent-rule,
or engineering-contract file was edited. No commit, stage, branch, push, or other
Git mutation was performed.

The post-review scheduling/evidence reconciliation modified:

- `ARCHITECTURE.md`, `INTERACTIONS.md`, `PLANS.md`, and `TESTING.md`;
- `docs/design-docs/tab-strip-redesign.md`, `session-tabs-ux.md`, and
  `macos-app-behavior.md`;
- `docs/checklists/interaction-parity.md`;
- `docs/audits/0004-phase-2-tab-strip-polish-evidence.md`;
- `docs/exec-plans/0006-phase-2-tab-strip-polish.md`;
- this report.

It did not change `docs/design-docs/index.md` or any Swift, test, or script file.

## Exact documentation claims

- The header-width owner feeds one pure sizing policy and assigns the tab strip its
  exact non-greedy width.
- Fitting tabs use 180 points, shrink equally to 120 points, and then hold 120
  points while one horizontal viewport scrolls. The 240-point maximum remains an
  explicit policy bound.
- One stable-ID `LazyHStack` is the only tab sequence. The existing local/relay `+`
  menu is a fixed non-scrolling sibling, and at least 8 points separate the strip
  from remaining toolbar space.
- Ordered IDs, selected ID, and viewport width identify reveal work. Creation,
  click activation, replacement selection after close, and resize request selected-
  tab reveal. Initial and tab/selection requests settle for 16 ms; initial reveal
  is unanimated and only tab/selection changes may animate. Viewport-only requests
  use a 75 ms cancellation-coalesced unanimated debounce. Each accepted request
  performs exactly one final scroll, and Reduce Motion removes the optional
  tab/selection animation.
- PTY/session/process/SSH ownership, terminal-surface identity, close policy,
  scrollback, and local/relay actions remain unchanged.
- Pure tests establish numerical layout policy and reveal-target identity. The
  separate staged pass establishes the observed core layout/scroll/reveal behavior,
  but not physical trackpad delivery, full keyboard traversal, actual VoiceOver,
  long-title rendering, or visual Reduce Motion behavior.

## Requirement and plan statuses

- `TAB-001`: **Partial** — remembered-session selection/double-click are absent.
- `TAB-002`: **Partial** — staged click activation, horizontal overflow, stable
  identity, and create/activation/close/resize reveal behavior were observed;
  keyboard tab navigation, physical trackpad momentum, drag reorder, and
  reveal-after-reorder are deferred or unverified.
- `TAB-003`: **Partial** — middle-click close is absent.
- `TAB-005`, `APP-003`, `A11Y-001`–`A11Y-003`, and `MAC-001`: remain **Partial**
  with their broader product/manual qualifiers.
- Phase 3 Session Manager remains the next product phase.
- Plan Tasks 1–3 and Task 4 Steps 1–5, 7, and 8 are recorded complete. Task 4 Step
  6 is partially complete with its specialized evidence gaps listed below.

The normative `INTERACTIONS.md` requirement clauses were not rewritten.

## Final automated results

Host/toolchain snapshot:

```text
sw_vers
ProductVersion: 26.5.2
BuildVersion: 25F84

uname -m
arm64

swift --version
Apple Swift version 6.3.3

xcode-select -p
/Library/Developer/CommandLineTools
```

Final post-review canonical verifier:

```text
./scripts/verify.sh
Required repository files: OK
Test run with 143 tests in 23 suites passed after 7.203 seconds
XMterm verification: OK
```

Result: exit 0. `TerminalTabStripLayoutTests` passed 17 tests in 1 suite.

Final clean debug and release `swift build` commands used isolated `/tmp` scratch
directories with `-Xswiftc -warnings-as-errors`. Both exited 0 with no warnings:

- debug: `Build complete! (38.56s)`;
- release: `Build complete! (58.22s)`.

## Controller-provided integration evidence

The controller supplied these final post-review results for Audit 0004:

- isolated `/tmp/xmterm-tab-polish-final-coverage` run: 143 tests in 23 suites
  passed in 7.132 seconds; scoped gate 83.42% lines (3,008/3,606) and 85.20%
  functions;
  `TerminalTabStripLayout.swift` 100% lines/functions; all first-party Sources
  63.36% lines (3,242/5,117) and 66.14% functions;
- `./script/build_and_run.sh --verify`: exit 0 and the packaged XMterm process
  remained running.
- final independent re-review: **READY** for the source/automated slice, with no
  remaining Critical, Important, or Minor finding.

The earlier non-isolated coverage mismatch was not cited. The packaged-launch
result is not represented as visual evidence.

## Manual evidence

The final reviewed staged bundle was launched and inspected. One tab was visually
approximately 180 points wide; two/three tabs stayed content-sized with `+` directly
after the final tab; six tabs shrank equally; and ten/eleven tabs overflowed at
readable widths with `+` pinned. Computer-use horizontal scrolling worked in both
directions. Selecting the first tab, creating a new final tab, closing the active
final tab, and narrowing the live window each revealed the resulting active tab.
The `+` menu opened by pointer, listed the local and relay actions, and dismissed
with Escape. AX inspection found the expected tab container, selected/status state,
close labels, `New terminal` metadata, and separate toolbar sibling. Eleven-tab
interaction remained qualitatively responsive, and the app was returned to one
local tab.

Open evidence is limited to physical trackpad momentum, rendered long-title
truncation, full Tab-key traversal/focus restoration, actual VoiceOver traversal,
the system Reduce Motion toggle, relay invocation/network/process behavior, and
quantitative CPU/memory/launch/latency/Instruments measurements. Full XCUITest
remains unavailable on the Command Line Tools-only host. These rows remain pending
in the parity checklist and Audit 0004 without inference from source or pure tests.
