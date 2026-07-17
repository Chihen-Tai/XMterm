# Browser-Like Terminal Tab Strip Redesign

- **Status:** Implemented in Phase 2
- **Date:** 2026-07-16
- **Owner:** Project owner
- **Decision scope:** Phase 2 UI polish for terminal-tab sizing, overflow, creation,
  selection, and header-region ownership
- **Canonical requirements:** `TAB-001`, `TAB-002`, `TAB-003`, `TAB-005`,
  `APP-003`, `A11Y-001`, `A11Y-002`, `A11Y-003`, and `MAC-001`

## Goal

Make XMterm's terminal tabs behave like a modern browser strip. The new-terminal
button visually follows the final visible tab, remains pinned when tabs overflow,
and is never treated as a trailing toolbar action.

This refinement does not add Session Manager, SFTP, Remote File Browser, Settings,
tab reordering, or unrelated toolbar actions.

Phase 3 subsequently replaced the local/relay `+` menu content with the searchable
saved-session popover defined in
[`session-manager.md`](session-manager.md). The pinned-button dimensions, sibling
ownership, viewport geometry, stable tab IDs, and reveal scheduling defined here
remain unchanged. That later workflow is evidence for compatibility, not a scope
expansion of this Phase 2 design.

## Region ownership

The window header has two independent regions:

```text
Terminal tab strip                              Remaining header / toolbar region
┌────────────────────────────────────────────┐  ┌──────────────────────────────┐
│ scrollable tab viewport when needed │  +  │  │ future toolbar actions       │
└────────────────────────────────────────────┘  └──────────────────────────────┘
```

The terminal tab strip owns terminal tabs, active and lifecycle indicators, close
buttons, the new-terminal `+` menu, and horizontal scrolling. The remaining header
region owns no actions in this task and stays available for existing or future
toolbar controls. The `+` menu is outside the scrollable viewport but inside the
terminal tab strip.

## Width policy

The layout uses these exact tab-width bounds:

- preferred width: **180 points**;
- minimum width: **120 points**;
- maximum width: **240 points**.

The preferred width is also the normal non-overflow width. Extra header space does
not expand a tab or its viewport. The maximum remains an explicit hard bound for
the layout policy and future presentation changes.

For `n` tabs, the preferred and minimum content widths include the fixed inter-tab
spacing. The policy behaves as follows:

1. If preferred-width tabs fit, every tab is 180 points and the viewport equals the
   actual tab-content width.
2. If preferred-width tabs do not fit but equal widths of at least 120 points do,
   every tab shrinks by the same amount and the viewport equals the content width.
3. If equal widths would fall below 120 points, every tab remains 120 points, the
   viewport consumes the available tab-strip budget, and the tab content scrolls
   horizontally.
4. The `+` menu sits immediately after the viewport. With no tabs it occupies the
   leading tab-strip position. It never enters the scrollable content.
5. The tab-strip width ends after the `+` menu. Any unconsumed header width remains
   outside the tab strip, so a non-overflow viewport never grows greedily.

Layout inputs are finite and nonnegative. A narrow or transient zero-width proposal
produces bounded zero-width viewport metrics rather than negative geometry.

## Selection, creation, and closure

Tabs continue to use stable `TerminalTab.ID` values. The existing immutable tab
state appends a created tab and selects it immediately; the strip observes that
selection and reveals the new tab after SwiftUI has inserted its view.

Selection changes, tab-list changes, and viewport-width changes all request that
the selected tab be revealed. The view uses `ScrollViewReader` with each tab's
stable ID and a trailing reveal anchor. Initial and tab/selection requests receive
one 16 ms render settle; viewport-only requests receive a 75 ms debounce. The delay
precedes all scroll work, so obsolete requests are cancelled or superseded before
exactly one final scroll for the latest accepted state.

Closing a tab preserves the existing replacement-selection policy. The strip
recomputes its width once, moves `+` after the final remaining tab, and reveals the
replacement active tab. No insertion/removal path recreates terminal sessions or
terminal views.

## View structure and future reordering

The tab viewport uses one `LazyHStack` and one tab-cell view per stable ID. The new
terminal menu is its sibling, not another lazy-stack item. A small pure layout
policy produces tab width, content width, viewport width, strip width, overflow
state, and the toolbar boundary.

Drag-to-reorder is intentionally absent. Because the tab cells remain one flat,
stable-ID sequence, later drag handlers can attach to those cells without moving
the `+` menu or redesigning the viewport.

## Visual behavior and accessibility

- Titles are one line and truncate at the tail.
- Active and lifecycle indicators remain non-color-only and preserve their current
  accessibility text.
- The close button retains its label and help text.
- The `+` menu is keyboard focusable and exposes the standard `New terminal` label,
  a descriptive hint, and a stable accessibility identifier.
- Creation, closure, and selection changes may use a short native ease-out
  animation after their 16 ms settle. Initial reveal is unanimated. Width-only
  reveal during live window/sidebar resize uses a 75 ms cancellation-coalesced
  unanimated debounce so repeated geometry proposals do not create competing
  scrolls. Reduce Motion disables the optional tab-state animation without changing
  final layout or selection.
- No flashy transition, tab-view duplication, or implicit process-view animation is
  introduced.

## Performance

- Stable IDs allow SwiftUI to retain unchanged tab cells.
- `LazyHStack` limits realized overflow content.
- One header-width proposal feeds one pure layout calculation; there are no
  per-tab `GeometryReader` or preference-key feedback loops.
- Lifecycle changes do not alter tab identity or viewport geometry.
- Reveal work is keyed to selection, tab IDs, and viewport width, so unrelated
  terminal output does not trigger scrolling. Each accepted request performs one
  final scroll after its pure-policy delay.

## Verification

Deterministic tests cover:

- 180/120/240-point constants and equal shrinking;
- content-sized non-overflow viewports;
- minimum-width overflow and horizontal-scroll state;
- `+` placement immediately after the viewport and outside scrollable content;
- reserved toolbar space beginning after the tab strip;
- selected/new/replacement tab reveal targets;
- initial/tab-state/viewport-only reveal scheduling and invalid-target suppression;
- existing create, select, close, and stable-identity behavior.

The staged manual pass covered pointer creation/selection/close, computer-use
horizontal scrolling, pinned `+`, active-tab reveal after creation/close/resize,
menu contents/dismissal, and AX labels/order. Physical trackpad momentum, long-title
rendering, full keyboard focus traversal, actual VoiceOver, Reduce Motion, relay
invocation, and quantitative performance inspection remain open.

The later Phase 3 packaged-app matrix rechecks the pinned `+`, picker dismissal and
focus restoration, profile-backed creation, local/SSH coexistence, appearance,
Reduce Motion, and accessibility metadata. Its exact outcomes are recorded in
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md)
rather than retroactively changing Audit 0004's historical Phase 2 evidence.

## Acceptance criteria

- Non-overflow layout is `[tabs at content width][+][remaining header space]`.
- Overflow layout is `[scrollable tab viewport][+][remaining toolbar space]`.
- The `+` menu is always visible and immediately adjacent to the viewport.
- Tabs shrink equally from 180 to 120 points and then scroll without further
  shrinking.
- The selected tab is revealed after creation, activation, closure, and resize.
- No terminal session, process, scrollback, close policy, SSH behavior, or toolbar
  action changes.

## Unresolved questions

None for this task. Tab reordering, `Command-1` through `Command-9` selection,
`Command-Shift-[` / `Command-Shift-]` adjacent-tab navigation, rename, duplicate,
reconnect, SFTP, Remote File Browser, Settings, and new toolbar actions remain
explicitly outside this design. Session Manager is implemented by the separate
Phase 3 design. `TAB-002` therefore remains Partial after this polish slice.
