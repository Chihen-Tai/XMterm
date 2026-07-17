# Terminal Interaction Design

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** PTY-backed terminal surface and browser-like terminal tabs
- **Canonical requirements:** `INTERACTIONS.md` sections 2 and 3
- **Keyboard contract:** [`terminal-keyboard.md`](terminal-keyboard.md)

**Implementation note (Phase 2):** the conservative SSH rule described below is
implemented for the fixed relay. Every live SSH process confirms with the exact
SSH-specific decision; exited and failed SSH tabs close immediately. No local PTY
foreground classification is reused as a claim about remote work.

## Goal

The terminal must feel like a first-class macOS terminal rather than a static SSH
log viewer. It must preserve ordinary shell behavior while supporting local text
selection, copy/paste, search, scrollback, and tab management.

## Required interaction scenarios

### Select and copy output

1. User drags over terminal output.
2. XMterm highlights the selected terminal cells.
3. User presses `Command-C`.
4. Clipboard receives normalized plain text.
5. The remote process does not receive `Control-C`.

Acceptance: `TERM-SEL-001`, `TERM-CLIP-001`.

### Select while a remote app uses the mouse

1. A remote program enables mouse reporting.
2. Normal drag is sent to the remote application.
3. User holds `Option` and drags.
4. XMterm performs local selection instead.

Acceptance: `TERM-SEL-003`.

### Paste multiple lines

1. User copies several shell commands.
2. User presses `Command-V` in the terminal.
3. If paste protection is enabled, XMterm previews or warns before sending.
4. Bracketed paste is used when supported by the remote application.
5. Cancel sends nothing.

Acceptance: `TERM-CLIP-002`.

### Read old output without being pulled to bottom

1. User scrolls up.
2. New remote output arrives.
3. View stays at the user's current history position.
4. A subtle indicator shows new output below.
5. Scrolling to bottom resumes follow mode.

Acceptance: `TERM-SCROLL-001`.

### Close a connected versus exited terminal

Local and remote terminals use different evidence. For a local PTY, XMterm records
the shell process group and queries the terminal foreground process group at close
time. Therefore the local rules are:

- shell process group is foreground: close immediately;
- a different process group is foreground: show one concise confirmation;
- a foreground process that completes returns the terminal to immediate-close;
- background jobs alone do not trigger the foreground warning;
- disconnected/exited/failed/already-closed PTY: close immediately;
- unexpected `tcgetpgrp` failure on an otherwise-live PTY: show one conservative
  confirmation without claiming a process is definitely running;
- close terminates only that tab's PTY/SSH process;
- other tabs, SFTP, and transfers remain unaffected.

XMterm still cannot reliably distinguish an idle remote shell from a foreground
command without remote shell integration. A connected SSH terminal therefore uses
the conservative remote confirmation policy until that capability is designed.

The local rule is intentionally process-group-based. Work that deliberately stays
inside the shell process group, such as a long-running builtin or an `exec`
replacement, is not distinguishable without prohibited shell/output heuristics.

Acceptance: `TAB-003`, `TERM-PROC-001`.

## Terminal rendering and selection model

The emulator owns a grid plus scrollback buffer. Selection is represented in
buffer coordinates, not copied from an accessibility snapshot. Reflow on resize
must preserve selection when practical; if exact preservation is impossible, clear
selection explicitly rather than copying wrong text.

## Clipboard output rules

- default format: UTF-8 plain text;
- preserve intentional line breaks;
- strip cells used only as visual right padding;
- preserve internal spaces and tabs according to emulator data;
- do not include prompt decorations outside the selected cells;
- copying an empty selection is a no-op.

## Tab behavior

Tabs are reorderable and independently own process state, scrollback, title,
selection, and search state. Switching tabs must restore that tab's scroll
position and focus. Duplicate Connection opens a fresh SSH process using the same
profile; it does not clone shell process state.

## Control keys and local shortcuts

The keyboard implementation must follow `terminal-keyboard.md`. In particular:

- `Control-C` sends the remote interrupt byte;
- `Control-Z` sends suspend;
- `Control-D` sends end-of-input;
- `Control-V` must remain remote input and must not paste or terminate;
- `Command-V` performs local clipboard paste;
- `Control-W` remains available to the remote shell;
- `Command-W` closes the XMterm tab.

XMterm forwards terminal input and does not emulate shell job control locally.

## Minimum manual verification

- drag, double-click, triple-click, and Shift-click selection;
- `Command-C` versus `Control-C`;
- `Command-V` versus `Control-V`;
- `Command-W` versus `Control-W`;
- `Control-Z`, `Control-D`, and `Control-\`;
- paste one line and many lines;
- Unicode and emoji copy/paste;
- Option-drag while `vim` or another mouse-reporting app is active;
- trackpad momentum scroll with incoming output;
- tab create, close, reorder, duplicate, and reconnect;
- local idle/foreground/completed/background close behavior and conservative query
  failure fallback;
- remote connected-tab confirmation without claiming remote foreground detection;
- terminal remains responsive during a large SFTP transfer.
