# Interaction Parity Checklist

Phases 1 and 2 cover the terminal/process surfaces, and Phase 3 adds the saved-
session picker, manager/editor, persistence/recovery, and profile-backed launch
workflow. `[x]` means applicable and verified at the scope named by the row;
unchecked items are labelled **Partial**, **Deferred**, **Out of scope**,
**Pending**, or **Not applicable**. Real-relay manual status is tracked separately in
[`ssh-terminal-acceptance.md`](ssh-terminal-acceptance.md). Remote-file collection behavior remains for later phases.

## Selection

- [x] Single-click tab selection and terminal focus work.
- [ ] **Not applicable:** terminal tabs are a single-selection collection; local
  and SSH tabs do not expose discontiguous batch selection.
- [ ] **Partial:** terminal Shift-click is engine-supported but not manually verified.
- [ ] **Partial:** terminal selection is keyboard-operable through engine behavior;
  keyboard tab-number selection is deferred.
- [x] `Command-A` targets only the focused terminal.
- [x] Terminal selection and each tab's state survive harmless SwiftUI updates.
- [ ] **Not applicable:** terminal text is not a batch-action collection.
- [x] Saved profiles use intentional single selection in the picker and manager;
  profile multi-selection/range selection and batch actions are explicitly deferred.

## Clipboard and editing

- [x] `Command-C` acts on the focused terminal and only when it has selection.
- [x] `Command-X` is intentionally unavailable for immutable terminal output.
- [x] `Command-V` pastes through the focused terminal's safety policy.
- [ ] **Partial:** menu/context/shortcut parity exists for the implemented terminal
  subset; clear scrollback, visible-screen copy, cwd, URL, and reconnect are deferred.
- [ ] **Out of scope:** remote-file pasteboard representations do not exist yet.
- [x] Undo/redo remains owned by the shell/application; no local mutation pretends
  to be terminal undo.

## Pointer and drag

- [x] Double-click word and triple-click line behavior is defined and verified.
- [ ] **Partial:** secondary-click exposes the terminal menu; a complete selection-
  preservation matrix was not manually recorded.
- [ ] **Deferred:** selected terminal text drag export.
- [ ] **Out of scope:** terminal/file drop targets and operation feedback.
- [ ] **Out of scope:** remote mutation and invalid-drop rejection.
- [ ] **Out of scope:** remote copy-versus-move modifiers.
- [x] Terminal-surface trackpad and mouse scrolling/selection were checked; this is
  not evidence for the separate tab-overflow viewport.

## Keyboard and focus

- [x] Create, close, copy, paste, find, and select-all shortcuts are discoverable.
- [x] Focus moves predictably after create, select, close-cancel, close, and exit.
- [ ] **Partial:** primary tab/terminal controls are keyboard reachable; full
  VoiceOver and tab-number/reorder navigation are not complete.
- [x] Terminal control sequences are not stolen by unrelated app shortcuts.
- [x] `Command-C`/`Command-V` are local while `Control-C`/`Control-V` reach the PTY.
- [x] Tests preserve distinct `Control-C`, `Control-Z`, `Control-D`, and `Control-\`
  bytes; the first two were additionally exercised manually.
- [x] `Control-W` reaches the shell while exact `Command-W` closes the tab.
- [ ] **Partial:** Backspace/Delete and representative special keys match the engine
  profile; the entire function/modified-key matrix was not manually audited.
- [x] Runtime menu normalization gives Close Terminal and Close Window distinct
  exact shortcuts and leaves deferred modifier chords unhandled.

## Phase 2 tab-strip polish

- [x] **Pure policy:** tests cover 180-point preferred width, equal shrinking to
  120 points, minimum-width overflow, exact thresholds, and finite bounded geometry.
- [x] **Pure policy:** tests cover content-sized non-overflow, pinned `+`
  coordinates, zero-tab gap behavior, and the reserved toolbar boundary.
- [x] **Pure reveal target:** tests cover appended selection, contained replacement
  selection, stale selection rejection, and viewport width in request identity.
- [x] **Pure reveal schedule:** tests cover a 16 ms unanimated initial settle, a
  16 ms optionally animated tab/selection settle, a 75 ms cancellation-coalesced
  unanimated viewport debounce, and no schedule for an invalid target.
- [x] **Source-reviewed composition:** one stable-ID `LazyHStack` is the only tab
  sequence inside one horizontal viewport; `+` is its fixed non-scrolling sibling,
  each accepted schedule performs exactly one final scroll, and terminal/session
  ownership is unchanged.
- [x] **Rendered width/pinned `+`:** one tab was visually approximately 180 points;
  two/three tabs kept a content-sized viewport, unused header space, and `+`
  immediately after the final tab.
- [x] **Rendered overflow:** six tabs shrank equally; ten/eleven tabs overflowed at
  readable widths, computer-use horizontal scrolling worked in both directions,
  and `+` remained pinned outside the viewport.
- [ ] **Pending physical input:** trackpad momentum was not exercised.
- [x] **Rendered active reveal:** the first, newest, and replacement selected tabs
  became visible after activation, create, close, and live resize.
- [ ] **Pending rendered long title:** verify one-line tail truncation keeps status
  and the 28-point close target visible and usable at minimum width.
- [x] **Pointer/menu inspection:** `+` opened the unchanged local/relay menu and
  Escape dismissed it.
- [ ] **Pending keyboard focus:** verify full Tab-key traversal and focus restoration
  to the sensible selected terminal after close.
- [x] **AX inspection:** the staged tree exposed `Terminal tabs`, selected/status
  state, close labels, the `New terminal` label/hint/identifier, and a separate
  toolbar sibling.
- [ ] **Pending VoiceOver:** actual auditory/traversal behavior was not exercised.
- [ ] **Pending Reduce Motion:** verify create/select/close/resize reaches the same
  layout and selected reveal without explicit animation.
- [x] **Rendered local subset:** local creation, selection, replacement close, and
  the local/relay menu entries were inspected in the polished header.
- [x] **Phase 3 relay regression:** the packaged app launched the saved Relay Host
  profile; exact argument construction and process/session isolation remain covered
  by deterministic production-boundary tests.
- [ ] **Deferred (`TAB-002`):** `Command-1`…`Command-9`, adjacent-tab shortcuts,
  drag reorder, and reveal after reorder are not implemented.

## Phase 3 Session Manager

- [x] The pinned `+` opens a searchable saved-session popover rather than launching
  a process immediately; the search field requests focus on appearance.
- [x] Pure picker tests cover unique Recent/Favorites/SSH/Local precedence, recency
  ordering/cap, search by name/host/user/alias/shell, empty results, stable
  Up/Down selection, and `Command-T` fallback policy.
- [x] Picker rows support pointer selection, double-click, Return, Escape, a named
  accessibility Launch action, and a separately labelled Favorite/Unfavorite
  button. Dismissal restores `+` focus; successful launch restores terminal focus.
- [x] The native manager/editor supports create local, create SSH, edit, duplicate
  with an independent ID, favorite/unfavorite, and delete with an explicit
  confirmation that existing tabs remain open.
- [x] Editor drafts show inline structural validation while typing; filesystem
  existence/executable/readability checks occur only at save or launch boundaries.
- [x] Profile mutations are persist-before-publish. Automated failure tests prove a
  failed write leaves the published immutable collection unchanged, and the UI
  keeps the typed persistence error visible so the original action can be repeated
  after repair; load errors have `Try Again`, and corrupt stores expose recovery
  actions.
- [x] Each launched tab owns a copied immutable launch specification plus source-
  profile provenance. Profile edit/rename/delete and tab-title changes cannot
  cross-mutate the other identity.
- [x] Loading, empty, unmatched search, path-validation, persistence-error, and
  recovery-required states have explicit non-silent presentations.
- [x] The complete packaged-app matrix, including restart persistence, appearance,
  Reduce Motion, keyboard-only management, AX labels, 100-profile responsiveness,
  stored-data inspection, and exact limitations, is recorded row by row in
  [`session-manager-acceptance.md`](session-manager-acceptance.md); an unchecked or
  partial row there is not inferred from automated evidence here.
- [ ] **Deferred by design:** profile multi-selection/batch operations, drag reorder,
  config-alias discovery/import, reconnect, and automatic reconnect.
- [ ] **Out of scope:** SFTP, Remote File Browser, transfers, external-editor launch,
  and editor synchronization have not been introduced.

## Async behavior

- [x] Starting, running, closing, exited, and failed states are explicit.
- [x] SSH state is process-only and honestly avoids Connected/Authenticated claims;
  raw prompt text is not parsed.
- [x] Local foreground work is detected from PTY process-group ownership and can be
  cancelled through confirmed terminal close; an idle shell closes directly.
- [x] Completed foreground work returns to idle-close behavior, background jobs do
  not trigger the foreground warning, and an exceptional live query failure uses a
  conservative prompt.
- [x] Closing a tab terminates/reaps its PTY process without retaining the view.
- [x] One terminal failure, exit, or asynchronous close decision does not freeze,
  prompt for, or close another terminal.
- [x] Every live SSH process receives the SSH-specific confirmation; exited and
  failed SSH tabs close immediately, and aggregate shutdown counts SSH separately.
- [ ] **Not applicable:** terminal tabs and Phase 3 profiles expose no batch
  operation in the implemented scope.

## Safety

- [ ] **Out of scope:** destructive remote paths.
- [ ] **Out of scope:** remote name collisions.
- [ ] **Out of scope:** remote mutation confirmation.
- [ ] **Out of scope:** remote retry ordering.

## Accessibility

- [x] Icon-only controls have accessibility labels and help.
- [x] terminal lifecycle status is expressed in text, not color alone.
- [x] The plus picker exposes keyboard-readable saved local/SSH rows, named Launch
  actions, and profile-specific Favorite/Unfavorite labels; SSH panes identify the
  selected target and describe in-terminal OpenSSH prompts.
- [ ] **Partial:** surrounding native controls have sensible order; SwiftTerm does
  not expose the complete grid/cursor/selection as a full VoiceOver model.
- [x] plus/close controls use enlarged hit targets and the terminal resizes naturally.
- [ ] **Partial:** no custom animation hides state; increased-contrast appearance
  was not exhaustively audited.

## Verification evidence

- [x] Domain/unit tests cover tab, lifecycle, input, paste, grid, and resize state.
- [ ] **Partial:** focused AppKit tests cover critical shortcut and selection
  boundaries; full XCUITest is blocked by the Command Line Tools-only host.
- [x] Manual verification steps and outcomes are in Execution Plan 0003 and Audit 0002.
- [ ] **Partial:** Phase 2 deterministic, staged-app, and bounded real-relay
  evidence is in Audit 0003; unencountered credential and application flows are
  explicitly not inferred.
- [ ] **Partial:** Audit 0004 records 143 passing tests in 23 suites, clean warning-
  treated builds, a READY independent source/automated re-review, and the core
  rendered layout/overflow/reveal/AX inspection. Physical trackpad momentum,
  long-title rendering, full keyboard traversal, actual VoiceOver, Reduce Motion,
  relay invocation, and quantitative performance inspection remain open.
- [x] Phase 3's isolated coverage run passed 268 tests in 35 suites; clean isolated
  warnings-as-errors debug/release builds, scoped coverage, packaged-app results,
  review findings, and limitations are recorded in Audit 0005.
- [x] Applicable `INTERACTIONS.md` requirement IDs are cited in plan and tests.

## Terminal protocol and lifecycle additions

- [ ] **Partial:** SwiftTerm supplies the advertised profile and focused integration
  tests cover critical modes; full xterm compatibility is not claimed.
- [x] Soft-wrapped copy does not add artificial newlines.
- [ ] **Partial:** combining/CJK/emoji rendered and copied; exhaustive cell-width and
  IME preedit testing remains.
- [x] Resize updates PTY size and `vim`/`less` redraw.
- [x] Local process exit preserves scrollback/selection and shows typed status.
- [ ] **Deferred:** SSH reconnect starts a fresh process.
- [x] OSC links cannot open automatically; link presentation itself is deferred.
- [ ] **Partial:** OSC 52 reads/writes are dropped; visible permission-gated writes
  are deferred rather than enabled.
- [ ] **Deferred:** local Clear Scrollback/`Command-K` and Reset Terminal.

## SSH and transfer additions

- [x] The fixed relay executes system `/usr/bin/ssh` directly with a structured,
  exact argument array and inherits normal OpenSSH environment behavior.
- [ ] **Partial:** effective behavior is delegated to OpenSSH and manually entered
  aliases launch as `/usr/bin/ssh ALIAS`; config alias discovery/import and `ssh -G`
  presentation remain deferred beyond Phase 3.
- [ ] **Out of scope:** SSH sleep/wake and network loss.
- [ ] **Out of scope:** terminal/SFTP failure isolation (terminal-tab isolation is verified).
- [ ] **Partial:** normal agent/Keychain/config behavior is preserved by the direct
  OpenSSH process; real authentication flows were not established by automation.
- [ ] **Out of scope:** transfer staging.
- [ ] **Out of scope:** executable-mode preservation.
- [ ] **Out of scope:** symlink-safe editor saves.
- [ ] **Out of scope:** transfer retry ordering.
- [ ] **Out of scope:** remote path argument handling.
