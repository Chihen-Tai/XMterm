# XMterm Phase 2 Tab-Strip Redesign — Final Source Review

## Review basis

Reviewed the engineering and interaction contracts, approved design, Execution Plan
0006, the complete tab-strip/header/root implementation, focused layout tests, and
the relevant workspace selection/close/focus path. Fresh canonical verification was
also run during this review: `./scripts/verify.sh` exited 0 with **139 tests in 23
suites**.

This is a source/automated review. The locked host prevented rendered macOS,
trackpad, keyboard-focus, VoiceOver, and Reduce Motion inspection; Audit 0004 and the
interaction checklist correctly keep those observations pending.

## Strengths

- `Sources/XMtermApp/TerminalTabStripLayout.swift:25-109` implements the approved
  width policy cleanly: 180-point preferred tabs, equal shrink to 120 points, then
  minimum-width overflow. The 596/416/415-point three-tab boundaries are correct,
  non-overflow viewports remain content-sized, and invalid widths cannot produce a
  negative viewport.
- `Sources/XMtermApp/TerminalWorkspaceHeader.swift:16-36` gives the strip an exact
  computed width and places an actual sibling spacer after it. The current 8-point
  toolbar separation is therefore real rather than only a policy-test assertion.
- `Sources/XMtermApp/TerminalTabStrip.swift:20-48` keeps the `+` menu outside both the
  `ScrollView` and `LazyHStack`, immediately after the viewport. The flat
  `ForEach(tabs)` sequence and explicit stable IDs are suitable for future reorder
  work without implementing reorder now.
- `Sources/XMtermApp/TerminalTabStrip.swift:121-177` protects the fixed close target,
  tail-truncates titles to one line, retains textual lifecycle status, and exposes
  selected state and useful accessibility labels. The new-terminal menu keeps its
  actions/availability and adds a stable accessibility identifier.
- `Sources/XMtermApp/RootView.swift:20-32` is a narrow integration: the same store
  values and actions are passed through, while terminal-surface identity, alerts,
  commands, session ownership, PTY/SSH behavior, and close policy remain unchanged.
- The tests are strong for what pure tests can prove: exact sizing, thresholds,
  overflow state, pinned-control coordinates, toolbar reservation arithmetic,
  invalid inputs, and reveal-target identity. Existing domain/app suites provide
  useful Phase 1/2 selection, close, process, and isolation regression coverage.

## Original findings

### Critical

None.

### Important

1. **Reveal animation is restarted before the first animation can finish, and the
   resize path performs redundant scroll work.**

   `Sources/XMtermApp/TerminalTabStrip.swift:94-118` calls an optionally animated
   `scrollTo` at lines 105-107, sleeps only 16 ms, and calls the same 150 ms animated
   operation again at lines 116-118. The second transaction begins long before the
   first can complete, so create/select/close reveal can restart or jitter. For
   width-only requests the two calls are unanimated but still duplicate work. In
   addition, the raw viewport `CGFloat` is part of the task identity at
   `Sources/XMtermApp/TerminalTabStrip.swift:53-58`, so live resize can start a task
   for every width proposal; cancellation prevents late stale completion but does
   not coalesce a first attempt that already ran.

   **Fix:** make each accepted request perform one final `scrollTo`. Delay/debounce
   before that call so `.task(id:)` cancellation naturally coalesces width-only
   resize requests; animate only tab-list/selection requests. If a lazy-registration
   fallback is retained, do not universally start a second full animation. Extract
   the request/reason scheduling decision into a testable policy and add a rendered
   integration test when the Xcode UI harness is available.

### Minor

1. **The reveal tests' display names claim more behavior than their bodies prove.**

   `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift:10-21` does not create a
   tab or invoke scrolling; it only checks that a contained selected ID becomes a
   target. Likewise, `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift:24-41`
   does not close a tab or exercise replacement selection. TESTING.md and Audit 0004
   describe this boundary honestly, but the test names themselves can be mistaken
   for rendered reveal coverage.

   **Fix:** rename them to “reveal request targets the appended selected ID” and
   “reveal request accepts only a contained selected ID.” Keep actual create/close
   state assertions in the domain suites and add UI/integration coverage for
   `ScrollViewReader` behavior when available.

## Recommendations

- Track, but do not gate this change on, the pre-existing focus helper at
  `Sources/XMtermApp/TerminalWorkspaceStore.swift:528-532`. It does not cancel or
  revalidate yielded focus tasks after rapid superseding selection. That code was
  not changed by the tab-strip redesign, and review found no Phase 1/2 focus
  regression attributable to this slice. A later hardening change should cancel the
  previous task or guard the current selected/session ID before calling `focus()`.
- No change is required for the policy's sub-chrome fixed-width result at
  `Sources/XMtermApp/TerminalTabStripLayout.swift:42-68`. The app enforces a
  960-point minimum window at `Sources/XMtermApp/XMtermApp.swift:10-16`, while the
  sidebar tops out at 240 points at `Sources/XMtermApp/RootView.swift:10-18`; the
  36/40-point fixed strip edge is therefore not reachable in a steady-state product
  layout. Optional clipping would only harden transient framework proposals.
- Keep the current toolbar separation, but when real toolbar controls are added,
  thread their reservation into `TerminalWorkspaceHeader`; today
  `reservedToolbarWidth` is exercised only by the pure policy tests and the
  production header passes the default zero reservation.
- Add the new design, Execution Plan 0006, and Audit 0004 to
  `scripts/verify.sh:6-41` so the canonical “Required repository files” gate cannot
  pass if a newly canonical artifact disappears.
- Preserve the explicit pending status for rendered trackpad overflow, focus order,
  VoiceOver traversal, Reduce Motion appearance, and local/relay GUI regression.
  Pure policy coverage must not be promoted into evidence for those behaviors.

## Resolution

The prior Important reveal-scheduling finding is resolved.

- `Sources/XMtermApp/TerminalTabStripLayout.swift:15-40` now separates scheduling
  from rendering. Initial and tab/selection-state requests receive one 16 ms render
  settle; viewport-only requests receive a 75 ms debounce and no animation.
- `Sources/XMtermApp/TerminalTabStrip.swift:87-109` updates the latest request and
  generation, sleeps before doing any scroll work, returns on task cancellation or
  supersession, and contains exactly one final `scrollTo` per accepted request.
  Because the delay is inside `.task(id: revealRequest)`, successive viewport widths
  cancel the earlier sleep and coalesce to the latest request.
- Animation is selected only when tab IDs or selection changed. Initial and
  viewport-only reveals are unanimated, and `accessibilityReduceMotion` still makes
  the optional tab-state animation `nil` at
  `Sources/XMtermApp/TerminalTabStrip.swift:62-64,106-108`.
- The former Minor naming concern is also resolved at
  `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift:10-41`. New scheduling
  tests at lines 68-153 cover the initial settle, tab/selection animation schedule,
  viewport debounce, and invalid target behavior.
- Fresh focused verification passed: **17 tests in 1 suite**, with zero failures.

## Ready verdict

**READY — approved for the source/automated Phase 2 tab-strip slice.** The prior
blocking reveal issue is fixed, the focused 17-test suite passes, and no new Critical,
Important, or Minor finding was identified in the scoped re-review. This approval
does not convert the separately documented rendered trackpad, focus, VoiceOver, or
Reduce Motion checks into completed evidence.
