# Session and Terminal Tab Design

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** Remembered SSH sessions, authentication handoff, and tab lifecycle
- **Canonical requirements:** `TAB-*`, `SESS-*`, and `TERM-STATE-001`
- **Lifecycle contract:** [`ssh-connection-lifecycle.md`](ssh-connection-lifecycle.md)

**Implementation note (Phase 2):** stable local and fixed `Relay Host` tab kinds
coexist and retain independent views/processes. The `+` and File menus can open the
relay. The tab strip now keeps fitting tabs at 180 points, shrinks them equally to
120 points, and then holds 120 points while one horizontal viewport scrolls.
Non-overflow width is the actual tab-content width; unused header space is not
claimed by the strip. The `+` menu is pinned immediately after the viewport as a
non-scrolling sibling, followed by an independent toolbar region.

Creation, click activation, replacement selection after close, and resize all
request reveal of the selected stable tab ID. Initial and tab/selection requests
settle for 16 ms before exactly one final scroll; initial reveal is unanimated and
only tab/selection changes may use the short scoped animation. Viewport-only
requests use a 75 ms cancellation-coalesced unanimated debounce. Reduce Motion
removes the optional tab/selection animation without changing selection or final
layout. The current pure tests cover policy geometry, reveal targets, and scheduling,
and a staged pass verified the core rendered sizing, overflow, pinned `+`, and
selected-tab reveal behavior. Physical trackpad momentum, long-title rendering,
full keyboard traversal, actual VoiceOver, visual Reduce Motion, and relay
invocation remain pending manual evidence.

**Implementation note (Phase 3):** the pinned `+` now opens a focused, searchable
saved-session picker with unique Recent, Favorites, SSH, and Local sections.
Users can create, edit, duplicate, favorite, and delete local, direct-SSH, and
manually entered SSH-alias profiles in a native manager. Each launch creates a new
tab/session pair from an immutable launch snapshot and retains source-profile
provenance; later profile edits or deletion cannot mutate or close that tab.
Profile persistence, error/recovery states, keyboard selection, and `Command-T`
saved-local behavior are implemented. SSH config alias discovery/import, tab-
number and adjacent-tab shortcuts, tab drag reorder, reconnect, recently closed
tabs, and file-browser following remain deferred.

## Session source

Phase 3 persists user-created launch templates as versioned, non-secret local JSON.
Direct profiles contain explicit host/user/port metadata; alias profiles contain
only the manually entered alias used for launch. System OpenSSH remains the source
of truth for alias semantics, authentication, host verification, and effective
connection behavior.

Automatic discovery from `~/.ssh/config` and `ssh -G` presentation are deferred.
When added, discovery must remain presentation-only and effective settings must
still be delegated to system OpenSSH. XMterm must not reimplement `Include`,
wildcard, `Match`, ProxyJump, token expansion, canonicalization, identity selection,
or host-key policy.

## Implemented Phase 3 session actions

- single click selects a stable picker row;
- double-click, Return, or the row's accessibility Launch action opens a new
  terminal from the current saved snapshot;
- the row favorite control and manager context menu persist Favorite/Unfavorite;
- the manager provides create, edit, duplicate, and confirmed delete;
- removing a saved profile does not edit `~/.ssh/config` and does not close an
  existing tab launched from that profile.

Future file-aware context actions such as Connect Files and profile display-setting
overrides remain outside Phase 3.

## Tab lifecycle

Each terminal tab owns:

- stable tab ID;
- session ID;
- display title and optional user rename;
- PTY/process handle;
- connection state;
- exit status;
- scrollback and selection state;
- unread-output state;
- reconnect history and last error.

A tab is independently created, selected, reordered, renamed, reconnected, and
closed. Duplicate Terminal starts a fresh process using the same profile; it does
not clone remote shell state. Disconnected tabs preserve scrollback and show exit
status. `Command-Shift-T` may reopen a recently closed profile as a fresh connection.

The active file browser session follows the selected terminal by default, but the
architecture must allow pinning the file browser to another session later. A file
browser failure does not terminate terminal processes.

## Authentication experience

XMterm must correctly support key-based authentication, ssh-agent, macOS Keychain
integration exposed through OpenSSH, ProxyJump, and server-required interactive
prompts. Passwords and OTPs are never saved by XMterm.

A connection prompt must identify the target alias/host. Host-key warnings must not
be replaced by a generic app dialog that hides the fingerprint or reason.

When the selected backend can safely reuse an authenticated transport or trusted
OpenSSH multiplexed connection, terminal and SFTP should not trigger duplicate
password/OTP prompts. If reuse is unavailable, the separate connection is visible
and may prompt again.

## Minimum manual verification

The completed Task 8 Phase 3 profile/tab matrix and its exact results are
maintained in
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md).
The remaining list below is the broader future SSH/file-lifecycle contract and is
not claimed by Phase 3:

- discover aliases while `Include`/wildcard config still resolves correctly through
  OpenSSH;
- connect with key and agent;
- connect through ProxyJump;
- visible password/OTP prompt when server requires it;
- create several tabs for one session and different sessions;
- reorder and rename tabs;
- close one tab without affecting others;
- reconnect an exited tab while preserving old scrollback;
- sleep/wake and network loss without false Connected state;
- SFTP reconnect/failure without closing terminals;
- file browser follows active terminal session.
