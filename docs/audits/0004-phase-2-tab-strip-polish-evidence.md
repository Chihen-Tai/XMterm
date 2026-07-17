# Audit 0004: Phase 2 Tab-Strip Polish Evidence

- **Date:** 2026-07-16
- **Status:** READY for the source/automated slice; core rendered layout/reveal
  inspection complete, with specialized accessibility/input/performance checks pending
- **Host:** macOS 26.5.2 (25F84), Apple silicon arm64, Command Line Tools
- **Swift:** Apple Swift 6.3.3
- **Terminal engine:** SwiftTerm 1.14.0
- **Scope:** terminal-tab sizing, overflow, selected reveal, pinned creation menu,
  and header-region ownership only

## Outcome

The Phase 2 implementation replaces the greedy tab header with a bounded
presentation-only layout. Fitting tabs remain 180 points wide. When needed, every
tab shrinks equally to the 120-point minimum; below that fit threshold the tabs stay
120 points wide and the viewport scrolls. The 240-point maximum remains an explicit
policy bound, while the current non-overflow presentation stops at the 180-point
preferred width.

The non-overflow viewport equals actual tab-content width. The existing local/relay
`+` menu is fixed immediately after the viewport and is never part of its scroll
content. At least 8 points separate the computed strip from the remaining header /
toolbar region. Creation, click activation, replacement selection on close, and
viewport resize request reveal of the selected stable tab ID. Initial and
tab/selection requests settle for 16 ms before one final scroll; initial reveal is
unanimated and only tab/selection changes may animate. Viewport-only requests use a
75 ms cancellation-coalesced unanimated debounce. Reduce Motion removes the
optional tab/selection animation.

This is not a Session Manager, SFTP, Remote File Browser, Settings, tab-reorder, or
toolbar-action change. No terminal session, PTY/process, SSH launch, close policy,
scrollback, terminal-surface identity, or local/relay action changed.

## Implementation boundary

```text
TerminalWorkspaceHeader (one width proposal)
  -> TerminalTabStripLayoutPolicy (pure metrics)
    -> exact-width TerminalTabStrip
      -> horizontal ScrollView / stable-ID LazyHStack
      -> pinned non-scrolling `+` menu
  -> independent remaining toolbar space
```

- `TerminalTabStripLayoutPolicy` calculates finite, nonnegative tab/content/
  viewport/strip/toolbar geometry in O(1) time for a tab count.
- `TerminalTabRevealRequest` contains ordered tab IDs, selected ID, and viewport
  width and exposes a target only when selection is still present.
- `TerminalWorkspaceHeader` owns the sole geometry proposal for this composition
  and assigns the strip its exact computed width.
- `TerminalTabStrip` renders one stable-ID lazy sequence, keeps `+` outside the
  viewport, bounds the close target at 28 points, and tail-truncates titles to one
  line.
- A pure reveal-scheduling policy selects the 16 ms render settle or 75 ms viewport
  debounce. The view sleeps before any scroll work, rejects cancellation or
  supersession, and performs exactly one final `scrollTo` per accepted request.
- `RootView` still keys the terminal surface by the selected session ID. The
  immutable tab state and all session/process owners are unchanged.

## Automated verification

### Repository verifier

Fresh documentation-task run:

```text
./scripts/verify.sh
Required repository files: OK
Test run with 143 tests in 23 suites passed after 7.203 seconds
XMterm verification: OK
```

Result: exit 0. The tab-strip layout suite contributed **17 tests in 1 suite**.
Those tests cover the 180/120/240 constants, exact thresholds, equal shrinking,
content-sized non-overflow, minimum-width overflow, zero/invalid inputs, pinned `+`
coordinates, toolbar reservation, valid/stale reveal targets, and viewport-width
request identity. Scheduling tests cover the 16 ms initial/tab-state settle,
tab-state-only animation, 75 ms unanimated viewport debounce, and invalid-target
suppression.

### Clean warning-treated builds

Final debug and release `swift build` commands used clean isolated `/tmp` scratch
directories with `-Xswiftc -warnings-as-errors`. Both exited 0 with no warnings:

- debug: `Build complete! (38.56s)`;
- release: `Build complete! (58.22s)`.

### Isolated coverage

The isolated `/tmp/xmterm-tab-polish-final-coverage` run passed **143 tests in 23
suites in 7.132 seconds**. The scoped Phase 1/2 gate plus
`ApplicationShortcutCoordinator` and the new `TerminalTabStripLayout` covered:

- **83.42% of lines** (3,008/3,606);
- **85.20% of functions**;
- **100% of lines and functions** in `TerminalTabStripLayout.swift`.

All first-party `Sources`, including declarative SwiftUI that the unit harness does
not invoke, covered **63.36% of lines** (3,242/5,117) and **66.14% of functions**.
The scoped number is not represented as whole-source coverage.

### Independent re-review

The final independent source/requirements re-review is **READY** for the
source/automated Phase 2 tab-strip slice. It confirmed the prior duplicate-scroll
finding is resolved: each accepted request performs one final scroll after its
tested schedule, the focused 17-test suite passes, and no new Critical, Important,
or Minor finding remains. This verdict is independent from the rendered observations
recorded below.

Pure tests establish numerical policy and reveal-target identity. The staged manual
pass separately establishes the observed SwiftUI layout, horizontal scrolling, and
selected-tab reveal behavior below; it does not establish physical trackpad
delivery, full keyboard traversal, actual VoiceOver traversal, or visual Reduce
Motion behavior.

## Requirement status

| Requirement | Status | Evidence and remaining boundary |
|---|---|---|
| `TAB-001` | **Partial** | The staged `+` menu exposed the existing local and fixed-relay actions. Local creation appended, selected, and revealed the new tab; relay creation was not invoked. Remembered-session selection and double-click creation are absent. |
| `TAB-002` | **Partial** | Rendered click activation, horizontal overflow, stable identity, and selected-tab reveal after create/activation/close/resize were observed. `Command-1`…`Command-9`, adjacent-tab shortcuts, drag reorder, reveal-after-reorder, and physical trackpad momentum remain deferred or unverified. |
| `TAB-003` | **Partial** | Closing the active final tab selected and revealed its previous neighbor without a visible layout jump. Middle-click close is absent. |
| `TAB-005` | **Partial** | Existing local/relay non-color lifecycle status is preserved; the broader connecting/connected/reconnecting/unread-output surface remains incomplete. |
| `APP-003` | **Partial** | The selected terminal remained visibly active after selection and close, and AX focus remained in the terminal/scrollbar region. Full Tab-key traversal across every control remains unverified; future session/file focus regions do not exist. |
| `A11Y-001` | **Partial** | Pointer activation opened the `+` menu and Escape dismissed it; source controls remain keyboard-capable. Full Tab-key traversal and broader product workflows remain incomplete or unverified. |
| `A11Y-002` | **Partial** | AX inspection found the `Terminal tabs` container, selected trait, tab status/help, close labels, `New terminal` label/hint/identifier, and a separate toolbar sibling. Actual VoiceOver traversal and the full terminal-grid model remain incomplete. |
| `A11Y-003` | **Partial** | Rendered tabs remained readable through equal shrink and overflow, and computer-use horizontal scrolling worked with `+` pinned. Physical trackpad momentum, middle-click, and drag reorder were not verified or are absent. |
| `MAC-001` | **Partial** | Pointer activation opened the unchanged menu with `New Local Terminal` and `Connect to Relay Host`, and Escape dismissed it. The relay action was inspected but not invoked; full toolbar/context/focused-region parity is outside this slice. |

`INTERACTIONS.md` normative clauses were not weakened or rewritten for this polish.

## Packaging and staged-app status

The controller ran:

```text
./script/build_and_run.sh --verify
```

Result: exit 0; the app was rebuilt, staged into `dist/XMterm.app`, ad-hoc signed,
launched, and remained running from the packaged executable. The final reviewed
bundle was then manually inspected:

- one tab was visually approximately 180 points wide, and two/three tabs kept a
  content-sized viewport with `+` immediately after the final tab and unused header
  space remaining outside the strip;
- six tabs visibly shrank equally; ten/eleven tabs entered horizontal overflow at
  readable widths while `+` remained pinned outside the viewport;
- computer-use horizontal scrolling moved the tab viewport in both directions
  without moving `+`;
- after scrolling to the trailing end, selecting the first tab revealed it;
  creating from that state appended, selected, and revealed the newest final tab;
- closing the active final tab selected and revealed its previous neighbor without
  a visible layout jump;
- narrowing the live window kept the active tab revealed and `+` pinned;
- pointer activation opened the unchanged `+` menu with `New Local Terminal` and
  `Connect to Relay Host`; Escape dismissed it;
- AX inspection exposed the `Terminal tabs` container, selected trait, per-tab
  status/help, close labels, `New terminal` label/hint/identifier, and a distinct
  toolbar sibling;
- interaction with eleven tabs remained qualitatively responsive. The app was
  returned to one local tab after the matrix.

The following observations were not performed and are not inferred:

- physical trackpad momentum behavior;
- rendered long-title tail truncation (a controlled title fixture did not change
  the tab title under the existing title/security policy);
- complete Tab-key traversal and focus restoration across every tab/menu control;
- actual VoiceOver auditory/traversal behavior;
- a system Reduce Motion toggle and its rendered animation behavior;
- invoking relay creation or checking its network/process/close flow;
- quantitative Instruments, CPU, memory, launch, input, or resize measurements.

Full XCUITest remains unavailable on this Command Line Tools-only host. The
specialized gaps remain unchecked in `docs/checklists/interaction-parity.md` and
keep the execution plan's manual step partially complete.

## Performance observations

Source inspection confirms one header geometry proposal, one pure O(1) sizing
calculation, a stable-ID `LazyHStack`, no per-tab measurement or preference loop,
and reveal requests keyed only to tab IDs, selection, and viewport width. Width-only
requests are cancellation-coalesced for 75 ms and unanimated; initial and
tab/selection requests settle for 16 ms, with animation permitted only for the
tab/selection change. Every accepted request performs one final scroll. Terminal
output does not participate in layout/reveal identity.

The eleven-tab manual matrix remained qualitatively responsive during create,
select, close, scrolling, and live resize. No CPU, resident-memory, cold-launch,
input-latency, resize-latency, Instruments, or quantitative long-tab-list
measurement was performed. Existing `PERFORMANCE.md` budgets remain unchanged; no
performance number is inferred from tests, source structure, or that qualitative
observation.

## Security observations

The change is limited to pure presentation policy, SwiftUI composition, tests, and
documentation. It adds no dependency and does not touch process launch, SSH argv,
credentials, terminal I/O, clipboard policy, output filtering, logging,
persistence, or remote behavior. Stable titles/status remain behind the existing
presentation policy. No secret, private host, private path, or credential was added.

## Deferred work and completion gate

- `Command-1` through `Command-9` and adjacent-tab keyboard navigation;
- drag reorder and reveal after reorder;
- rename, duplicate, reconnect, recently closed tabs, and restoration;
- Session Manager, SFTP, Remote File Browser, editor sync, Settings, and new toolbar
  actions;
- full XCUITest and the specialized manual gaps above.

Phase 3 Session Manager remains the next product phase. The independent re-review
and post-review verifier are complete, and the core staged layout/reveal matrix is
recorded. Execution Plan 0006 retains a partial manual step for the explicitly
unperformed accessibility, system-setting, input-device, relay, long-title, and
quantitative-performance checks.
