# XMterm Interaction Contract

This document is the canonical baseline for ordinary desktop behavior in XMterm.
Features are not complete merely because the underlying SSH/SFTP operation works.
They are complete only when the expected macOS mouse, keyboard, selection,
clipboard, focus, drag-and-drop, cancellation, and error behaviors also work.

Requirement IDs in this document are stable references for plans, tests, issues,
and code review.

## Implementation status note — Phases 1 through 3

The canonical requirements below remain the full product contract. Phases 1 and 2
implement native local and fixed-relay SSH terminals with the applicable input,
selection, clipboard, scrollback, resize, exit, tab-isolation, focused-command,
and close-policy subsets. A running local `/usr/bin/ssh` process is presented only
as `SSH session active`; XMterm does not claim `connected` or infer
authentication/remote-shell state from terminal output. Exact Phase 2 evidence is
in
[`docs/audits/0003-phase-2-ssh-terminal-evidence.md`](docs/audits/0003-phase-2-ssh-terminal-evidence.md).

The completed Phase 3 implementation provides saved local, direct-host
SSH, and manually entered SSH-config-alias profiles; versioned persistence and
explicit recovery; the searchable Recent/Favorites/SSH/Local picker; profile CRUD;
and immutable profile-backed launch snapshots with tab provenance. It completes
the implemented scope of `TAB-001` and `SESS-007` through `SESS-010`. Exact
packaged-app results and manual limitations are recorded in
[`docs/audits/0005-phase-3-session-manager-evidence.md`](docs/audits/0005-phase-3-session-manager-evidence.md).

Automatic alias discovery/import, `ssh -G` presentation, tab reordering,
reconnect, sleep/wake, network-loss classification, ProxyJump UI, SFTP
coordination, and remote files remain deferred. `SESS-001` through `SESS-006`,
`TAB-002` through `TAB-005`, and `TERM-STATE-001` therefore remain partial against
their broader canonical scope.

## Implementation status note — Phase 4A foundation implemented; transport blocked

The Phase 4A Remote Workspace Foundation implements `SESS-011`,
`FILE-WORKSPACE-001`, `FILE-NAV-002`, `FILE-CACHE-001`, `FILE-STATE-001`, and
`FILE-COPY-001` for the locked scope: each launched SSH runtime owns one
read-only, immediate-child workspace with single selection, bounded cache/state,
provider-resolved transactional navigation with Back/Forward/Parent/breadcrumbs/
Refresh, honest per-state presentation, a native sidebar below compact Saved
Sessions, focused menu/context commands with exact-owner guards, and exact
plain-text path copy actions. Local runtimes own no provider, cache, or remote
task. `FILE-SEL-001`, `FILE-NAV-001`, `FILE-OPS-001`, and `FILE-LIST-001` remain
Partial: only their single-selection/read-only subsets are implemented. Mutation,
transfer, multi/range selection, remote-object clipboard, drag-and-drop, file
opening, terminal-directory following, and editor sync remain deferred to later
phases.

The stock macOS `/usr/bin/sftp` client exposes only human-formatted directory
listings and cannot safely preserve every legal remote filename. Human `ls` parsing
and a custom SFTP implementation are prohibited. ADR 0007 therefore blocks the
production provider while the session architecture, provider seam, deterministic
provider, state machine, and mock-backed UI proceed. A simulated listing must never
be presented as Relay Host evidence, and Phase 4A cannot be marked complete until
the structured production transport and real manual acceptance pass.

## Implementation status note — Phase 2 tab-strip polish

The Phase 2 polish implements the source and deterministic-policy subset for a
content-sized browser-like tab strip. Preferred-width tabs stay at 180 points,
shrink equally to the 120-point minimum, and then use horizontal overflow. The
stable-ID lazy viewport is non-greedy, the `+` control is a pinned non-scrolling
sibling, and at least 8 points separate the strip from the remaining
toolbar region. Selected-tab reveal is requested after creation, click activation,
replacement selection on close, and viewport resize. Initial and tab/selection
requests settle for 16 ms before one final scroll; only tab/selection changes may
animate. Viewport-only requests use a 75 ms cancellation-coalesced unanimated
debounce. Reduce Motion disables the optional tab/selection animation.

These are implementation-status statements, not changes to the normative clauses
below. Their broader status remains:

| Requirement | Current status and boundary |
|---|---|
| `TAB-001` | **Partial at the packaged evidence boundary:** `+` opens the searchable picker without launching, `Command-T` launches the first saved login-shell profile or falls back to the picker, and Return plus the accessible Launch action launch the stable selection. A double-click hook is source-implemented, but the packaged attempt did not launch and requires focused diagnosis. |
| `TAB-002` | **Partial:** staged click activation, horizontal overflow, stable identity, and selected-tab reveal after create/activation/close/resize were observed. `Command-1`…`Command-9`, adjacent-tab shortcuts, drag reorder, reveal after reorder, and physical trackpad momentum remain deferred or unverified. |
| `TAB-003` | **Partial:** existing close and replacement-selection behavior is preserved, but middle-click close is absent. |
| `TAB-005` | **Partial:** current local/relay lifecycle status remains non-color-only, while the broader connecting/connected/reconnecting/unread-output product surface is incomplete. |
| `APP-003` | **Partial:** Phase 3 adds search autofocus, stable keyboard picker selection, Return launch, Escape dismissal, and sensible focus restoration. Complete future session/file-region traversal remains outside this phase; packaged evidence is in the Phase 3 audit. |
| `APP-004` | **Partial:** saved-profile rows provide source-implemented edit, duplicate, favorite, and delete context actions. Packaged secondary-click traversal and the broader future multi-selection/batch contract remain unverified or deferred. |
| `APP-007` | **Unchanged / not applicable to short local profile writes:** no network listing, transfer, or reconnect operation exists in Phase 3. Phase 4 cancellable operations remain deferred. |
| `APP-008` | **Implemented for the Phase 3 state surface:** loading, saving, launch validation, content, empty, persistence-error, and recovery-required states use explicit copy/progress/actions; broader transfer progress remains deferred. |
| `A11Y-001`–`A11Y-003` | **Partial:** the picker and manager have keyboard paths and explicit launch/favorite labels, and Reduce Motion removes picker scrolling animation. Actual VoiceOver traversal, physical trackpad momentum, middle-click, and future remote-file workflows remain incomplete or manually limited as recorded in the Phase 3 audit. |
| `MAC-001` | **Partial:** the pinned `+` control opens the picker, app commands expose New Terminal/Choose Session/Manage Sessions, and manager rows have context actions. Full future remote-file menu/toolbar/context parity remains outside Phase 3. |
| `MAC-003` | **Unchanged / deferred:** Phase 3 adds immutable profile provenance but does not add window/tab restoration or `Command-Shift-T` reopen behavior. |
| `MAC-006` | **Partial:** stored-data, source-log, and packaged-runtime-output inspection found no secret content or sensitive path/credential logging. Diagnostic export and notification privacy surfaces do not yet exist. |
| `SESS-001` | **Partial:** Phase 3 persists only schema-defined non-secret local/direct/alias profile metadata, but automatic `~/.ssh/config` alias discovery/import is deferred. |
| `SESS-002` | **Partial:** Open Terminal, Open Another Terminal, edit, duplicate, favorite, and delete-template actions exist. Connect File Browser remains deferred to Phase 4A. |
| `SESS-003`–`SESS-004` | **Partial:** system `/usr/bin/ssh` owns prompts and receives structured direct or exact-alias arguments. Automatic alias discovery and `ssh -G` presentation are deferred. |
| `SESS-007`–`SESS-010` | **Implemented for the Phase 3 scope:** immutable snapshots/provenance, persist-before-publish storage/recovery, picker/recency/focus, validated isolated CRUD, destructive delete isolation, explicit recovery, keyboard-only management, and appearance/motion checks are covered. Packaged limitations are recorded in the Phase 3 audit. |

Pure layout and reveal-target tests do not prove rendered SwiftUI behavior. A
separate staged pass verified core layout, horizontal scrolling, and selected-tab
reveal; long-title rendering, full keyboard focus order, actual VoiceOver traversal,
physical trackpad momentum, and Reduce Motion appearance remain open. Exact evidence is recorded in
[`docs/audits/0004-phase-2-tab-strip-polish-evidence.md`](docs/audits/0004-phase-2-tab-strip-polish-evidence.md).

## 1. Global macOS behavior

### APP-001 — Native selection conventions

XMterm must follow normal macOS selection behavior wherever a collection is shown:

- click selects one item and clears unrelated selection;
- `Command-click` toggles one item without clearing other selected items;
- `Shift-click` selects a contiguous range from the selection anchor;
- clicking empty space clears selection when the control conventionally supports it;
- moving keyboard focus must not silently destroy a valid multi-selection;
- disabled or unavailable items must not become selected by accident.

### APP-002 — Native clipboard conventions

Where the focused control supports the action:

- `Command-C` copies;
- `Command-X` cuts;
- `Command-V` pastes;
- `Command-A` selects all;
- `Command-Z` undoes the most recent local UI operation when undo is available;
- `Command-Shift-Z` redoes it.

Menus and context menus must expose the same actions and enabled/disabled state as
the shortcuts. A shortcut must operate on the currently focused area, not on a
hidden or previously focused area.

### APP-003 — Focus is visible and predictable

XMterm has three primary focus regions:

1. session list;
2. remote file browser;
3. terminal surface.

The active focus region must be visually identifiable. Clicking a region moves
focus there. Opening or closing a terminal tab returns focus to a sensible target:
usually the active terminal surface. Dismissing a dialog restores focus to the
control that opened it.

### APP-004 — Context menus

Right-clicking an item selects that item if it was not already selected, then opens
a context menu. Right-clicking any item in an existing multi-selection preserves
the multi-selection and applies the chosen action to all selected items when the
action supports batches.

### APP-005 — Drag-and-drop feedback

Every drag operation must show:

- what is being dragged;
- the current drop target;
- whether the operation is move, copy, upload, download, or unavailable;
- a clear forbidden cursor when dropping is not allowed.

No remote mutation starts until the drop is committed.

### APP-006 — Destructive actions

Destructive operations must state the number of affected items and their exact
remote parent/location. Batch deletion must not show one dialog per item. A
failed item must not hide the success or failure status of the others.

### APP-007 — Cancellation

Network operations, directory listing, transfers, and reconnect attempts must be
cancellable. Cancellation is a first-class result and must not be reported as an
unknown failure.

### APP-008 — Progress and status

Operations lasting long enough to notice must show state such as queued, running,
completed, cancelled, conflict, or failed. Background activity must never be
represented only by a spinning cursor with no explanation.

## 2. Terminal text interaction

### TERM-SEL-001 — Drag to select terminal text

Dragging over terminal output creates a text selection using rendered terminal
cells. Selection must continue while the pointer is dragged beyond the visible
viewport, with bounded auto-scroll.

The selection is visual only; it must not alter the remote shell input buffer.

### TERM-SEL-002 — Word and line selection

- double-click selects a word using terminal-aware boundaries;
- triple-click selects the full visual line;
- `Shift-click` extends the existing selection to the clicked cell;
- pressing `Escape` clears the current selection before sending Escape remotely;
- clicking without dragging clears the selection and places keyboard focus in the
  terminal.

### TERM-SEL-003 — Selection during mouse-reporting applications

Programs such as `vim`, `less`, `htop`, or `tmux` may enable terminal mouse
reporting. XMterm must preserve a way to force local text selection. The v0.1
contract is:

- normal drag is forwarded to the remote application when mouse reporting is on;
- holding `Option` while dragging always performs local XMterm text selection;
- the behavior is documented in the terminal context menu and Help menu.

### TERM-CLIP-001 — Copy terminal selection

`Command-C` copies the selected terminal text without sending `Control-C` to the
remote process. If no terminal text is selected, `Command-C` does nothing by
default. Sending an interrupt remains `Control-C`.

Copied text must preserve line breaks while avoiding padding spaces that exist
only because of terminal cell width. A preference may later allow preserving
trailing spaces.

### TERM-CLIP-002 — Paste into terminal

`Command-V` pastes clipboard text into the active terminal. Pasting must:

- preserve Unicode text;
- normalize unsupported line endings safely;
- use bracketed paste mode when the remote application enables it;
- warn before sending suspicious multi-line text when paste protection is enabled;
- never rewrite or execute clipboard text silently.

### TERM-CLIP-003 — Terminal context menu

The terminal context menu must include, as applicable:

- Copy;
- Paste;
- Select All Scrollback;
- Select Visible Screen;
- Clear Selection;
- Clear Scrollback;
- Find;
- Copy Current Working Directory when available;
- Open Selection as URL when the selection is a valid URL;
- Reconnect;
- Close Terminal.

### TERM-SCROLL-001 — Scrollback

The user can scroll through terminal history using trackpad, mouse wheel, Page
Up/Down, and scrollbar. New output must not force the view to the bottom while the
user is reading older output. Returning to the bottom resumes follow mode.

### TERM-FIND-001 — Find in terminal history

`Command-F` opens terminal search for the active tab. Search supports next,
previous, case-sensitive toggle, and visible result count. Search must not send
characters to the remote shell.

### TERM-KEY-001 — Terminal keyboard input

The terminal must correctly distinguish Command shortcuts from Control sequences.
At minimum:

- `Control-C`, `Control-D`, `Control-Z`, arrow keys, function keys, Home/End,
  Page Up/Down, Tab, Backspace, Delete, and Escape reach the PTY correctly;
- `Command-C`, `Command-V`, `Command-F`, `Command-T`, and `Command-W` remain local
  application shortcuts;
- Option/Meta behavior is configurable because shells differ.

### TERM-KEY-002 — Control-key byte semantics

XMterm must not reinterpret ordinary `Control` combinations as application
commands. It must encode and send the corresponding control byte to the active
PTY unless the terminal protocol or a documented user preference says otherwise.

The v0.1 baseline is:

| Keys | Byte | Expected terminal meaning |
|---|---:|---|
| `Control-C` | `0x03` (ETX) | Usually causes the remote TTY driver to send `SIGINT` to the foreground process. This is the normal interrupt/terminate-current-command key. |
| `Control-Z` | `0x1A` (SUB) | Usually causes `SIGTSTP`, suspending the foreground job so the shell can resume. |
| `Control-\` | `0x1C` (FS) | Usually causes `SIGQUIT`; the remote program may produce a core dump. |
| `Control-D` | `0x04` (EOT) | In canonical TTY mode, signals end-of-input when the current input line is empty; it may exit a shell. In raw mode, the application receives the byte. |
| `Control-V` | `0x16` (SYN) | Must be forwarded unchanged. Many shells/readline configurations use it as “quoted insert” for the next character. It is **not** paste and is **not** terminate. |
| `Control-S` | `0x13` (XOFF) | May pause terminal output when software flow control is enabled. |
| `Control-Q` | `0x11` (XON) | May resume output paused by `Control-S`. |
| `Control-L` | `0x0C` (FF) | Commonly asks the shell/application to clear or redraw the screen. |
| `Control-R` | `0x12` (DC2) | Commonly starts reverse history search in readline-compatible shells. |
| `Control-A` / `Control-E` | `0x01` / `0x05` | Commonly move to beginning/end of the input line in Emacs/readline mode. |
| `Control-U` / `Control-K` | `0x15` / `0x0B` | Commonly delete from cursor to beginning/end of line in readline mode. |
| `Control-W` | `0x17` | Commonly deletes the previous word in shells. It must not close an XMterm tab; closing a tab is `Command-W`. |
| `Control-H` | `0x08` (BS) | Backspace control byte; physical Backspace/Delete mapping remains configurable. |
| `Control-I` | `0x09` (TAB) | Equivalent to Tab. |
| `Control-J` | `0x0A` (LF) | Line feed. |
| `Control-M` | `0x0D` (CR) | Equivalent to Return/Enter for ordinary terminal input. |
| `Control-[` | `0x1B` (ESC) | Equivalent to Escape. |

These are byte-delivery rules, not promises about shell behavior. The remote TTY
mode and active application decide what each byte actually does. XMterm must not
kill, suspend, clear, or edit the remote process locally in response to these keys.

### TERM-KEY-003 — Local Command shortcuts versus remote Control input

The following distinction is mandatory on macOS:

- `Command-C` copies an XMterm terminal selection; `Control-C` sends interrupt;
- `Command-V` pastes clipboard text; `Control-V` sends `0x16`;
- `Command-W` requests closing the active tab; `Control-W` is sent remotely;
- `Command-T` launches the first saved login-shell profile or opens the picker when
  none exists; `Control-T` is sent remotely;
- `Command-F` opens local terminal-history search; `Control-F` is sent remotely;
- `Command-A` selects terminal history according to the focused terminal command;
  `Control-A` is sent remotely.

Holding `Shift` with a Control sequence must not silently convert it into a
Command shortcut. Menu commands must never steal a Control sequence merely because
the focused remote program also uses that key.

### TERM-KEY-004 — Special keys, Unicode, and repeat behavior

XMterm must provide xterm-compatible encoding for:

- arrow keys and modified arrow keys;
- Home, End, Insert, Forward Delete, Page Up, and Page Down;
- function keys;
- numeric keypad keys where distinguishable;
- Return, Tab, Backspace, Escape, and key repeat;
- Unicode text produced by macOS input methods, dead keys, and composed characters.

Application cursor-key mode, keypad mode, bracketed paste, and alternate-screen
mode must be obeyed. Option/Meta has a user preference with at least these modes:

1. send Escape-prefixed Meta;
2. type the macOS character;
3. no special Option remapping.

### TERM-PROC-001 — Interrupt, suspend, EOF, and tab-close are different actions

XMterm must keep these concepts separate:

- interrupt current foreground command: `Control-C`;
- suspend current foreground job: `Control-Z`;
- send end-of-input: `Control-D`;
- request quit/core-dump behavior: `Control-\`;
- close the XMterm terminal tab and its SSH session: `Command-W` or the tab close button.

Closing a connected tab may end the remote shell and any foreground process tied
to that SSH connection. The confirmation text must say this explicitly. A tab
close must not be implemented by injecting `exit`, `Control-C`, or `Control-D` into
the remote shell because those actions have different semantics.

## 3. Terminal tab interaction

### TAB-001 — Create terminal

- the pinned `+` button opens the searchable saved-session picker and does not
  start a process by itself;
- `Command-T` launches the first saved login-shell local profile in stable saved
  order; if no saved login-shell profile exists, it opens the picker;
- Return on the selected picker result and double-clicking a saved session open a
  terminal for that profile;
- the picker can choose any remembered local or SSH session and provides entry
  points for creating and managing saved profiles.

### TAB-002 — Select and reorder tabs

- clicking a tab activates it;
- `Command-1` through `Command-9` select terminal tabs;
- `Command-Shift-[` and `Command-Shift-]` move between adjacent tabs;
- tabs can be reordered by dragging;
- horizontal tab scrolling appears when tabs do not fit;
- the selected tab stays visible after creation, activation, or reorder.

### TAB-003 — Close tabs

- the close button and `Command-W` close only the active terminal tab;
- middle-click closes the clicked tab when supported by the pointing device;
- for a local PTY, XMterm compares the terminal foreground process group from
  `tcgetpgrp` with the recorded local-shell process group;
- a local shell that owns the foreground terminal is treated as idle and closes
  immediately; a different foreground process group receives one concise
  confirmation;
- a completed foreground process returns to immediate-close behavior, and
  background jobs do not trigger the foreground-job warning merely by existing;
- an already closed/reaped local PTY closes immediately; an unexpected foreground
  query failure on an otherwise-live PTY receives one conservative confirmation
  whose text does not claim that a job is definitely running;
- XMterm cannot reliably distinguish an idle remote shell from an active remote
  foreground process without shell integration, so a connected SSH terminal uses
  the conservative remote confirmation policy;
- a confirmation states which connection or local shell will end and that tied
  foreground work may be terminated;
- closing a disconnected, failed, or already exited tab is immediate;
- closing one tab closes only that tab's session-owned workspace and terminal; it
  must not terminate another tab's workspace, provider, or terminal.

### TAB-004 — Tab context menu

The tab context menu includes:

- Rename;
- Duplicate Connection;
- Reconnect;
- Close;
- Close Other Tabs;
- Close Tabs to the Right;
- Copy SSH Alias or connection description.

### TAB-005 — Status indication

Each tab shows a non-color-only indication for connecting, connected, reconnecting,
exited, or failed. Hover/help text provides the exact status. Activity in a
background tab may show a subtle unread-output indicator.

## 4. Remote file browser interaction

### FILE-SEL-001 — Single and multiple file selection

The remote file browser supports:

- single selection by click;
- discontiguous multi-selection with `Command-click`;
- contiguous range selection with `Shift-click`;
- `Command-A` to select all currently loaded visible entries;
- keyboard selection with arrow keys and Shift modifiers;
- preservation of selection after a refresh when the same remote paths still
  exist.

Batch-capable actions operate on the complete selection. Actions that require one
item, such as Rename, are disabled when selection count is not exactly one.

### FILE-NAV-001 — Open and navigate

- double-clicking a directory opens or expands it;
- double-clicking a supported file opens it in the configured local editor;
- `Return` renames one selected item, matching Finder behavior;
- `Command-Down` opens the selected directory or file;
- `Command-Up` navigates to the parent directory;
- Back and Forward restore directory, scroll position, and selection where
  possible;
- a path bar allows copying and direct navigation to an absolute remote path.

### FILE-CLIP-001 — Copy, cut, and paste remote files

The file browser supports normal file clipboard operations:

- `Command-C` copies selected remote entries;
- `Command-X` marks selected remote entries for move;
- `Command-V` pastes into the current remote directory;
- the context menu exposes Copy, Cut, and Paste;
- copied entries retain their exact source session and remote paths;
- paste shows copy/move progress and handles name collisions explicitly.

The app must not confuse file clipboard content with copied terminal text. Clipboard
actions are routed by keyboard focus and represented using a private pasteboard
format plus human-readable paths where useful.

### FILE-DND-001 — Drag remote items

Dragging selected remote files or folders:

- within the same session moves them by default;
- holding `Option` copies them instead;
- across sessions performs copy through the local transfer layer and never implies
  an atomic remote rename;
- onto a directory targets that directory;
- onto empty space targets the current directory;
- moving a directory into itself or a descendant is rejected before network work.

### FILE-DND-002 — Drag between Finder and XMterm

- dragging local Finder files into the remote file browser uploads them;
- dragging remote files from XMterm into Finder downloads them;
- multiple files and folders are supported;
- drag promises or temporary download locations must be cleaned up safely;
- conflicts use the same Replace, Keep Both, Skip, and Apply to All choices as
  toolbar-based transfers.

### FILE-OPS-001 — Required file operations

The v0.1 browser supports the following for one or many selected entries where
meaningful:

- Open in configured editor;
- Open With…;
- Download;
- Upload Here;
- Copy;
- Cut;
- Paste;
- Move;
- Rename;
- Duplicate;
- Delete;
- New File;
- New Folder;
- Refresh;
- Copy Remote Path;
- Copy SSH/SCP Reference;
- Open Terminal Here;
- Show Hidden Files.

### FILE-OPS-002 — Collision handling

Copy, move, upload, and download must never silently overwrite an existing item.
The collision sheet provides:

- Replace;
- Keep Both with a predictable generated name;
- Skip;
- Cancel operation;
- Apply this choice to all remaining collisions.

### FILE-OPS-003 — Delete behavior

Because ordinary SFTP servers do not provide a universal Trash:

- Delete clearly states that remote deletion may be permanent;
- the confirmation lists the exact parent path and selection count;
- deleting a non-empty directory requires explicit confirmation;
- partial batch failures remain visible per item;
- no item is removed from the UI until the server confirms deletion.

### FILE-LIST-001 — Listing and sorting

The browser displays name, kind, size, modified time, and permissions when
available. It supports sorting by name, kind, size, and modified time without
re-fetching the directory when the necessary metadata is already loaded.

Directories remain visually distinguishable from files. Hidden files are hidden by
default but can be toggled per window/session.

### FILE-PERF-001 — Lazy loading

Opening a directory lists only its immediate children. XMterm must not recursively
scan remote descendants for selection, drag, search, or size calculation unless the
user explicitly initiates an operation that requires it.

### FILE-WORKSPACE-001 — Session-scoped read-only workspace

Every launched SSH runtime may own one Remote Workspace capability created from its
immutable launch snapshot. A local runtime owns no remote-file provider, cache, or
background remote task. Two tabs launched from the same saved profile have
independent providers, navigation, history, selection, expanded directories,
caches, requests, and failures.

The Phase 4A workspace lists and navigates only. It must not expose mutation,
transfer, file-opening, editor-sync, terminal-directory-following, or
remote-object clipboard actions as if they were available.

### FILE-NAV-002 — Transactional navigation, history, and refresh

The provider resolves the actual initial remote directory. XMterm publishes that
directory, an opened child, Parent target, Back/Forward target, or breadcrumb
ancestor as current only after the target listing succeeds. A failed or cancelled
target leaves the prior current directory and history intact and displays the
failure honestly.

Successful ordinary navigation pushes the previous location onto Back and clears
Forward. Back and Forward are reciprocal and restore selection and scroll position
where exact identities remain valid. Refresh reloads only the current directory,
does not add history, and retains selection only when the same exact remote path is
still present. Newer requests supersede older requests; cancelled or stale results
must never overwrite a newer location or another session's state.

### FILE-CACHE-001 — Bounded per-session lazy directory cache

Every Remote Workspace owns a bounded immediate-child listing cache. Cache entries
are keyed by exact structured remote paths, replaced atomically, evicted
deterministically, and cleared when the owning runtime closes. Refresh invalidates
or replaces only its requested directory; one child failure does not clear
unrelated successful listings.

Opening or expanding a directory lists that directory only. The cache must not
trigger prefetch, recursive enumeration, symlink traversal, polling, descendant
size calculation, or a per-entry task explosion. Provider response bytes, entry
counts, path/component lengths, concurrent requests, and diagnostic data are
explicitly bounded.

### FILE-STATE-001 — Honest workspace and directory states

Workspace availability distinguishes local-session unavailability, idle,
connecting, initial loading, available, failed, closing, and closed. Every current
or expanded directory distinguishes not loaded, loading, loaded, empty, failed,
and cancelled. Loading failure is never presented as an empty directory, and a
child error remains scoped to that child with Retry where meaningful.

Remote I/O does not run on `MainActor`; observable UI publication does. Every task
is owned and cancellable by the exact runtime session. Closing a session cancels
its provider work, while switching tabs cannot route an inactive completion into
the selected session.

### FILE-COPY-001 — Exact remote path text actions

The selected entry and current directory expose Copy Path, Copy Name, Copy Parent
Directory, and Copy Shell-Quoted Path where meaningful. The shell-quoted form uses
POSIX-safe single-quote encoding, including embedded apostrophes. A copy writes
plain text without sending Return or executing anything.

Exact-text actions are enabled only when the underlying raw remote path has a
lossless text representation. Safe escaped display text must not be mislabeled as
the exact path. These actions do not implement the private remote-entry clipboard,
Cut, Paste, move, or batch behavior required by later phases.

## 5. Local editor and automatic upload

### EDIT-001 — Open remote file locally

Opening a remote text file:

1. confirms the file is within configured size/type limits;
2. downloads it to a session-scoped cache preserving a safe filename;
3. records the session ID, exact remote path, remote metadata, and local URL;
4. launches the configured local editor, initially Visual Studio Code;
5. begins watching the containing cache directory for atomic-save behavior.

Opening the same remote file again focuses/reuses its existing local mapping rather
than creating competing cache copies unless the user explicitly requests another
copy.

### EDIT-002 — Detect save reliably

XMterm must handle both in-place writes and atomic-save patterns where an editor
writes a temporary file and renames it over the original. Events are debounced so
one editor save produces one logical upload whenever possible.

Temporary editor files, lock files, swap files, and unrelated files in the cache
folder are ignored.

### EDIT-003 — Upload on save

When the mapped local file changes:

- state becomes `Pending Upload` then `Uploading`;
- XMterm checks available remote modification metadata;
- if no conflict exists, the file uploads to the exact original path;
- success becomes `Synced` and updates the stored fingerprint/metadata;
- failure becomes `Failed` with Retry and Reveal Details actions;
- repeated saves while an upload is active coalesce into a later upload rather than
  racing or losing the newest content.

### EDIT-004 — Conflict behavior

If the remote file changed after it was downloaded or last uploaded, XMterm must
not silently overwrite it. The conflict UI offers:

- Download Remote and Replace Local;
- Upload Local and Replace Remote;
- Keep Both;
- Open Both for comparison using the configured editor;
- Cancel and leave the mapping in Conflict state.

### EDIT-005 — Multiple open files

Many remote files can be open in VS Code simultaneously. Each mapping has its own
status and remote destination. Saving one file must never upload another file.

### EDIT-006 — App quit and cache lifecycle

If XMterm is quit while files are being watched or uploads are pending, it warns
about unsynced changes. The cache can survive normal restarts so mappings may be
recovered, but users can clear cached content from Settings. Cache files are never
executed automatically.

## 6. Session and authentication behavior

### SESS-001 — Remembered sessions

XMterm reads aliases from `~/.ssh/config` and may store non-secret presentation
settings such as display name, favorite status, initial remote path, and preferred
editor. It must not copy or persist private keys, passwords, or OTP values.

### SESS-002 — Connection actions

A session supports:

- Open Terminal;
- Open Another Terminal;
- Connect File Browser;
- Edit non-secret profile metadata;
- Duplicate profile presentation settings;
- Remove from XMterm favorites without altering `~/.ssh/config`.

### SESS-003 — Authentication prompts

Host-key, passphrase, password, and OTP prompts must be visible in a trusted,
understandable flow. XMterm must not claim that key authentication bypasses a
server policy that still requires OTP.

## 7. Minimum keyboard shortcut map

| Action | Shortcut |
|---|---|
| New terminal | `Command-T` |
| Close active terminal | `Command-W` |
| Next/previous tab | `Command-Shift-]` / `Command-Shift-[` |
| Select terminal 1–9 | `Command-1` … `Command-9` |
| Copy focused selection | `Command-C` |
| Cut selected remote files | `Command-X` |
| Paste into focused terminal/file browser | `Command-V` |
| Select all in focused region | `Command-A` |
| Find in active terminal | `Command-F` |
| Clear terminal scrollback locally | `Command-K` |
| Reopen recently closed terminal profile | `Command-Shift-T` |
| Refresh remote directory | `Command-R` |
| New remote folder | `Command-Shift-N` when remote files are focused |
| Rename one remote item | `Return` |
| Open selection | `Command-Down` |
| Parent directory | `Command-Up` |
| Delete selected remote items | `Command-Delete` |
| Focus session sidebar | `Control-1` |
| Focus remote files | `Control-2` |
| Focus terminal | `Control-3` |

Shortcuts that conflict with terminal applications must be configurable or scoped
carefully. The menu bar remains the source of truth for discoverability.

## 8. Accessibility and input devices

### A11Y-001 — Keyboard-only operation

Every primary workflow must be possible without a mouse: choose session, create and
close a tab, navigate remote files, select multiple files, invoke file actions,
focus the terminal, copy terminal output, paste input, and inspect operation status.

### A11Y-002 — VoiceOver and labels

Buttons that use only icons require accessibility labels and help text. Terminal
tab status, transfer status, selection counts, and destructive confirmations must
not rely on color alone.

### A11Y-003 — Trackpad and mouse

Trackpad scrolling, momentum scrolling, secondary click, middle click when present,
and drag-and-drop must behave consistently. Pointer targets must remain usable at
normal and increased display scaling.

## 9. Terminal compatibility and connection recovery

### TERM-SEL-004 — Wrapped lines, block selection, and drag export

Copying a soft-wrapped terminal line must not insert a newline solely because the
window wrapped it. Hard line breaks remain line breaks. Selection is represented in
terminal buffer coordinates and remains correct across wide Unicode cells.

Rectangular/block selection must either be implemented with a documented modifier
or explicitly marked deferred until the chosen terminal engine can implement it
without corrupting Unicode and wrapped-line behavior. Selected terminal text may be
dragged to another macOS text destination as plain text.

### TERM-RENDER-001 — Advertised terminal capabilities are real

XMterm must use a real PTY and implement the terminal behavior it advertises through
`TERM`. At minimum, the selected compatibility profile covers cursor addressing,
scroll regions, normal/alternate screen buffers, application cursor/keypad modes,
SGR attributes, 256 colors, true color when advertised, bracketed paste, mouse
reporting, cursor state, and safe handling of unknown control sequences.

XMterm must not set `TERM=xterm-256color` merely because that value is common; the
selected terminal engine must pass the corresponding verification first.

### TERM-RENDER-002 — Unicode width and decoding

The terminal must decode UTF-8 across read boundaries and render combining marks,
CJK wide characters, emoji, variation selectors, zero-width sequences, and non-BMP
characters without corrupting cursor position, selection, or copied text. Cell width
is not derived from Swift character count.

### TERM-RESIZE-001 — Resize and reflow

Resizing updates PTY rows and columns and notifies the child process through normal
PTY semantics. Resize events are coalesced while dragging. Soft-wrapped history is
reflowed where supported; if exact selection preservation is impossible, the
selection is visibly cleared rather than silently changed.

### TERM-LINK-001 — Links require explicit user action

OSC 8 links and detected plain-text URLs may be shown as links. Hover reveals the
destination and `Command-click` opens a supported URL. Unsafe or unusual schemes
require confirmation. Remote output can never open a URL automatically.

### TERM-BELL-001 — Bell and attention behavior

Terminal bell behavior is configurable as off, visual, sound, inactive-tab
attention, or optional notification. Repeated bells are rate-limited and status is
not communicated by color alone.

### TERM-STATE-001 — Exit, disconnect, and reconnect

When the PTY/SSH process exits, the tab preserves scrollback and selection, displays
exit/disconnect information, and disables input. Reconnect creates a fresh SSH
process using the same profile. It does not claim to restore the previous remote
shell, working directory, or foreground job.

### TERM-SEC-001 — Remote clipboard control sequences

Remote clipboard read requests such as OSC 52 are denied by default. Clipboard write
requests are denied or require explicit permission according to a visible setting.
Payloads are size-bounded and denied sequences must not appear as raw text or crash
the terminal.

## 10. SSH resolution and lifecycle

### SESS-004 — Delegate effective configuration to OpenSSH

XMterm may discover explicit aliases for presentation, but it must not reproduce the
full semantics of OpenSSH configuration in application code. Effective settings are
resolved by system OpenSSH, using `ssh -G` for inspection where required. `Include`,
wildcards, `Match`, ProxyJump, tokens, identity selection, canonicalization, and
host-key rules remain OpenSSH responsibilities.

Process arguments are passed as an argument array and never through an interpolated
shell command.

### SESS-005 — Network loss, sleep, wake, and reconnect

Connection state distinguishes resolving, connecting, authenticating, connected,
disconnected, exited, failed, cancelled, and reconnecting. Sleep/wake or network
changes must not leave a dead process labelled Connected. Automatic reconnect is
opt-in for interactive terminals because reconnect creates a new shell. Manual
Reconnect is always available.

### SESS-006 — Terminal and SFTP authentication coordination

Terminal and SFTP are independently recoverable capabilities of one launched
runtime session.
When the backend can safely reuse an authenticated transport or trusted OpenSSH
multiplexed connection, opening the file browser must avoid a duplicate password or
OTP prompt. If reuse is unavailable, XMterm states that a separate connection is
being opened and may prompt again.

A failed file-browser connection must not close or relabel the terminal. Closing a
runtime closes that exact runtime's file browser and terminal, but must not close
another runtime's file browser, provider, or terminal. This session-owned lifetime
supersedes the older shared/profile-owned file-browser interpretation.

### SESS-007 — Saved templates and launched-session identity

A saved session profile is a reusable launch template, not a running terminal.
Launching a profile creates an immutable launch snapshot for the new tab. The
saved-profile ID, terminal-tab ID, terminal-session ID, and native process identity
are distinct; opening the same profile more than once creates independent tab,
session, and process identities each time.

Editing, renaming, favoriting, or deleting a saved profile must not reconfigure,
rename, close, or otherwise mutate a terminal tab that was already launched from
it. Renaming a launched tab likewise must not modify the saved profile.

### SESS-008 — Durable profile persistence and explicit recovery

Saved profiles use a schema-versioned JSON document written through
same-directory staging and atomic replacement. Built-in defaults are persisted
exactly once when the store has never been initialized. A valid persisted empty
profile collection is initialized state and must not be reseeded.

Corrupt, partially recoverable, or unsupported documents are preserved rather
than silently overwritten or downgraded. XMterm presents an explicit recovery
state and requires the user to choose whether to accept recovered profiles or
reset to defaults before normal profile mutations resume.

Every profile mutation persists the proposed immutable collection before
publishing it. A failed write leaves the previously published profile collection
observable and offers an honest error/retry path; in-memory UI state must not claim
that an unpersisted mutation succeeded.

### SESS-009 — Searchable session picker, recency, and focus

The pinned new-session control opens a searchable picker without starting a
process. The picker exposes recent, favorite, SSH, and local profiles without
duplicating a profile row, and provides actions to create and manage profiles.
Recency changes only after a new tab/session pair has been created successfully;
opening, searching, highlighting, or dismissing the picker does not change it.

The picker focuses search when opened. Up and Down move the stable profile
selection, Return opens the selected profile, and Escape dismisses the picker.
Pointer activation remains available. Dismissal restores focus to the created
terminal or, when no launch occurred, to the new-session control or previous
sensible target.

### SESS-010 — Profile editing, validation, and deletion isolation

Users can create, edit, duplicate, favorite or unfavorite, and delete saved local
and SSH profiles. Editing occurs in an isolated draft with field-specific
validation; invalid drafts cannot be saved, and typing alone never persists a
change. Direct-host and SSH-config-alias fields are mutually exclusive when saved,
and credential material is never accepted as profile metadata.

Cheap structural validation may run synchronously while editing. Filesystem
existence, executable, file-kind, and working-directory checks run only at an
explicit Save or launch boundary, never on the per-keystroke draft path. Failures
remain attached to the relevant saved profile or editor field without publishing a
partial mutation.

Duplicating creates a new profile identity. Deleting requires a confirmation that
names the profile and states that existing terminal tabs will remain open. Create,
edit, duplicate, favorite, and delete operations affect saved templates only and
must preserve all already-launched tab snapshots and runtime sessions.

### SESS-011 — Session-owned runtime capabilities

A launched runtime is the owner of independently failing sibling capabilities. In
Phase 4A those capabilities are the retained terminal and, for an SSH launch target,
an optional Remote Workspace. Capability eligibility and configuration come from
the immutable launch snapshot, not from a mutable saved profile or a coarse tab
presentation kind.

Starting a runtime starts its capabilities independently. Remote Workspace loading
or failure must not block terminal publication, recreate its retained view, change
terminal lifecycle, or stop its process. Closing a runtime cancels and releases all
of its owned capability work before aggregate cleanup completes. State and results
are always keyed to the exact launched runtime identity.

## 11. Remote metadata and transfer integrity

### FILE-META-001 — Permissions, executable bits, and symlinks

Remote entries distinguish regular files, directories, symlinks, and special files
when metadata is available. Editor saves preserve the original remote mode,
especially executable bits. Deleting a symlink deletes the link, not its target.
Opening a symlinked text file must not replace the symlink accidentally.

Ownership changes are not part of ordinary save behavior. Unsupported metadata is
shown as unavailable rather than guessed.

### FILE-XFER-001 — Explicit per-item transfer state

Uploads, downloads, copies, and moves expose queued, preparing, transferring,
verifying, completed, cancelled, conflict, and failed states. Batch operations show
aggregate progress plus per-item failures. Cancellation is not reported as an
unknown error.

### FILE-XFER-002 — No partial destination presented as success

Downloads stage into a temporary local file and replace the final local destination
only after success. Uploads and editor-sync writes use a temporary file in the same
remote directory and a safe final rename where supported. A revision is not marked
Synced until the server confirms the final path.

If the server cannot provide safe replace semantics, XMterm exposes the reduced
guarantee rather than claiming atomicity.

### FILE-XFER-003 — Retry and offline ordering

A newer local revision supersedes an older queued revision for the same remote
mapping. An older retry must never overwrite a newer successful upload. Network
retry is bounded and stops on host-key or authentication failures. Pending uploads
refresh remote conflict metadata before resuming after reconnect.

### FILE-XFER-004 — Exact remote path identity

Remote operations use structured paths/protocol APIs and must support spaces,
quotes, leading dashes, Unicode, and other legal names without shell injection.
Control characters are displayed safely while preserving exact internal path
identity.

## 12. Editor-sync safety additions

### EDIT-007 — Complete-revision upload and metadata preservation

Auto-sync uploads a complete new revision using the transfer-integrity rules. It
preserves the original remote permission mode, detects remote rename/delete where
possible, and does not mark success while only a temporary file exists.

If a save occurs while disconnected, the newest local revision remains Pending
Upload. XMterm does not upload it after reconnect until remote conflict metadata is
refreshed. Binary or oversized files require an explicit open/edit decision.

## 13. Native macOS application behavior

### MAC-001 — Menu and focused-command parity

Menu-bar, toolbar, context-menu, and keyboard commands use the same action and
availability logic. Cut, Copy, Paste, Select All, Find, Close, Refresh, and file
actions target the focused region only.

### MAC-002 — Window close and application quit

Closing a terminal, closing a window, and quitting XMterm are different actions.
Window close and app quit account for connected terminals, active transfers, and
unsynced editor mappings. The user receives one understandable aggregate decision,
not one dialog per item.

For local terminals, an idle shell does not contribute to the aggregate warning.
Only a known foreground job or an exceptional live-PTY query failure requires
confirmation; exited, failed, closed, and idle local terminals shut down directly.
Remote activity detection remains a separate SSH concern.

### MAC-003 — Restoration and recently closed terminals

XMterm may restore window geometry, sidebar width, profile tabs, tab order, custom
names, and last remote path. Restored terminal tabs are disconnected placeholders
unless the user enabled reconnect. `Command-Shift-T` may reopen the most recently
closed profile as a fresh connection; it cannot restore the old remote process.

### MAC-004 — Settings cover habitual terminal behavior

At minimum, Settings define terminal font/zoom, appearance, scrollback limit,
Option/Meta mapping, Backspace mapping, word-selection characters, paste protection,
copy-on-select, bell, hidden files, directories-first sorting, transfer concurrency,
editor choice, cache management, close confirmations, and privacy-safe diagnostics.
Per-profile overrides are explicit and resettable.

### MAC-005 — Dragging paths into terminal

Dragging a remote item from the file browser into its associated terminal inserts a
shell-quoted remote path and sends no Return. Dragging a local Finder item into a
remote terminal must not insert a misleading local-only path without explanation;
XMterm may offer Upload to Current Remote Directory or cancel.

### MAC-006 — Privacy-safe diagnostics and notifications

Diagnostic exports exclude terminal contents, remote file contents, secrets, and
full internal identifiers by default. Notifications are optional and hide sensitive
host/path details on the lock screen unless the user enables them.

## 14. Interaction completion rule

A UI feature is not complete until all applicable behavior is covered:

- pointer interaction;
- keyboard shortcut;
- focus handling;
- single and multi-selection;
- clipboard behavior;
- context menu;
- drag-and-drop if items are movable;
- progress and cancellation;
- empty, loading, error, and disconnected states;
- accessibility labels;
- tests or a documented manual verification case.

Use `docs/checklists/interaction-parity.md` during implementation and review.
