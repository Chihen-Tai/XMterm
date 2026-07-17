# Task 3 SwiftUI integration guardrails

These findings bind the integration in addition to the task brief:

1. Render the policy geometry exactly. Remove the old scroll-content horizontal
   padding and menu trailing padding. Render the 8-point leading inset outside the
   viewport, make the 4-point gap conditional on a nonempty tab list, and constrain
   the `Menu` itself—not only its image—to 28 points.
2. Keep `TerminalWorkspaceHeader` as the sole `GeometryReader` owner. Give
   `TerminalTabStrip` exactly `metrics.stripWidth`, leave at least the policy's
   toolbar separation after it, and never give the non-overflow viewport a greedy
   max-width frame.
3. `Task.yield()` is not accepted as proof that a lazy child is registered with
   `ScrollViewReader`. Key/cancel reveal work by the latest request and verify the
   rendered result after rapid creation/selection/closure. If the first approach is
   flaky, use a generation-checked/coalesced two-phase reveal while retaining
   `ScrollViewReader`.
4. Animate tab-list/selection reveal only. Width-only reveal during continuous
   resize must be immediate or briefly coalesced, not one animation per geometry
   proposal. Reduce Motion disables explicit and implicit animation.
5. Do not key the header, reader, scroll view, or cells by metrics, count, index, or
   title. `ForEach` and `.id` use stable `TerminalTab.ID`; keep RootView's terminal
   surface identity unchanged.
6. The selectable tab button receives flexible remaining width; status and close
   controls remain usable at 120 points; title is one line with tail truncation.
7. Preserve the existing `+` actions, disabled state, label, hint, help, and keyboard
   focus; add the approved accessibility identifier. No toolbar controls are added.
8. Focus restoration after closing a keyboard-focused tab, overflow keyboard/
   VoiceOver order, trackpad scrolling, live resize, and actual selected-tab reveal
   are manual-runtime checks, not claims inferred from policy tests.
9. Boundary expectations for three tabs are: 1000 → viewport 548, plus minX 560,
   strip end 588, toolbar minX 596; exact preferred fit 596; exact minimum fit 416;
   415 overflows. Zero tabs: plus minX 8, strip width 36. Below 44, avoid negative or
   nonfinite frames; the fixed menu cannot physically fit below 36.
