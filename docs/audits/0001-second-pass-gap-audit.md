# Audit 0001: Second-Pass Product Gap Review

- **Status:** Complete
- **Date:** 2026-07-15
- **Scope:** Habitual terminal, SSH, file-management, editor-sync, and macOS behavior

## Why this audit exists

The first specification captured the main XMterm workflow, but a terminal and file
manager can appear functional while still omitting behaviors users rely on without
thinking about them. This review checks the product as a daily desktop tool rather
than as a collection of backend operations.

## Corrections made

### Control-key semantics

`Control-V` is not terminate and is not macOS paste. It must reach the PTY as byte
`0x16`. `Control-C` is the normal interrupt key. Local paste is `Command-V`.

### Closing a connected remote terminal

The earlier terminal UX draft distinguished an “idle shell” from a “foreground
command” for SSH, but XMterm cannot reliably know that without remote shell
integration. The corrected remote v0.1 behavior is:

- exited or failed tabs close immediately;
- connected tabs show a concise close confirmation by default;
- the user may disable this confirmation in Settings;
- XMterm never pretends it can guarantee whether a remote foreground job is active.

This remote limitation does not apply to a local PTY owned by XMterm. The later
local implementation compares `tcgetpgrp` with the recorded shell process group;
see Execution Plan 0004. SSH-specific foreground detection remains deferred.

### OpenSSH configuration

XMterm must not implement SSH semantics by naively parsing `~/.ssh/config`. Host
aliases may depend on `Include`, wildcard blocks, `Match`, canonicalization, tokens,
and command-line overrides. Alias discovery may use a conservative parser for UI,
but effective connection settings must be delegated to `/usr/bin/ssh`, with
`ssh -G <alias>` used for inspection where needed.

## Important missing areas found

### 1. Terminal compatibility was underspecified

The original documents described keyboard and selection, but not enough terminal
protocol behavior. Added requirements now cover:

- ANSI/VT/xterm screen behavior;
- 256-color and true-color rendering;
- alternate screen, scroll regions, cursor modes, and resize reporting;
- wrapped-line copy behavior and optional rectangular selection;
- Unicode cell width, combining marks, CJK, and emoji;
- OSC titles, working-directory hints, hyperlinks, and bell behavior;
- secure treatment of OSC 52 clipboard requests;
- preserving scrollback after disconnect and showing exit status.

See `terminal-compatibility.md`.

### 2. SSH lifecycle and sleep/wake behavior were missing

A stable client needs explicit behavior for:

- connecting, authenticating, connected, disconnected, exited, failed, and
  reconnecting states;
- host-key prompts and changed-host-key failures;
- laptop sleep, network loss, VPN changes, and wake;
- reconnect semantics that preserve scrollback but do not claim to restore the
  remote shell process;
- avoiding duplicate password/OTP prompts when a trusted shared connection is
  available;
- SFTP and terminal failure isolation.

See `ssh-connection-lifecycle.md`.

### 3. Transfer correctness was underspecified

“Upload” is not complete unless partial writes, metadata, symlinks, collisions, and
failures are defined. Added requirements now cover:

- temporary-file download/upload staging;
- same-directory atomic rename where the server supports it;
- preserving executable permission bits and timestamps where requested;
- not replacing a symlink accidentally;
- batch queue, per-item state, retry, cancellation, and cleanup;
- special characters in remote paths;
- large-file limits and no silent overwrite.

See `transfer-integrity.md`.

### 4. Local editor auto-sync needed stronger safety rules

The first draft detected saves and conflicts but did not fully specify:

- uploading a complete new revision rather than exposing a partially written file;
- preserving the original remote mode, especially executable scripts;
- saves made while offline and retry ordering;
- remote rename/delete while a local mapping is open;
- binary files, encoding, line endings, symlinks, and same-name files in different
  directories;
- custom local editor commands and editor-not-found behavior.

These are now included in the editor-sync and transfer documents.

### 5. Normal macOS application behavior was incomplete

Added explicit expectations for:

- menu bar commands and enabled states;
- Preferences/Settings and per-profile overrides;
- window close versus application quit;
- state restoration, reopening a recently closed terminal, and tab overflow;
- font zoom, appearance, reduced motion, notifications, and privacy-safe logs;
- dragging remote paths into a terminal to insert shell-quoted paths;
- menu/shortcut/focus consistency.

See `macos-app-behavior.md`.

### 6. Verification needed a terminal-specific acceptance checklist

The general interaction checklist was not sufficient to catch terminal protocol
regressions. A dedicated checklist now covers bytes, resize, Unicode, selection,
full-screen applications, disconnects, paste safety, titles, links, and bell.

See `docs/checklists/terminal-acceptance.md`.

## Explicitly still deferred

The audit does not move these into v0.1:

- tmux integration;
- split terminal panes;
- remote project indexing or search;
- embedded code editor;
- X11, RDP, VNC, or Mosh;
- shell integration required to identify remote foreground jobs perfectly;
- collaborative editing;
- automatic background upload after XMterm itself has quit.

## Result

The repository now treats the following as separate completion dimensions:

1. backend operation works;
2. native interaction works;
3. protocol compatibility works;
4. failure and recovery work;
5. security and data integrity work;
6. accessibility and verification evidence exist.
