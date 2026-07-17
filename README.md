# XMterm

**XMterm** is a lightweight, terminal-first SSH/SFTP client for macOS.

It keeps the fast MobaXterm-style workflow:

- terminal tabs are the main workspace;
- terminal text supports normal drag selection, copy/paste, search, and scrollback;
- the connected server's remote files appear in a sidebar;
- remote files support ordinary macOS single/multiple selection, copy, cut, paste,
  move, drag-and-drop, upload, and download;
- double-clicking a remote file downloads it to a local cache and opens it in a
  local editor such as VS Code;
- saving the local file uploads it back to the original remote path;
- no VS Code Remote SSH server, remote workspace indexing, Electron runtime, or
  background daemon is installed on the server.

## Current status

**Phase 3 is complete for its locked Session Manager scope.** The native app
supports durable saved local, direct-host SSH, and manually entered SSH-config-alias
profiles; a searchable Recent/Favorites/SSH/Local picker; profile
create/edit/duplicate/delete and favorite actions; and profile-backed terminal
launches. `+` opens the picker without starting a process. `Command-T` launches the
first saved login-shell local profile, or opens the picker when no such profile
exists.

Each new tab receives an immutable launch snapshot and retains its source-profile
provenance. Later profile edits, renames, or deletion do not change or close an
existing tab. Tab presentation and saved-profile values are model-independent,
although a user-facing tab-rename action is deferred. Profile mutations are
persisted before they are published. The schema-versioned JSON store lives at
`~/Library/Application Support/XMterm/sessions.json`; first-launch defaults are
seeded once, valid empty stores stay empty, and corrupt stores require an explicit
recovery choice.

The proven Phase 1/2 terminal path remains unchanged: independent local and SSH
tabs use the same real PTY, retained SwiftTerm view, bounded I/O, resize,
scrollback, selection/copy/paste, terminal find, Command-versus-Control routing,
typed exit status, and child cleanup. The built-in `Relay Host` profile directly
executes `/usr/bin/ssh -p 54426 allen921103@140.109.226.155` as a structured
executable plus argument array. OpenSSH owns host-key and authentication prompts
inside the terminal; XMterm stores no passwords, OTPs, passphrases, or private-key
contents.

Live SSH tabs use a conservative close confirmation because local PTY state cannot
reveal remote foreground work. Exited or failed SSH tabs retain their final
scrollback and close immediately. Exact automated and packaged-app acceptance
results, retained limitations, and the final audit are recorded in
[`docs/audits/0005-phase-3-session-manager-evidence.md`](docs/audits/0005-phase-3-session-manager-evidence.md).
Automatic alias discovery/import, `ssh -G` presentation, tab-rename UI, reconnect,
ProxyJump UI, automatic second hops, SFTP, remote files, editor sync, tunnels,
tmux, settings, Developer ID signing, and notarization remain deferred.

## Open the project

```bash
open Package.swift
```

Or build from Terminal:

```bash
swift build
swift test
```

Stage an ad-hoc-signed native application bundle and launch it:

```bash
./script/build_and_run.sh --verify
```

Run all repository checks:

```bash
./scripts/verify.sh
```

Command Line Tools installations that provide Swift Testing outside the default
linker path should use `./scripts/verify.sh`; it supplies the required framework and
runtime search paths automatically.

## Read first

1. [`PRODUCT.md`](PRODUCT.md) — what XMterm is and is not.
2. [`INTERACTIONS.md`](INTERACTIONS.md) — detailed mouse, keyboard, selection,
   clipboard, drag-and-drop, and status behavior.
3. [`docs/design-docs/terminal-keyboard.md`](docs/design-docs/terminal-keyboard.md) — exact Command/Control key behavior and PTY semantics.
4. [`docs/design-docs/terminal-compatibility.md`](docs/design-docs/terminal-compatibility.md) — rendering, Unicode, resize, links, titles, bell, and disconnect behavior.
5. [`docs/design-docs/ssh-connection-lifecycle.md`](docs/design-docs/ssh-connection-lifecycle.md) — OpenSSH config, prompts, sleep/wake, and reconnect.
6. [`docs/design-docs/transfer-integrity.md`](docs/design-docs/transfer-integrity.md) — safe uploads/downloads, metadata, symlinks, and retries.
7. [`ARCHITECTURE.md`](ARCHITECTURE.md) — component boundaries and invariants.
8. [`PERFORMANCE.md`](PERFORMANCE.md) — measurable lightweight/resource budgets.
9. [`TESTING.md`](TESTING.md) — unit, PTY, SSH/SFTP, watcher, UI, and compatibility test strategy.
10. [`PLANS.md`](PLANS.md) — active work and next milestones.
11. [`AGENTS.md`](AGENTS.md) — rules for coding agents working in this repository.

## v0.1 outcome

A user can select an SSH profile, open and close browser-like terminal tabs, use
normal terminal selection/copy/paste, browse the corresponding remote directory
lazily, select and manipulate one or many remote files, open a remote text file in
local VS Code, and have each save uploaded back through SFTP with visible sync
status and conflict protection.
# XMterm
