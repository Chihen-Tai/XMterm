# XMterm Product Definition

## One sentence

XMterm is a lightweight, native macOS SSH/SFTP client that combines MobaXterm-style
remote file access with browser-like terminal tabs and local-editor auto-sync.

## Primary user

A macOS user working through SSH jump hosts, HPC clusters, research servers, or
ordinary Linux machines who wants a stable terminal and familiar remote file
operations without running a remote IDE server.

## Product character

XMterm is terminal-first, but it must not be terminal-only.

The dominant area is the terminal. The remote file browser is a companion to the
active connection and must still provide the ordinary interactions users expect
from Finder or VS Code: single and multiple selection, copy, cut, paste, drag and
drop, rename, move, download, upload, and contextual actions.

“Lightweight” does not mean omitting routine desktop behavior. It means avoiding a
remote server, recursive indexing, bundled browser runtime, and unrelated IDE
features while implementing the chosen workflows completely.

## Implemented product slice

Phases 1 through 3 implement the native terminal and saved-session foundation.
Users can keep local, direct-host SSH, and manually entered SSH-config-alias
profiles; search them by name, host, or user; organize them through
Recent/Favorites/SSH/Local sections; manage them with native create, edit,
duplicate, favorite, and delete flows; and launch independent terminal tabs.

Saved profiles are launch templates. Each tab retains an immutable launch snapshot
and source-profile provenance, so later edits or deletion do not mutate or close a
running tab. XMterm persists only non-secret profile metadata and delegates SSH
authentication and configuration semantics to `/usr/bin/ssh`. Automatic
`~/.ssh/config` alias discovery/import and `ssh -G` presentation are not yet
implemented.

This implemented slice does not include SFTP, the remote file browser, local editor
sync, reconnect, ProxyJump editing, automatic second hops, or distribution approval.
Those remain roadmap requirements below; the exact Phase 3 packaged-app evidence
and manual limitations are recorded in
[`docs/audits/0005-phase-3-session-manager-evidence.md`](docs/audits/0005-phase-3-session-manager-evidence.md).

## Core workflow

1. Select a saved local or SSH profile.
2. Open one or more terminal tabs using the user's existing OpenSSH setup.
3. Use the terminal normally, including drag text selection, copy/paste, search,
   and scrollback.
4. Browse the active connection's remote files from the left sidebar.
5. Select one or many files using normal macOS gestures and perform file actions.
6. Double-click a text file to download it to an isolated local cache and open it
   in local Visual Studio Code.
7. Saving in VS Code triggers an upload to the exact original remote path.
8. XMterm displays connection, transfer, sync, conflict, cancellation, and failure
   states without blocking unrelated terminals.

## v0.1 must have

### Terminal workspace

- Native PTY-backed terminal rendering and input.
- Browser-like terminal tabs: add, close, switch, reorder, reconnect, duplicate,
  and rename.
- Drag text selection, double-click word selection, triple-click line selection,
  `Command-C` copy, `Command-V` paste, terminal search, and scrollback.
- Correct distinction between local Command shortcuts and remote Control sequences.
- Independent tab failure and connection state, preserved scrollback after exit,
  honest reconnect semantics, terminal titles, links, bell, resize, Unicode width,
  and xterm-compatible rendering for advertised capabilities.

### Sessions and authentication

- SSH profiles discovered from `~/.ssh/config` aliases first, with manual
  alias or host/user/port entry as a fallback. Phase 3 implements manual alias and
  direct-host entry; automatic discovery/import remains deferred.
- Key and agent authentication without storing private keys in XMterm.
- Support for normal OpenSSH flows such as ProxyJump and server-required prompts.
- Delegate effective SSH config resolution to system OpenSSH rather than naively
  reimplementing `Include`, wildcard, `Match`, or token semantics.
- Explicit sleep/wake, network-loss, host-key, reconnect, and terminal/SFTP
  authentication-coordination behavior.
- Remember only non-secret presentation settings.

### Remote files

- MobaXterm-style remote file sidebar for the active session.
- Lazy directory loading, Back/Forward/Up, direct path entry, refresh, sorting,
  and hidden-file toggle.
- Single selection, `Command-click` multi-selection, `Shift-click` range selection,
  keyboard selection, and `Command-A` for loaded visible entries.
- Copy, cut, paste, drag move/copy, rename, duplicate, delete, new file/folder,
  upload, download, copy remote path, and Open Terminal Here.
- Finder-to-remote upload drag and remote-to-Finder download drag.
- Explicit name-collision handling and batch progress/error reporting.
- Permissions/executable-bit preservation, symlink-safe behavior, structured path
  handling, and transfer staging that never reports a partial destination as success.

### Local editor sync

- Open remote text files in local Visual Studio Code or the configured local editor.
- Watch editor saves, including atomic-save behavior, and upload automatically.
- Keep independent mappings for multiple open files.
- Coalesce rapid saves safely and never mark an older revision as current.
- Visible sync state and remote-modification conflict handling.
- Warn before quitting with unsynced changes.
- Safe complete-revision upload, offline pending state, remote rename/delete handling,
  configurable local editor, and executable-mode preservation.

### Quality baseline

- Keyboard-only operation for the primary workflows.
- Context menus and menu-bar commands that match shortcut behavior.
- Accessibility labels and non-color-only status indication.
- Cancellable long operations.
- Exact remote paths in destructive or conflict-sensitive dialogs.
- Native menu/focus parity, state restoration, settings for habitual terminal and
  file behavior, and privacy-safe diagnostics.
- A terminal compatibility acceptance checklist covering PTY bytes, resize, Unicode,
  full-screen applications, disconnects, titles, links, bell, and clipboard escape
  sequences.

The detailed interaction contract is in [`INTERACTIONS.md`](INTERACTIONS.md).

## Explicit non-goals for v0.1

- VS Code Remote SSH compatibility.
- An embedded code editor.
- Remote project indexing, recursive search across the server, Git integration,
  LSP, extensions, or a remote runtime.
- tmux orchestration.
- X11, RDP, VNC, serial, Kubernetes, Docker, or database clients.
- Cross-platform support.
- Cloud account synchronization.
- Full remote filesystem mounting.

## Experience principles

- Opening XMterm should feel closer to opening Terminal than opening an IDE.
- Terminal occupies the dominant area and remains responsive during transfers.
- Ordinary macOS interactions must work; “MVP” is not permission to omit selection,
  clipboard, drag-and-drop, focus, cancellation, or accessibility behavior.
- A network interruption in one terminal must not freeze the full UI.
- The file browser must never scan more than the user opened.
- Common actions should take one click, one drag, or one keyboard shortcut.
- Dangerous file operations require clear confirmation and report the exact remote
  path.
