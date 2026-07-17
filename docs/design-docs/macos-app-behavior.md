# macOS Application Behavior and Settings

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** Native menus, windows, tabs, settings, restoration, notifications,
  appearance, and application lifecycle
- **Canonical requirements:** `MAC-001` through `MAC-006`, `APP-*`, `A11Y-*`

## Goal

XMterm should feel like a native macOS application. Users should not need to learn
special rules for actions that Finder, Terminal, and browser-style tab interfaces
already make habitual.

## Menu bar

XMterm provides standard menus with correct enabled states based on focus:

### File

- New Terminal Tab;
- New Window if multi-window support is enabled;
- Open Session;
- Close Tab;
- Close Window;
- Open Remote File in Editor;
- Download/Upload where applicable.

### Edit

- Undo/Redo for local UI operations where supported;
- Cut/Copy/Paste routed to the focused region;
- Select All routed to the focused region;
- Find for the active terminal or focused list.

### View

- Show/Hide Sidebar;
- Show/Hide Transfer Activity;
- Show Hidden Files;
- Increase/Decrease/Reset Terminal Font Size;
- Enter Full Screen;
- Focus Session List, Remote Files, or Terminal.

### Terminal

- New/Duplicate/Reconnect/Rename/Close Terminal;
- Clear Scrollback;
- Reset Terminal;
- Send selected special key through an optional menu for discoverability;
- paste-protection control.

### Window and Help

Standard macOS window navigation, recently closed terminal recovery where
supported, keyboard shortcut reference, and security/help documentation.

Menu items and context-menu items must share the same command implementation and
enabled state.

## Window and tab lifecycle

For v0.1, a single-window implementation is acceptable, but models must not assume
there can only ever be one window.

- Closing a terminal tab closes only that tab.
- Closing a window evaluates connected terminals, running transfers, and unsynced
  editor mappings.
- An idle local shell closes without a warning. A known local foreground job or an
  exceptional live foreground-query failure contributes to the tab/window/quit
  confirmation; exited, failed, and closed local PTYs do not.
- Quitting the app performs the same checks across all windows.
- `Command-Shift-T` reopens the most recently closed terminal profile as a fresh
  connection while restoring its title/settings and optionally retained scrollback;
  it cannot restore the remote process.
- Tab overflow uses scrolling or an overflow menu; tabs must not shrink until close
  buttons and status become unusable.
- Drag reorder preserves terminal state.
- Detaching a tab into another window is deferred unless implemented completely.

**Phase 2 tab-strip implementation status:** fitting tabs use the exact 180-point
preferred width and a content-sized, non-greedy viewport. As width narrows, all tabs
shrink equally to 120 points; below that threshold they remain 120 points and the
viewport scrolls horizontally. In Phase 2, the local/relay `+` menu was a fixed,
non-scrolling sibling immediately after the viewport, with at least 8 points before
the separate remaining toolbar region. Selected-tab reveal is requested after
creation, click activation, replacement selection on close, and resize. Initial and
tab/selection requests settle for 16 ms before exactly one final scroll; initial
reveal is unanimated and only tab/selection changes may animate. Viewport-only
requests use a 75 ms cancellation-coalesced unanimated debounce. Reduce Motion
removes the optional tab/selection animation while preserving final layout and
selection.

The source/automated slice is implemented, and staged inspection verified rendered
content sizing, equal shrink, horizontal overflow, pinned `+`, actual selected-tab
reveal after activation/create/close/resize, menu contents/dismissal, and AX
tab/menu/toolbar structure. Physical trackpad momentum, long-title rendering, full
keyboard traversal, actual VoiceOver, visual Reduce Motion, and relay invocation
remain pending. Drag reorder and reveal
after reorder, tab-number/adjacent-tab shortcuts, recently closed tabs,
restoration, Settings, and new toolbar actions remain deferred.

**Phase 3 Session Manager status:** the pinned `+` now opens a native popover whose
search field receives focus. File-menu commands expose New Terminal, Choose
Session, and Manage Sessions. The picker supports stable keyboard selection and
launch, favorite actions, and explicit loading/empty/error/recovery presentations;
the native manager/editor provides create, edit, duplicate, and confirmed delete.
Escape dismisses the picker and restores focus to the `+`; a successful launch
restores terminal focus. `Command-T` launches the first saved login-shell profile
and opens the picker when none exists. Profile drafts validate structurally while
typing but defer filesystem checks until save or launch.

The Session Manager observes system light/dark appearance and Reduce Motion, and
its launch/favorite controls expose descriptive accessibility labels/actions.
Exact packaged-app outcomes and any limitation of AX inspection versus an actual
VoiceOver auditory pass are recorded in
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md)
and
[`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).
This phase adds no Settings surface, window restoration, SFTP, remote browser, or
editor integration.

## State restoration

XMterm may restore:

- window size and sidebar width;
- selected session/profile;
- terminal profile tabs as disconnected placeholders;
- tab order, custom tab names, and appearance;
- last remote browser path per profile;
- safe local cache mappings and unsynced state.

XMterm must not automatically reconnect every terminal after launch unless the user
has enabled that behavior. Restored tabs clearly indicate that they are not yet
connected.

## Settings

Settings are searchable and separated into:

### General

- reopen previous windows/tabs;
- close confirmation behavior;
- default local editor and custom editor command;
- cache location/size and clear-cache action;
- notification behavior;
- update channel when updates exist.

### Terminal

- font family and size;
- light/dark/system color scheme;
- cursor shape and blink;
- scrollback limit;
- copy-on-select preference, off by default unless the user enables it;
- word-selection characters;
- Option/Meta behavior;
- Backspace mapping;
- paste protection;
- local selection modifier during mouse reporting;
- bell behavior;
- terminal identity compatibility profile.

### Files and transfers

- show hidden files;
- directories-first sorting;
- default upload/download collision behavior;
- transfer concurrency;
- preserve timestamps/mode preferences;
- editor size and binary thresholds;
- auto-upload enabled per profile or globally.

### SSH

- default behavior is to respect `~/.ssh/config`;
- no private-key import into XMterm;
- sanitized diagnostics controls;
- optional connection-reuse setting only when the backend supports it safely.

Per-profile overrides are explicit and can be reset to global defaults.

## Native drag and path insertion

- Dragging selected terminal text to another app exports plain text.
- Dragging a remote file from the sidebar into its associated terminal inserts a
  shell-quoted remote path and sends no Return.
- Multiple paths are separated safely for shell use.
- Dragging a Finder file into the remote file browser uploads it.
- Dragging a Finder file into a remote terminal must not insert a misleading local
  path without explanation; XMterm may offer Upload to Current Remote Directory or
  cancel.

## Notifications and attention

Notifications are optional and reserved for meaningful background events such as:

- transfer completed or failed while XMterm is not frontmost;
- editor upload conflict;
- terminal bell when configured;
- disconnected session when configured.

Notifications do not expose remote paths or hostnames on the lock screen unless the
user enables detailed notifications.

## Appearance and accessibility

- System light/dark appearance is supported.
- Font scaling does not clip tab titles or controls.
- Increased contrast and Reduce Motion retain all status meaning.
- Terminal status, conflicts, and transfer failures use text/icon labels in addition
  to color.
- Full keyboard access and VoiceOver traversal are verified for sessions, remote
  files, tab strip, terminal controls, and transfer status.

## Diagnostics and privacy

A user can export a sanitized diagnostic bundle containing app version, macOS
version, configuration flags, state transitions, and non-secret errors. The bundle
excludes terminal contents and remote file contents by default.

Logs are size-bounded and rotate locally. Debug logging requires explicit opt-in.
