# Design Document Index

| Document | Status | Purpose |
|---|---|---|
| [`v0.1-mvp.md`](v0.1-mvp.md) | Draft | Defines the first usable XMterm release and release-level acceptance criteria. |
| [`session-tabs-ux.md`](session-tabs-ux.md) | Draft | Defines remembered sessions, authentication handoff, and terminal-tab lifecycle. |
| [`session-manager.md`](session-manager.md) | Implemented (Phase 3) | Defines Phase 3 saved local/SSH profiles, versioned persistence, picker, management, validation, and immutable launched-tab snapshots. |
| [`tab-strip-redesign.md`](tab-strip-redesign.md) | Approved | Defines Phase 2 terminal-tab sizing, overflow, selected-tab reveal, pinned creation control, and header-region ownership. |
| [`terminal-ux.md`](terminal-ux.md) | Draft | Defines terminal selection, clipboard, keyboard, scrollback, search, and tab behavior. |
| [`terminal-keyboard.md`](terminal-keyboard.md) | Draft | Defines macOS Command shortcuts, PTY Control bytes, process-control semantics, special-key encoding, and verification. |
| [`terminal-compatibility.md`](terminal-compatibility.md) | Draft | Defines xterm/VT rendering, Unicode width, resize/reflow, titles, links, bell, OSC security, and disconnect behavior. |
| [`ssh-connection-lifecycle.md`](ssh-connection-lifecycle.md) | Draft | Defines OpenSSH config resolution, authentication prompts, connection reuse, sleep/wake, network loss, and reconnect. |
| [`transfer-integrity.md`](transfer-integrity.md) | Draft | Defines safe upload/download staging, metadata, symlinks, path correctness, retry ordering, and data integrity. |
| [`macos-app-behavior.md`](macos-app-behavior.md) | Draft | Defines native menu, settings, window/tab lifecycle, restoration, notifications, and macOS drag behavior. |
| [`remote-files-ux.md`](remote-files-ux.md) | Draft | Defines multi-selection, copy/cut/paste, drag-and-drop, navigation, and remote file operations. |
| [`remote-workspace.md`](remote-workspace.md) | Approved and implemented for Phase 4A | Defines the Phase 4A session-owned read-only workspace, provider boundary, raw paths, bounded navigation/cache state, and native sidebar. |
| [`production-sftp-transport.md`](production-sftp-transport.md) | Accepted, implemented, and production verified | Defines Task 9's independent system-OpenSSH subsystem process, bounded read-only SFTP v3 codec, noninteractive authentication boundary, lifecycle, and production gates. |
| [`phase-4b-remote-file-mutations-and-transfers.md`](phase-4b-remote-file-mutations-and-transfers.md) | Approved for implementation | Defines Phase 4B Finder-style selection, mutations, streaming transfers, queue/collision policy, clipboard, drag-and-drop, lifecycle, security, and acceptance boundaries. |
| [`editor-sync-ux.md`](editor-sync-ux.md) | Draft | Defines local VS Code launch, save detection, automatic upload, conflicts, and cache lifecycle. |

The canonical cross-feature interaction baseline is [`../../INTERACTIONS.md`](../../INTERACTIONS.md).

Phase 3 implementation and packaged-app evidence are tracked in
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md)
and
[`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).
SSH config alias discovery, SFTP, remote file browsing, and editor synchronization
remain outside the implemented Session Manager design.

A design document must state its status, owner, decision scope, acceptance criteria,
and unresolved questions. Update this index whenever a design document is added or
retired.
