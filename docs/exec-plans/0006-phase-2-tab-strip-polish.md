# Phase 2 Browser-Like Tab Strip Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace XMterm's greedy terminal-tab header with a browser-like,
content-sized strip whose pinned `+` follows the visible tabs and whose active tab
is always revealed.

**Architecture:** Keep terminal/session state unchanged. Add a pure application-
presentation sizing policy, use it from a focused SwiftUI header wrapper, and keep
one stable-ID `LazyHStack` inside a horizontal `ScrollViewReader`; the `+` menu is a
non-scrolling sibling and remaining width is a separate toolbar region.

**Tech Stack:** Swift 6, SwiftUI on macOS 14+, Observation, Swift Testing, SwiftPM,
existing XMtermCore/XMtermTerminal boundaries.

**Plan status (2026-07-16):** Tasks 1–3 and the Task 4 documentation/automated
gate are complete. The packaged app passed the core rendered layout, overflow,
selected-reveal, close, resize, menu, and AX-tree inspection. The final independent
re-review is READY and the post-review 143-test verifier passes. Physical trackpad
momentum, long-title rendering, full keyboard traversal, actual VoiceOver, Reduce
Motion, relay invocation, and quantitative performance inspection remain open, so
the manual step is partially complete.

## Global Constraints

- This is Phase 2 UI polish only: no Session Manager, SFTP, Remote File Browser,
  Settings, tab drag/reorder, or unrelated toolbar work.
- Preferred tab width is exactly 180 pt, minimum is 120 pt, and maximum is 240 pt.
- Non-overflow viewports equal actual tab-content width and never greedily expand.
- Overflow begins before tabs would fall below 120 pt; the viewport scrolls while
  `+` remains pinned directly outside it.
- UI code stays on `MainActor`; terminal/process/session ownership is unchanged.
- Preserve Phase 1 and Phase 2 input, process, SSH, close, scrollback, selection,
  focus, and accessibility behavior.
- No new dependency or ADR is required because the implementation uses native
  SwiftUI and the existing application layer.
- Requirement IDs: `TAB-001`, `TAB-002`, `TAB-003`, `TAB-005`, `APP-003`,
  `A11Y-001`, `A11Y-002`, `A11Y-003`, and `MAC-001`.

---

## Acceptance criteria

1. With preferred-width tabs that fit, layout is
   `[actual-width tabs][+][remaining header space]`.
2. Tabs shrink equally from 180 pt toward 120 pt as header space narrows.
3. Below the 120-pt fit threshold, layout is
   `[scrollable minimum-width tab viewport][+][remaining toolbar space]`.
4. `+` is outside scroll content, always visible, and opens the existing local/relay
   menu without changing its actions.
5. Creation appends and selects a tab immediately before `+`, then reveals it.
6. Selection, closure, and resize reveal the resulting active tab.
7. Long titles remain one line and truncate at the tail.
8. Reduce Motion removes layout/reveal animation but not behavior.
9. Stable IDs preserve terminal views and make later reordering possible without
   implementing it now.

## File map

- Create `Sources/XMtermApp/TerminalTabStripLayout.swift`: pure constants, sizing
  metrics/calculation, and selected-tab reveal request.
- Create `Sources/XMtermApp/TerminalWorkspaceHeader.swift`: header-width owner that
  places a fixed-width tab strip before independent remaining toolbar space.
- Modify `Sources/XMtermApp/TerminalTabStrip.swift`: render bounded tab cells in one
  lazy horizontal viewport and keep `+` outside it.
- Modify `Sources/XMtermApp/RootView.swift`: compose `TerminalWorkspaceHeader` in
  place of the greedy strip.
- Create `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`: sizing, overflow,
  pinned-button, toolbar-boundary, and reveal-target tests.
- Modify `Tests/XMtermCoreTests/TerminalDomainTests.swift`: retain explicit create,
  select, close, and stable-ID assertions as regression evidence if the focused
  app tests reveal a missing state assertion.
- Update `ARCHITECTURE.md`, `INTERACTIONS.md`, `PLANS.md`, `TESTING.md`,
  `docs/design-docs/index.md`, `docs/design-docs/session-tabs-ux.md`,
  `docs/design-docs/macos-app-behavior.md`,
  `docs/checklists/interaction-parity.md`, and this plan.
- Create `docs/audits/0004-phase-2-tab-strip-polish-evidence.md` with automated and
  manual evidence plus honest gaps.

## Architecture impact

The change introduces only a pure presentation policy and one header composition
boundary. `TerminalWorkspaceStore`, `TerminalTabsState`, `TerminalSession`, the PTY,
and SSH launch paths do not change. Toolbar space becomes structurally distinct from
`TerminalTabStrip`, so future toolbar actions do not need to move the `+` menu.

## Performance impact

One geometry proposal drives one O(1) sizing calculation. A stable-ID `LazyHStack`
replaces the eager `HStack`; there are no per-tab measurements, preference cycles,
polling loops, or terminal-output-driven scroll requests. Reveal work is keyed only
to tab IDs, selection, and viewport width.

## Security impact

None. The change does not touch process launch, SSH arguments, credentials,
terminal input/output, clipboard policy, logging, or persistence. Existing icon
labels and lifecycle status remain sanitized by `TerminalPresentationPolicy`.

## UX impact

The pointer target moves next to the final visible tab, tab widths remain readable,
overflow becomes horizontally navigable, active/new tabs remain visible, long
titles truncate, and Reduce Motion is respected. Existing menu actions, shortcuts,
close confirmation, terminal focus, and local/relay distinctions remain intact.

## Edge cases

- zero tabs: viewport width is zero and `+` occupies the leading strip position;
- one/few tabs in a wide window: each remains 180 pt and unused width stays outside;
- exact preferred/minimum thresholds: no off-by-one overflow transition;
- transient zero/nonfinite width: bounded zero-width viewport, no negative frames;
- selected ID absent from the current tab IDs: no scroll target;
- closing first, middle, last, and final tabs: replacement selection remains the
  domain policy's result and `+` moves once;
- repeated creation/selection during animation: latest keyed reveal wins;
- window narrowing/widening: selected tab is re-revealed after metrics change;
- long local or relay title: icon and close button stay usable while text truncates;
- Reduce Motion: scroll/layout changes occur without animation.

## Risks and mitigations

- **SwiftUI scroll timing:** a pure policy gives initial and tab/selection requests
  one 16 ms render settle and viewport-only requests a 75 ms debounce. Sleep before
  any scroll work, reject cancellation/supersession, and issue exactly one final
  `scrollTo`; rendered outcome still requires manual/UI evidence.
- **Resize churn:** cancellation-coalesce viewport-only changes for 75 ms and keep
  their final scroll unanimated so live resize does not scroll once per proposal.
- **Greedy geometry returning:** make `TerminalWorkspaceHeader` assign the computed
  `stripWidth`; do not give `TerminalTabStrip` a flexible max-width frame.
- **Layout feedback/thrashing:** use fixed constants and parent width only; do not
  measure individual cells.
- **Tab recreation:** retain `ForEach(tabs)` with `TerminalTab.ID` and do not key
  views by index or title.
- **Toolbar overlap:** calculate a toolbar boundary and leave a fixed separation
  after the tab strip; verify reserved toolbar width in unit tests.
- **Animation glitches:** animate only tab-list/selection changes with a short
  ease-out. Initial and viewport-only requests remain unanimated, Reduce Motion
  removes the optional tab-state animation, and no insertion/removal effect exists.

## Remaining work outside this plan

Tab reorder, `Command-1` through `Command-9` selection, `Command-Shift-[` /
`Command-Shift-]` adjacent-tab navigation, rename, duplicate, reconnect, recently
closed tabs, Session Manager, SFTP, Remote File Browser, Settings, new toolbar
actions, and full XCUITest remain deferred. `TAB-002` stays Partial; these gaps are
not prerequisites for this polish slice.

---

### Task 1: Pure tab-strip sizing policy

**Status:** Complete; all six steps passed and are recorded in the Task 1 report.

**Files:**
- Create: `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`
- Create: `Sources/XMtermApp/TerminalTabStripLayout.swift`

**Interfaces:**
- Consumes: finite header width, tab count, and optional reserved toolbar width.
- Produces: `TerminalTabStripLayoutPolicy.metrics(availableWidth:tabCount:reservedToolbarWidth:) -> TerminalTabStripLayoutMetrics`.

- [x] **Step 1: Write failing sizing tests**

Add Swift Testing cases that assert the exact constants and representative geometry:

```swift
@Suite("Terminal tab strip layout")
struct TerminalTabStripLayoutTests {
    private let policy = TerminalTabStripLayoutPolicy()

    @Test("[TAB-002] non-overflow viewport uses actual preferred-width content")
    func nonOverflowIsContentSized() {
        let metrics = policy.metrics(availableWidth: 1_000, tabCount: 3)
        #expect(policy.minimumTabWidth == 120)
        #expect(policy.preferredTabWidth == 180)
        #expect(policy.maximumTabWidth == 240)
        #expect(metrics.tabWidth == 180)
        #expect(metrics.tabContentWidth == 548)
        #expect(metrics.viewportWidth == 548)
        #expect(!metrics.requiresHorizontalScrolling)
    }

    @Test("[TAB-002] tabs shrink equally before minimum-width overflow")
    func tabsShrinkEqually() {
        let metrics = policy.metrics(availableWidth: 500, tabCount: 3)
        #expect(metrics.tabWidth >= 120)
        #expect(metrics.tabWidth < 180)
        #expect(metrics.viewportWidth == metrics.tabContentWidth)
        #expect(!metrics.requiresHorizontalScrolling)
    }

    @Test("[TAB-002, A11Y-003] overflow holds the readable minimum width")
    func overflowUsesMinimumWidth() {
        let metrics = policy.metrics(availableWidth: 360, tabCount: 4)
        #expect(metrics.tabWidth == 120)
        #expect(metrics.tabContentWidth > metrics.viewportWidth)
        #expect(metrics.requiresHorizontalScrolling)
    }
}
```

- [x] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
swift test --filter TerminalTabStripLayoutTests
```

Expected: compile failure because `TerminalTabStripLayoutPolicy` and metrics do not
exist.

- [x] **Step 3: Implement the minimal pure policy**

Create internal immutable value types with exact public-to-test constants:

```swift
import CoreGraphics

struct TerminalTabStripLayoutMetrics: Equatable, Sendable {
    let tabWidth: CGFloat
    let tabContentWidth: CGFloat
    let viewportWidth: CGFloat
    let stripWidth: CGFloat
    let newTabButtonMinX: CGFloat
    let toolbarRegionMinX: CGFloat
    let requiresHorizontalScrolling: Bool
}

struct TerminalTabStripLayoutPolicy: Equatable, Sendable {
    let minimumTabWidth: CGFloat = 120
    let preferredTabWidth: CGFloat = 180
    let maximumTabWidth: CGFloat = 240
    let interTabSpacing: CGFloat = 4
    let leadingPadding: CGFloat = 8
    let newTabButtonGap: CGFloat = 4
    let newTabButtonWidth: CGFloat = 28
    let toolbarSeparation: CGFloat = 8

    func metrics(
        availableWidth: CGFloat,
        tabCount: Int,
        reservedToolbarWidth: CGFloat = 0
    ) -> TerminalTabStripLayoutMetrics {
        // Sanitize widths, reserve toolbar/separation, use preferred content when
        // it fits, shrink equally to minimum, then keep minimum and scroll.
    }
}
```

Use `gap = tabCount > 0 ? newTabButtonGap : 0`, include
`max(0, tabCount - 1) * interTabSpacing` in content widths, and make
`toolbarRegionMinX` exactly `stripWidth + toolbarSeparation` when space permits.

- [x] **Step 4: Extend tests for pinned `+`, toolbar separation, zero/invalid width, and thresholds**

Add assertions that:

```swift
#expect(metrics.newTabButtonMinX == policy.leadingPadding + metrics.viewportWidth + policy.newTabButtonGap)
#expect(metrics.stripWidth == metrics.newTabButtonMinX + policy.newTabButtonWidth)
#expect(metrics.toolbarRegionMinX >= metrics.stripWidth + policy.toolbarSeparation)
```

Verify zero tabs omit the gap, reserved toolbar width never overlaps the strip,
nonfinite widths yield bounded metrics, and exact minimum/preferred thresholds do
not oscillate. For three tabs, assert the exact 596-point preferred-fit boundary,
416-point minimum-fit boundary, and overflow at 415 points. Verify widths below the
fixed 44-point leading/button/separation requirement never produce negative or
nonfinite frames.

- [x] **Step 5: Run focused tests and confirm GREEN**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: all layout-policy tests pass.

- [x] **Step 6: Review the task diff**

Run `git diff -- Sources/XMtermApp/TerminalTabStripLayout.swift Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift` when tracked; otherwise inspect both files directly. Do not create a partial parent-repository commit because `XMterm-starter` is currently untracked under `/Applications/codes`.

---

### Task 2: Stable active-tab reveal request

**Status:** Complete; all five steps passed and are recorded in the Task 2 report.

**Files:**
- Modify: `Sources/XMtermApp/TerminalTabStripLayout.swift`
- Modify: `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`

**Interfaces:**
- Consumes: current ordered tab IDs, selected ID, and viewport width.
- Produces: hashable `TerminalTabRevealRequest` with a valid optional `targetTabID`.

- [x] **Step 1: Write failing reveal-target tests**

```swift
@Test("[TAB-001, TAB-002] creation reveals the selected appended tab")
func creationTargetsAppendedSelection() {
    let request = TerminalTabRevealRequest(
        tabIDs: [firstID, secondID, thirdID],
        selectedTabID: thirdID,
        viewportWidth: 300
    )
    #expect(request.targetTabID == thirdID)
}

@Test("[TAB-002, TAB-003] selection and replacement selection remain revealable")
func selectionTargetsOnlyAContainedID() {
    #expect(validRequest.targetTabID == secondID)
    #expect(staleRequest.targetTabID == nil)
}
```

Also assert that changing viewport width changes request identity so resize can
reveal the active tab again.

- [x] **Step 2: Run focused tests and confirm RED**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: compile failure because `TerminalTabRevealRequest` does not exist.

- [x] **Step 3: Implement the immutable request**

```swift
struct TerminalTabRevealRequest: Equatable, Hashable, Sendable {
    let tabIDs: [TerminalTab.ID]
    let selectedTabID: TerminalTab.ID?
    let viewportWidth: CGFloat

    var targetTabID: TerminalTab.ID? {
        guard let selectedTabID, tabIDs.contains(selectedTabID) else { return nil }
        return selectedTabID
    }
}
```

Import `XMtermCore` in the policy file; do not move selection state out of
`TerminalTabsState`.

- [x] **Step 4: Run focused tests and confirm GREEN**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: sizing and reveal tests pass.

- [x] **Step 5: Re-run immutable tab-state regression tests**

Run `swift test --filter TerminalTabsStateTests`.

Expected: creation selects the appended ID; closure preserves or replaces selection
exactly as before.

---

### Task 3: Compose the non-greedy SwiftUI header and scrolling strip

**Status:** Complete; all eight implementation/automated steps passed. Rendered
outcome remains a Task 4 evidence item rather than an inferred Task 3 claim.

**Files:**
- Create: `Sources/XMtermApp/TerminalWorkspaceHeader.swift`
- Modify: `Sources/XMtermApp/TerminalTabStrip.swift`
- Modify: `Sources/XMtermApp/RootView.swift`
- Modify: `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`

**Interfaces:**
- Consumes: existing tab values and existing select/close/create actions.
- Produces: fixed computed strip width followed by independent remaining header
  space; tab viewport is the only scrollable child.

- [x] **Step 1: Complete the header-boundary acceptance harness before view changes**

Use policy metrics with a reserved toolbar width and assert:

```swift
let metrics = policy.metrics(
    availableWidth: 900,
    tabCount: 8,
    reservedToolbarWidth: 120
)
#expect(metrics.stripWidth + policy.toolbarSeparation <= 780)
#expect(metrics.toolbarRegionMinX <= 780)
#expect(metrics.newTabButtonMinX >= policy.leadingPadding + metrics.viewportWidth)
```

This assertion belongs in the policy test written before the declarative view is
changed. It must be GREEN after Task 1 and acts as the numerical acceptance harness
for the header composition below.

- [x] **Step 2: Run the focused acceptance harness**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: the sizing, overflow, pinned-button, and toolbar-boundary tests pass before
the view begins consuming those metrics. If any assertion fails, fix the policy
before changing SwiftUI composition.

- [x] **Step 3: Create the focused header owner**

`TerminalWorkspaceHeader` uses one `GeometryReader`, calculates metrics once, gives
`TerminalTabStrip` exactly `metrics.stripWidth`, and places a flexible spacer after
it with at least `toolbarSeparation`. It retains the 38-point bar height and `.bar`
background. It adds no toolbar controls.

```swift
GeometryReader { geometry in
    let metrics = layoutPolicy.metrics(
        availableWidth: geometry.size.width,
        tabCount: tabs.count
    )
    HStack(spacing: 0) {
        TerminalTabStrip(/* existing actions */, metrics: metrics)
            .frame(width: metrics.stripWidth, alignment: .leading)
        Spacer(minLength: layoutPolicy.toolbarSeparation)
    }
}
.frame(height: 38)
.background(.bar)
```

- [x] **Step 4: Refactor the strip around one lazy viewport and pinned menu**

Replace the eager inner stack with:

```swift
ScrollViewReader { proxy in
    ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: layoutPolicy.interTabSpacing) {
            ForEach(tabs) { tab in
                terminalTab(tab)
                    .frame(width: metrics.tabWidth)
                    .id(tab.id)
            }
        }
    }
    .frame(width: metrics.viewportWidth)
    .task(id: revealRequest) {
        await revealSelectedTab(using: proxy)
    }
}
```

The completed implementation derives a pure schedule from the previous/current
request: 16 ms for initial or tab/selection state, 75 ms for viewport-only changes,
and no schedule for an invalid selected target. It sleeps before scroll work, then
performs exactly one cancellation/generation-guarded final `scrollTo`. Initial and
viewport-only requests are unanimated; only tab/selection changes may animate.

Place the existing `+` `Menu` after the viewport with the policy gap and fixed
28-point target. Remove the old scroll-content horizontal padding and menu trailing
padding, render `leadingPadding` outside the viewport, omit the gap for zero tabs,
and constrain the `Menu` itself rather than only its image. Keep its existing
actions, availability, help, label, and hint;
add `.accessibilityIdentifier("terminal-tab-strip-new-terminal")`. The menu must
not be inside `ScrollView` or `LazyHStack`.

- [x] **Step 5: Bound tab-cell content and animations**

Give the selection button flexible remaining width and keep the close button fixed.
Apply `.lineLimit(1)` and `.truncationMode(.tail)` to the title. Use a short optional
ease-out animation keyed to ordered tab IDs/selection and return `nil` when
`accessibilityReduceMotion` is true. Viewport-only reveal during live resize uses a
75 ms cancellation-coalesced debounce and remains unanimated. Do not add
transitions or key the reader, scroll view, header, or tab cells by metrics, count,
index, or title.

- [x] **Step 6: Switch RootView to the header owner**

Replace only the existing `TerminalTabStrip(...)` call with
`TerminalWorkspaceHeader(...)`, passing the same store values and closures. Keep
the divider, terminal surface, alerts, commands, and lifecycle callbacks unchanged.

- [x] **Step 7: Build and run focused tests**

Run:

```bash
swift test --filter TerminalTabStripLayoutTests
swift build
```

Expected: focused tests pass and the app compiles without Swift 6 concurrency or
SwiftUI availability warnings.

- [x] **Step 8: Run app-layer regression tests**

Run:

```bash
swift test --filter TerminalWorkspaceCommandTests
swift test --filter TerminalWorkspaceStoreTests
swift test --filter TerminalWorkspaceStoreSSHTests
```

Expected: creation, selection, close, SSH isolation, and command routing pass
unchanged.

---

### Task 4: Documentation, manual verification, and full regression gate

**Status:** In progress. Documentation, the 143-test verifier, isolated coverage,
warning-clean debug/release builds, packaged launch, READY independent re-review,
post-review verifier, and core rendered/manual inspection are recorded in Audit
0004. Specialized accessibility, input-device, relay, title, and quantitative
performance checks remain open.

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

- [x] **Step 1: Update architecture and interaction status**

Document the pure sizing boundary, non-greedy viewport, pinned sibling `+`, stable
lazy tab sequence, active reveal triggers, Reduce Motion behavior, and toolbar
separation. Mark the overflow/reveal subset of `TAB-002` implemented while keeping
drag reorder and shortcut gaps partial.

- [x] **Step 2: Update design/index/status documents**

Add `tab-strip-redesign.md` to the design index; update the session-tab and macOS
behavior documents plus `PLANS.md` with a completed Phase 2 polish slice. Keep
Phase 3 Session Manager as the next product phase.

- [x] **Step 3: Update testing and parity documentation**

Record deterministic policy/reveal tests and add manual checklist rows for pinned
`+`, trackpad overflow, active reveal, long-title truncation, keyboard focus,
VoiceOver, Reduce Motion, and local/relay regression.

- [x] **Step 4: Run canonical verification**

Run `./scripts/verify.sh`.

Expected: repository validation and every existing/new test suite pass.

- [x] **Step 5: Run warning-clean debug and release builds**

Run clean SwiftPM debug and release builds with warnings treated as errors using
scratch paths under `/tmp`. Expected: both builds pass with no warnings.

- [ ] **Step 6: Stage and manually inspect the native app (partially complete)**

**Current evidence:** `./script/build_and_run.sh --verify` exited 0. The staged app
was inspected with one, two/three, six, and ten/eleven tabs: content-sized preferred
tabs, equal shrink, readable horizontal overflow, pinned `+`, two-way computer-use
scrolling, selected reveal after activation/create/close/resize, pointer menu and
Escape dismissal, and the expected AX tab/menu/toolbar structure were observed.
The app was returned to one local tab. Physical trackpad momentum, long-title
rendering, full Tab-key traversal, actual VoiceOver, Reduce Motion, relay invocation,
and quantitative performance checks were not performed, so this step remains open.

Run `./script/build_and_run.sh --verify`, then verify:

1. one to three tabs stay 180 pt and `+` hugs the final tab;
2. repeated creation shrinks tabs equally to 120 pt, then scrolls;
3. `+` remains visible and opens the unchanged local/relay menu;
4. the newest/selected tab is revealed, including after resize and closure;
5. long titles truncate to one line and close targets remain usable;
6. pointer, keyboard focus, accessibility labels, and Reduce Motion behave;
7. local and relay tabs retain Phase 1/2 focus, close, process, and isolation
   behavior.

- [x] **Step 7: Record honest evidence and gaps**

Write exact automated counts/build outcomes and only the manual observations that
were performed. Record XCUITest or VoiceOver gaps explicitly rather than inferring
them.

- [x] **Step 8: Run final review and verification**

**Current evidence:** the final independent re-review is READY for the
source/automated slice, the focused suite passes 17 tests in 1 suite, and the
post-review canonical verifier passes 143 tests in 23 suites. The core rendered
matrix is also complete; this does not close Step 6's explicitly unperformed
specialized checks.

Dispatch independent code/requirements review, address all critical/high findings,
then rerun `./scripts/verify.sh`. Mark this plan complete only after the final run
passes.
