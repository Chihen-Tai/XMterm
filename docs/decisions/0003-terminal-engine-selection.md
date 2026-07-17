# ADR 0003: Select the Terminal Emulator and PTY Integration

- **Status:** Accepted for Phase 1
- **Date:** 2026-07-15

## Context

The terminal engine determines selection, scrollback, Unicode width, xterm
compatibility, performance, accessibility, licensing, and maintenance cost. A
simple text view is not sufficient.

## Decision criteria

A candidate must be evaluated for:

- native macOS/AppKit integration;
- real PTY support or a clean PTY adapter;
- xterm/VT compatibility and advertised `TERM` accuracy;
- 256-color/true-color, alternate screen, mouse, bracketed paste, resize;
- Unicode combining/CJK/emoji width behavior;
- drag/word/line selection and forced local selection during mouse reporting;
- scrollback search and bounded memory;
- OSC title/link/bell behavior and OSC 52 security controls;
- accessibility and input-method support;
- performance under sustained output;
- active maintenance, license compatibility, and dependency size.

## Options evaluated

- SwiftTerm 1.14.0, a native Swift/AppKit engine under the MIT license;
- Ghostty/libghostty and Ghostling;
- libvterm or another small C/Rust parser core with an XMterm-owned renderer;
- an XMterm-authored terminal emulator.

Ghostty's embeddable API is not yet a stable tagged macOS view surface, and
Ghostling intentionally omits rendering, selection, IME, and window integration.
Parser-only C/Rust cores would require XMterm to build most terminal interaction
behavior from scratch. An XMterm-authored emulator is both larger and riskier than
this vertical slice permits.

## Required evidence

Phase 1 evidence is recorded in
[`../audits/0002-phase-1-local-terminal-evidence.md`](../audits/0002-phase-1-local-terminal-evidence.md)
and [`../checklists/terminal-acceptance.md`](../checklists/terminal-acceptance.md).
Those records distinguish automated, manual, partial, deferred, and blocked results;
adopting SwiftTerm does not make unverified compatibility behavior complete.

## Decision

Pin SwiftTerm **1.14.0** exactly (revision
`849e8a4f3d6f79ddee07152400137f1370c32621`) as XMterm's sole terminal engine.
Use its AppKit `TerminalView` for parsing, rendering, selection, IME, search,
scrollback, alternate-screen, keyboard, and mouse-mode behavior.

Do not use SwiftTerm's `LocalProcess` or `LocalProcessTerminalView`. XMterm owns a
separate PTY/process boundary because the application must expose structured launch,
read, write, resize, exit, and signal failures and must guarantee descriptor cleanup
and child reaping independently of SwiftUI view lifetime.

The Phase 1 engine policy is:

- `TERM=xterm-256color` with the compatibility surface verified through focused and
  manual acceptance evidence;
- 10,000 lines of bounded scrollback;
- CoreGraphics rendering; optional Metal remains disabled;
- Sixel advertisement disabled and Kitty image cache set to zero;
- Backspace sends DEL and Option sends Escape-prefixed Meta;
- terminal-originated OSC 52 reads/writes, automatic link opening, bells,
  notifications, and iTerm host actions are denied;
- untrusted output passes through a constant-memory control-sequence filter that
  drops OSC, DCS, APC, PM, and SOS strings; bounds CSI length; and blocks window/
  title operations, pixel mouse mode 1016, terminal graphics, and engine log paths;
- an AppKit adapter keeps mouse reporting disabled between events so output does not
  clear local selection, forwards genuine reported mouse events transiently, and
  reserves Option-drag for local selection;
- multiline or control-bearing paste requires application confirmation, while
  oversized, bidi-spoofed, or bracket-terminator-injected paste is rejected.

SwiftTerm remains behind `XMtermTerminalView`; application and domain code do not
import it directly.

## PTY decision

Use a minimal C shim around `forkpty`, `execve`, `ioctl(TIOCSWINSZ)`, master-side
`TIOCSIG`, and process-group signals. Swift owns validation, bounded nonblocking
I/O, resize coalescing, close escalation, final-output/exit reconciliation, and
cached idempotent completion.
The login shell is executed directly with a login `argv[0]`; no command string or
`/bin/bash -c` participates in application shell launch.

The same PTY boundary records the local shell PID/process group and exposes
`tcgetpgrp` foreground ownership for close decisions. This is local kernel state,
not terminal-engine parsing or a claim about remote SSH activity.

## Consequences and follow-up

- SwiftTerm is one pinned third-party runtime dependency and its MIT license must
  remain represented in distribution artifacts.
- SwiftTerm 1.14.0 makes macOS `keyDown` and `scrollWheel` non-open, so the adapter
  uses a window-scoped AppKit event monitor rather than patching or forking the
  dependency.
- VoiceOver access to the complete terminal buffer, rectangular selection, and
  dragging selected terminal text are not complete upstream and remain tracked.
- XMterm filters potentially unbounded or host-affecting control strings before
  they reach SwiftTerm. Focused tests cover split chunks, unterminated strings,
  bounded CSI handling, OSC 52, graphics, window operations, private mouse mode
  1016, and terminal-content logging paths.
- SwiftTerm's MIT license is copied into the development application bundle. The
  Phase 1 bundle is ad-hoc signed for local testing only; Developer ID signing,
  hardened runtime validation, notarization, and distribution remain pending ADR
  0004.
- The terminal compatibility and acceptance checklists remain the release evidence;
  adopting the engine does not imply untested full xterm compatibility.
