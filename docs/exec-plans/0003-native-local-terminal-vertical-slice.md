# Execution Plan 0003: Native Local Terminal Vertical Slice

- **Status:** Complete
- **Started:** 2026-07-15
- **Completed:** 2026-07-15
- **Scope:** One complete PTY-backed local-terminal workflow with independent tabs

## Goal

Launch the user's normal interactive login shell inside a real pseudo-terminal,
render it with a native AppKit terminal engine, and provide complete Phase 1 tab,
input, selection, clipboard, scrolling, resize, exit, error, and cleanup behavior.

## Acceptance requirements

- `APP-002`, `APP-003`, `APP-004`
- `TERM-SEL-001` through `TERM-SEL-004`
- `TERM-CLIP-001` through `TERM-CLIP-003`
- `TERM-SCROLL-001`, `TERM-FIND-001`
- `TERM-KEY-001` through `TERM-KEY-004`, `TERM-PROC-001`
- `TERM-RENDER-001`, `TERM-RENDER-002`, `TERM-RESIZE-001`
- `TERM-STATE-001`, `TERM-SEC-001`
- `TAB-001`, the Phase 1 create/select subset of `TAB-002`, `TAB-003`, `TAB-005`
- applicable `A11Y-001` through `A11Y-003` and `MAC-001`, `MAC-002`

## Decisions

1. Pin SwiftTerm v1.14.0 as the sole terminal engine. Use its AppKit
   `TerminalView`, not its process wrapper.
2. XMterm owns `forkpty`, descriptor I/O, resize, signal escalation, wait-status
   decoding, and child reaping behind a PTY protocol.
3. Runtime terminal views and processes are stable objects keyed by immutable tab
   IDs. SwiftUI owns presentation state but never owns raw descriptors.
4. Scrollback defaults to 10,000 lines. Terminal graphics are not advertised and
   image cache is disabled for Phase 1.
5. Multiline paste confirmation is enabled. OSC 52 reads and writes are denied.
6. Option sends Escape-prefixed Meta for the Phase 1 default. A settings UI is out
   of scope.

## Architecture and data flow

```text
SwiftUI workspace and tab strip
        | stable tab ID / commands / state
Terminal session + AppKit adapter
        | input bytes / output chunks / grid size
PTY controller
        | master descriptor
forkpty child -> interactive login shell
```

The AppKit bridge is a narrow `NSViewRepresentable` around one retained terminal
view per tab. Output is parsed incrementally by SwiftTerm without copying the full
scrollback into SwiftUI state. PTY reads and writes never block the main actor.

## Work items

### 1. Domain and deterministic behavior (TDD)

- [x] Replace the remote-only tab model with immutable local-terminal metadata,
      lifecycle state, typed exit status, and stable identity.
- [x] Add a window-local tab state/store with deterministic create, select, close,
      neighboring-selection, and update operations.
- [x] Add executable shell fallback and login argument construction.
- [x] Add Command-versus-Control input routing and paste normalization/framing.
- [x] Add grid-size calculation, resize coalescing, and bounded engine constants.
- [x] Keep the starter suite on Swift Testing, add a Command Line Tools framework
      discovery fallback to repository verification, and demonstrate RED then GREEN
      results. This host ships `Testing.framework` but no XCTest module.

### 2. PTY infrastructure (TDD)

- [x] Add a minimal C `forkpty`/`execve` shim with structured argv/environment and
      startup errno reporting.
- [x] Add a serially owned PTY controller with asynchronous chunked reads/writes,
      `TIOCSWINSZ`, process-group close escalation, exact-once descriptor cleanup,
      final output drain, and guaranteed `waitpid` reaping.
- [x] Add real-PTY integration tests for round trip, `stty size`, exit code,
      signal status, close, and independent children.

### 3. Terminal-engine adapter

- [x] Configure SwiftTerm for 10,000-line scrollback, no terminal graphics
      advertisement/cache, CoreGraphics rendering, DEL Backspace, and Meta Option.
- [x] Route output/input/resize through the PTY abstraction.
- [x] Deny OSC 52 and automatic link/bell actions.
- [x] Preserve selection during output and implement Option-forced local selection
      while remote mouse reporting is active.
- [x] Expose copy, paste, find, select-all, clear-selection, jump-to-latest, focus,
      context menu, title, follow-mode, and new-output state through narrow actions.

### 4. Native workspace and tab workflow

- [x] Launch one local shell at app startup.
- [x] Implement `+`, `Command-T`, click selection, close button, and `Command-W`.
- [x] Confirm every running-shell close without claiming foreground-job detection;
      close exited/failed tabs immediately.
- [x] Preserve each hidden tab's engine view, PTY, screen, process, selection, and
      scroll position.
- [x] Keep exited tabs visible with final scrollback and decoded status; disable
      their input and allow immediate close.
- [x] Add multiline paste confirmation, meaningful failures/recovery, visible focus,
      accessibility labels, and a jump-to-latest affordance.

### 5. Build, verification, and evidence

- [x] Add a project-local SwiftPM GUI `.app` staging/run script and Codex Run action.
- [x] Run focused tests during each RED/GREEN cycle, then the complete suite,
      coverage, debug/release builds, warnings-as-errors, and `scripts/verify.sh`.
- [x] Run deterministic PTY stress/lifecycle checks and the available GUI/manual
      acceptance cases on this host.
- [x] Record exact commands, versions, measurements, unsupported behaviors, and
      environment blockers in the Phase 1 evidence audit.
- [x] Update ADR 0003, architecture/status docs, the prior terminal spike, and the
      terminal acceptance checklist without marking unverified behavior complete.

## Performance impact

- One bounded SwiftTerm buffer per tab; no parallel SwiftUI copy of scrollback.
- PTY output is chunked and parser-driven, never per-character SwiftUI state.
- Resize is latest-value coalesced; idle work uses process/descriptor events rather
  than polling.
- Child-output backpressure is bounded so a fast producer blocks at the PTY instead
  of growing application memory without limit.

## Security impact

- Shell launch uses an executable path plus argv/environment arrays, never an
  interpolated command.
- Terminal output is untrusted: OSC clipboard access, automatic URL opening,
  notification requests, and terminal-content logging are denied.
- No secrets, terminal contents, or full environment dumps enter diagnostics.

## Edge cases and risks

- Shell candidates may be empty, relative, missing, or non-executable.
- A child may exit before the PTY reaches EOF; completion must wait for final output
  without leaking the child.
- Close may encounter a stopped or signal-ignoring process group and must escalate.
- SwiftTerm's default mouse-selection modifier and selection-on-output behavior do
  not match XMterm and require adapter coverage.
- macOS terminal VoiceOver support is incomplete upstream.
- This host has Command Line Tools but no full Xcode, and XMterm is untracked inside
  an unrelated parent repository. XCUITest, Developer ID release-signing, and a
  project-scoped commit are unavailable here; the staged ad-hoc bundle is verified.

## Explicitly deferred

SSH, SFTP, remote files, editor sync, tunnels, tmux, settings, tab reorder/rename/
duplicate/reconnect/reopen, block selection, selected-text drag export, configurable
OSC 52/link/bell permissions, terminal graphics, split panes, signing, notarization,
and distribution.

## Completion evidence and known limitations

The running-shell confirmation item above records the original Phase 1 behavior.
It is superseded for local PTYs by
[`0004-local-terminal-close-confirmation.md`](0004-local-terminal-close-confirmation.md):
idle shells now close immediately and only a different foreground process group or
an exceptional live query failure prompts. Remote SSH detection remains deferred.

The exact automated results, manual checks, performance observations, signing
scope, file inventory, and honest limitations are recorded in
[`../audits/0002-phase-1-local-terminal-evidence.md`](../audits/0002-phase-1-local-terminal-evidence.md).
Notably, full xterm compatibility, live IME preedit timing, comprehensive VoiceOver,
Shift-click, reported-mouse application behavior, and a release performance run are
not claimed complete.
