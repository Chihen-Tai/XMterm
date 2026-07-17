# Terminal Acceptance Checklist

Phase 1 evidence was collected on macOS 26.5.2 (Apple M4, arm64) with the local
login shell, SwiftTerm 1.14.0, and a debug-development app bundle. `[x]` means the
behavior has direct automated or manual evidence. An unchecked **Partial**,
**Deferred**, **Blocked**, or **Out of scope** item is not claimed complete. Exact
commands and observations are in
[`../audits/0002-phase-1-local-terminal-evidence.md`](../audits/0002-phase-1-local-terminal-evidence.md).
Phase 2 fixed-relay checks and their separate automated/manual status are in
[`ssh-terminal-acceptance.md`](ssh-terminal-acceptance.md) and
[`../audits/0003-phase-2-ssh-terminal-evidence.md`](../audits/0003-phase-2-ssh-terminal-evidence.md).
Phase 3 saved-session workflow evidence is in
[`session-manager-acceptance.md`](session-manager-acceptance.md) and
[`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).

## PTY and process lifecycle

- [x] A real PTY is allocated and a local interactive login shell sees a terminal.
- [x] Phase 2 directly configures `/usr/bin/ssh` through the same production PTY
  boundary; deterministic session tests cover raw output, input, resize, and exit.
- [x] Window resize updates rows/columns and full-screen applications redraw.
- [x] Process exit code and signal status are captured and tested.
- [x] Local shell exit preserves final scrollback and disables input.
- [ ] **Deferred:** reconnect starts a fresh process; no reconnect UI exists yet.
- [x] Closing one local tab does not affect another tab.
- [ ] **Out of scope:** independence from SFTP awaits SFTP implementation.
- [x] The shell PID and `forkpty` shell process-group ID are recorded separately
  from lifecycle state.
- [x] A real-PTY test proves an idle interactive shell owns the foreground process
  group and closes without confirmation.
- [x] A real-PTY test proves `sleep` moves a different process group to the
  foreground and requires confirmation.
- [x] Interrupting or completing the foreground process returns the shell process
  group to the foreground and restores immediate-close behavior.
- [x] A background job leaves the shell in the foreground and does not trigger the
  foreground-job warning merely by existing.
- [x] Exited and failed terminal lifecycles close immediately.
- [x] A closed/reaped PTY is treated as unavailable and closes immediately; an
  unexpected `tcgetpgrp` failure on an otherwise-live PTY uses one conservative,
  honestly worded confirmation.
- [x] Per-tab decisions are keyed by stable session identity; two-tab and stale
  asynchronous-result tests prevent cross-tab routing.
- [x] The staged GUI was verified for a fresh prompt (immediate close),
  `sleep 100` (foreground-job confirmation), Cancel preserving the session, and
  `Control-C` returning the shell to immediate-close behavior.
- [ ] **Manual follow-up:** extend the staged close-sheet matrix to `python3`,
  `vim`, `less`, `top`, and a foreground pipeline.
- [ ] **Known limitation:** a long-running builtin or `exec` replacement can remain
  in the recorded shell process group and is not distinguishable without the
  prohibited prompt/output heuristics.
- [x] PTY descriptors close and children are reaped, including descendants that
  retain the slave PTY after the direct child exits.

## Control keys and special keys

- [x] Exact byte mapping tests distinguish `Control-C`, `Control-Z`, `Control-D`,
  and `Control-\`; `Control-C` and `Control-Z` were also exercised manually.
- [x] `Control-V` reaches the PTY as byte `0x16`; quoted insertion was exercised.
- [ ] **Partial:** `Control-S` and `Control-Q` are byte-tested, but IXON flow-control
  behavior was not manually exercised.
- [x] `Control-W` reaches the shell and `Command-W` closes only the selected tab.
- [x] `Command-C` and `Command-V` are local copy and paste operations.
- [x] Backspace is DEL; Forward Delete has a deterministic engine mapping.
- [ ] **Partial:** Return, Tab, Escape, arrows, Page Up/Down, Shift-Tab, modified
  arrows, and function-key routes are covered selectively, not as a full matrix.
- [ ] **Partial:** repeated terminal input uses AppKit key-repeat delivery and
  bounded writes, but a long manual repeat soak was not recorded.
- [ ] **Blocked on repeatable GUI automation:** Traditional Chinese committed and
  pasted text works, but IME preedit was not conclusively observed before commit.
- [x] Only exact supported Command chords are consumed; modified/deferred Command
  chords remain available to macOS or later features.

## Rendering and protocol

- [ ] **Partial:** SwiftTerm advertises 256-color/true-color support, but the full
  16/256/true-color visual matrix was not manually audited.
- [ ] **Partial:** bold, italic, underline, inverse, faint, and strike rendering was
  not exhaustively compared.
- [ ] **Partial:** cursor movement and visibility worked in `vim`/`less`; every
  xterm cursor style was not tested.
- [x] Alternate screen restores the original shell screen in `vim` and `less`.
- [ ] **Partial:** ordinary redraw/clear behavior works; the complete scroll-region
  and insert/delete-line sequence matrix relies on the pinned engine.
- [x] Bracketed paste framing is emitted only when the engine reports it enabled.
- [ ] **Partial:** the adapter supports reported mouse events and Option-local
  selection, but a `vim`/`htop` mouse matrix was not manually verified.
- [x] A constant-memory pre-parser filter handles split, overlong, unterminated,
  and host-affecting control strings without forwarding raw dangerous content.

## Unicode and width

- [x] Tests split UTF-8 input across PTY chunks without corrupting the stream.
- [ ] **Partial:** combining accents rendered in the manual fixture, but every
  cursor-cell boundary was not measured.
- [ ] **Partial:** Traditional Chinese and wide CJK text rendered and copied, but a
  comprehensive width table was not tested.
- [ ] **Partial:** emoji rendered without observed corruption; variation-selector
  and ZWJ sequences were not exhaustively tested.
- [x] Selection and copy returned the intended manually checked Unicode text.

## Selection and clipboard

- [ ] **Partial:** drag selection works in the viewport and while historical
  scrollback is visible; prolonged edge auto-scroll was not manually measured.
- [x] Double-click word and triple-click line selection work.
- [ ] **Partial:** Shift-click extension is supplied by SwiftTerm but was not
  manually verified in this environment.
- [x] A deterministic adapter test proves soft-wrapped lines copy without an
  artificial newline.
- [x] Hard line breaks remain in copied text.
- [x] Trailing visual padding is not copied by default.
- [ ] **Deferred:** dragging selected terminal text into another application.
- [x] A multiline/control-bearing paste confirmation sends zero bytes on Cancel.
- [x] Pasted content is never given an implicit Return.
- [x] Exited terminals retain selectable scrollback even if the engine's last
  application mode had mouse reporting enabled.

## Scrollback and search

- [x] Mouse/trackpad scrolling remained responsive during and after heavy output.
- [x] Scrolling up disables follow mode without losing incoming data.
- [x] A New Output affordance appears while historical output is visible.
- [x] Jumping to latest resumes follow mode.
- [ ] **Partial (`TERM-FIND-001`):** search finds visible/historical text with
  next/previous and case/word/regex options; result count is absent.
- [ ] **Deferred:** Clear Scrollback distinct from `Control-L` and terminal reset.
- [x] Scrollback is bounded to 10,000 lines per terminal.

## Titles, links, bell, and clipboard escape sequences

- [ ] **Deferred by security policy:** terminal-originated dynamic titles.
- [ ] **Deferred:** user-renamed tabs and remote-title precedence.
- [x] OSC 8 and detected URLs never open automatically.
- [x] Unsafe URL schemes cannot be opened by terminal output in Phase 1.
- [ ] **Deferred by security policy:** audible/visual bell configuration.
- [x] OSC 52 clipboard reads are denied.
- [x] OSC 52 clipboard writes are dropped before engine parsing.

## Application compatibility

- [ ] **Partial:** zsh line editing was exercised; bash was not separately audited.
- [ ] **Partial:** `vim` and `less` were exercised, including alternate screen,
  resize, redraw, quit, and shell-screen restoration; `nano`, `man`, `top`, `htop`,
  and `watch` were not all exercised.
- [ ] **Partial:** interactive shell commands worked; a formal Python/secondary-REPL
  checklist was not recorded.
- [ ] **Phase 2 manual follow-up:** nested `ssh g207` behavior is supported as
  ordinary terminal input but has not been inferred from automated tests.
- [ ] **Deferred:** ten-minute continuous-output soak; the required 100,000-line
  fixture completed responsively.
- [ ] **Out of scope:** simultaneous SFTP transfer.

## Tabs, window lifecycle, and accessibility

- [x] `Command-T` launches the first saved login-shell profile, normally Local
  Terminal; when none exists it opens the saved-session picker. The pinned `+` and
  File menu open the searchable local/SSH picker with stable profile identity.
- [x] Click selection preserves each tab's process, screen, and scroll position.
- [x] Close buttons and `Command-W` close only the selected terminal; an idle local
  shell closes immediately, while a known foreground job or exceptional live query
  failure prompts. `Shift-Command-W` and `Command-Q` aggregate those local
  terminals requiring confirmation and count live SSH sessions separately.
- [x] A normally or abnormally exited tab retains final scrollback and can close
  immediately; a new tab can be opened afterward.
- [x] Icon-only controls and terminal containers expose accessibility labels and
  the active terminal receives focus.
- [ ] **Partial (`A11Y-001`–`A11Y-003`):** full VoiceOver access to terminal cells,
  cursor, and selection is incomplete upstream; no XCUITest run was available.

## Evidence

- [x] Deterministic integration tests cover advertised adapter/parser boundaries.
- [x] Real PTY integration tests cover input/output, resize, output draining,
  process exit, signal status, close escalation, and cleanup.
- [ ] **Partial:** focused AppKit tests cover shortcut routing, retained views,
  selection/copy, scroll-follow, and close state; a full XCUITest suite is blocked
  by the Command Line Tools-only host.
- [x] Manual notes cite known compatibility exceptions without claiming full xterm
  compatibility.

## Phase 2 fixed-relay supplement

- [x] Exact executable/arguments, absence of a shell wrapper, and absence of
  host-key bypass/secret options are automated.
- [x] Local/SSH coexistence, selection, fixed title, lifecycle, final output,
  conservative live close, immediate exited/failed close, and aggregate shutdown
  behavior are automated.
- [x] Existing Phase 1 key, paste, resize, selection, scrollback, security-filter,
  descriptor-close, child-reap, and no-zombie tests apply to the shared production
  terminal/process path.
- [ ] **Partial; see Audit 0003:** real relay login, one `stty size`, and active
  close/Cancel/isolation were observed. Host-key/password/OTP/Keychain flows,
  applications, Unicode/IME, manual second hop, and naturally exited close remain
  unperformed or unencountered.

## Phase 3 saved-session supplement

- [x] Local, direct-SSH, and manually entered alias profiles produce immutable
  launch specifications before terminal creation; the specification and source-
  profile provenance remain attached to the tab.
- [x] Opening the same profile twice creates distinct tab and runtime-session IDs.
  Editing, renaming, favoriting, or deleting its saved profile cannot mutate or
  close either existing tab.
- [x] Relay Host retains the exact `/usr/bin/ssh`, `-p`, `54426`,
  `allen921103@140.109.226.155` launch contract, and Local Terminal retains the
  ordinary Phase 1 login-shell resolver.
- [x] The picker and manager surface loading, empty, invalid-field, path-validation,
  persistence-error, and corrupt-store recovery states without replacing terminal
  lifecycle state or parsing prompt output.
- [x] The isolated Phase 3 coverage run passed 268 tests in 35 suites, including
  local/SSH coexistence, launch-boundary validation, snapshot isolation, and exact
  argument construction. Existing PTY/process, terminal-engine, and close-policy
  suites remained green.
- [ ] **Deferred:** profile-backed reconnect, recently closed tab reopening,
  automatic reconnect, SSH config alias discovery/import, and `ssh -G`
  presentation.
- [ ] **Out of scope:** SFTP, remote file browsing, transfers, external-editor
  launch, and editor synchronization have not started.
