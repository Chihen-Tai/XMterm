# Task 3 Report: Non-Greedy SwiftUI Header and Scrolling Tab Strip

## Status

Task 3 implementation and automated verification are complete. The SwiftUI header
now owns the width proposal, the tab strip consumes the pure policy metrics without
growing greedily, and the `+` menu remains a pinned sibling of the only horizontal
scroll viewport. The independent post-fix review is approved with no Critical,
Important, or Minor findings.

Manual runtime verification was not performed in this task and is not inferred from
the policy tests. It remains explicitly pending for Task 4.

## Requirements and scope

Applicable requirements are `TAB-001`, `TAB-002`, `TAB-003`, `TAB-005`,
`APP-003`, `A11Y-001`, `A11Y-002`, `A11Y-003`, and `MAC-001`.

Implemented scope is limited to the approved Phase 2 tab-strip polish. No Session
Manager, SFTP, Remote File Browser, Settings, drag reorder, toolbar action,
session/process behavior, SSH behavior, or terminal-surface identity changed.

## Files created and modified

Created:

- `Sources/XMtermApp/TerminalWorkspaceHeader.swift`
- `.superpowers/sdd/task-3-report.md`

Modified:

- `Sources/XMtermApp/TerminalTabStrip.swift`
- `Sources/XMtermApp/RootView.swift`
- `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`

The pure sizing/reveal implementation in
`Sources/XMtermApp/TerminalTabStripLayout.swift` was not changed.

## Implemented behavior

### Header ownership

- `TerminalWorkspaceHeader` is the sole owner of one `GeometryReader` for this
  composition.
- It calculates one `TerminalTabStripLayoutMetrics` value from the header proposal,
  assigns `TerminalTabStrip` exactly `metrics.stripWidth`, and leaves a flexible
  sibling region with at least the policy's 8-point toolbar separation.
- The header retains the existing 38-point height and `.bar` background and adds no
  toolbar control.

### Exact strip composition

- The 8-point leading inset is a fixed sibling outside the scroll viewport.
- The viewport is one horizontal `ScrollView` containing one stable-ID
  `LazyHStack` with policy spacing and fixed `metrics.tabWidth` cells.
- The viewport receives exactly `metrics.viewportWidth` and has no greedy
  max-width frame.
- The conditional 4-point gap is rendered only when tabs exist.
- The existing new-terminal `Menu` is outside both the `ScrollView` and
  `LazyHStack`, and the `Menu` itself is fixed to the policy's 28-point target.
- The old scroll-content horizontal padding and menu trailing padding are gone.

### Reveal and animation

- Reveal work is keyed by `TerminalTabRevealRequest`, so ordered tab IDs,
  selection, and viewport-width changes cancel and supersede stale `.task` work.
- A generation check provides an additional latest-request guard, including when
  selection becomes absent.
- The reveal makes two guarded `scrollTo` attempts: one after yielding for lazy
  registration and one after a 16 ms coalescing interval. Rapid obsolete requests
  cannot complete either attempt after cancellation/generation change.
- Only the `scrollTo` calls receive the optional 0.15-second ease-out animation.
  The animation decision is keyed to ordered IDs and selection. Width-only resize
  requests use no animation, and Reduce Motion makes all explicit reveal animation
  `nil`.
- No transition or broad descendant animation was added, and no reader, scroll
  view, header, or tab cell is keyed by metrics, count, index, or title.

### Tab cells and accessibility

- Each selection button consumes flexible remaining width while the close button
  remains a fixed 28-point target.
- Titles are one line with tail truncation, preserving status and close controls at
  the 120-point minimum tab width.
- The `+` menu preserves its actions, availability, help, accessibility label, and
  hint, and now has identifier `terminal-tab-strip-new-terminal`.
- Existing tab status text, close labels, and stable `TerminalTab.ID` identity are
  preserved.

### Root integration

- `RootView` replaces only the old `TerminalTabStrip` call with
  `TerminalWorkspaceHeader` and passes the same store values/actions.
- The divider, terminal surface and its `.id(session.id)`, alerts, commands,
  lifecycle callbacks, and process/session code are unchanged.

## Acceptance-harness evidence

Before changing SwiftUI production code, the reserved-toolbar policy test was
completed with the brief's explicit assertions:

- `stripWidth + toolbarSeparation <= 780`;
- `toolbarRegionMinX <= 780`;
- the new-terminal minX is at or after leading padding plus viewport width.

The focused suite was then run and remained green, as the Task 3 brief requires for
this already-implemented pure policy. This Task intentionally consumes a pre-green
numerical acceptance harness; it does not claim a new RED cycle for declarative
SwiftUI rendering, which remains outside the current XCUITest/line-coverage gate.

## Commands and results

This Command Line Tools host requires the repository-documented Swift Testing
framework/runtime flags on focused `swift test` commands. Those flags were used for
every focused run below.

### Pre-edit acceptance harness

```bash
swift test --filter TerminalTabStripLayoutTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Result: exit 0; **13 tests in 1 suite passed** before SwiftUI source changes.

### Final focused layout/reveal suite

The identical command was rerun after the review fixes.

Result: exit 0; **13 tests in 1 suite passed**.

### Required build

```bash
swift build
```

Result: exit 0; debug build completed without Swift 6 concurrency, SwiftUI
availability, or other compiler warnings.

### App-layer regressions

The same documented framework/runtime flags were appended to each command:

```bash
swift test --filter TerminalWorkspaceCommandTests
swift test --filter TerminalWorkspaceStoreTests
swift test --filter TerminalWorkspaceStoreSSHTests
```

Final results after review fixes:

- `TerminalWorkspaceCommandTests`: exit 0; **2 tests in 1 suite passed**.
- `TerminalWorkspaceStoreTests`: exit 0; **13 tests in 1 suite passed**.
- `TerminalWorkspaceStoreSSHTests`: exit 0; **6 tests in 1 suite passed**.

### Canonical verifier

```bash
./scripts/verify.sh
```

Fresh final result after all source/review changes: exit 0; **139 tests in 23
suites passed** and `XMterm verification: OK`.

## Independent review

The first read-only review found two Important issues:

1. a broad `.animation(..., value:)` could animate unrelated descendant
   insertion/removal/chrome changes;
2. one delayed `scrollTo` attempt was weaker than the binding timing guardrail.

The broad animation was removed, and reveal was changed to two generation- and
cancellation-guarded attempts with animation scoped only to `scrollTo`. The same
reviewer then re-read the current code and approved it with no Critical, Important,
or Minor findings. The reviewer explicitly confirmed that actual reveal, focus
restoration, and accessibility order remain manual-runtime evidence.

## Manual verification status

The app was not launched or manipulated during Task 3. The following are therefore
pending and must not be reported as observed behavior yet:

- one to three tabs retaining preferred width and `+` hugging the final tab;
- shrink-to-120 and trackpad horizontal overflow with pinned `+`;
- actual selected/new/replacement reveal after rapid create/select/close and live
  resize;
- keyboard focus restoration after closing the focused tab;
- long-title truncation and close-target usability at 120 points;
- VoiceOver order/labels and keyboard access to the `+` menu;
- Reduce Motion behavior;
- local/relay coexistence, close, focus, process, and isolation behavior in the
  staged GUI.

These checks belong to the Task 4 staged-app/manual evidence pass under the binding
guardrails.

## Self-review

- Re-read the task brief and all nine integration guardrails against the final
  source.
- Confirmed the rendered fixed widths sum to policy geometry: leading padding,
  viewport, conditional gap, and fixed menu.
- Confirmed there is no scroll-content padding, menu trailing padding, greedy
  viewport max width, per-tab measurement, or extra `GeometryReader`.
- Confirmed `ForEach` and `.id` use stable `TerminalTab.ID`, and terminal-surface
  identity in `RootView` is unchanged.
- Confirmed lifecycle-only tab changes do not change reveal request identity.
- Confirmed width-only changes are briefly coalesced and never explicitly animated.
- Confirmed Reduce Motion makes both guarded reveal attempts unanimated.
- Confirmed menu actions, disabled state, label, hint, help, focusable control type,
  and fixed target are preserved.
- Confirmed no forbidden product surface or session/SSH/process behavior was added.
- A source/test modification-time scope check found only the three planned source
  files and the planned focused test file changed since Task 2.
- The parent repository still reports `XMterm-starter/` as untracked. No stage,
  commit, branch, push, or parent-repository mutation was performed.

## Concerns and explicit boundaries

- Declarative SwiftUI scroll position and focus/accessibility traversal are not
  observable through the current pure test harness. The two-phase reveal is
  cancellation-safe and independently reviewed, but its rendered outcome remains a
  required manual check rather than an automated claim.
- The 16 ms second attempt is deliberately brief so live resize is coalesced. If
  staged runtime evidence finds unusually delayed lazy registration, adjust the
  reveal coordination under a reproduced manual/UI test rather than treating the
  current policy tests as proof.
- On this Command Line Tools-only host, literal focused `swift test` commands still
  need the documented framework/runtime flags; `./scripts/verify.sh` supplies the
  repository-wide harness automatically.
- The pre-existing sizing-policy boundary below 36 points remains unchanged: the
  fixed 8-point leading inset plus 28-point menu cannot physically fit in a smaller
  proposal. Returned viewport metrics remain finite and nonnegative.
