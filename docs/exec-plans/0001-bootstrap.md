# Execution Plan 0001: Bootstrap XMterm

- **Status:** Active
- **Started:** 2026-07-15

## Goal

Create an agent-legible repository that opens in Xcode, renders the terminal-first shell, and gives future coding agents deterministic product, architecture, and verification guidance.

## Acceptance criteria

- [x] Repository has a small `AGENTS.md` entry point.
- [x] Product scope, architecture, security rules, and plans are versioned.
- [x] Swift package defines a native macOS executable and testable core library.
- [x] Starter UI shows sessions, remote-files placeholder, terminal tabs, add, and close.
- [x] `⌘T` creates a terminal placeholder.
- [x] Core models have initial tests.
- [x] `scripts/verify.sh` checks required repository structure and runs tests.
- [x] Detailed interaction requirements cover terminal selection/copy/paste, remote file multi-selection, clipboard actions, drag/drop, editor sync, focus, cancellation, and accessibility.
- [x] UI work has a reusable interaction parity checklist.
- [x] Second-pass gap audit covers terminal protocol, SSH lifecycle, transfer
  integrity, editor-sync safety, native macOS behavior, performance, and testing.
- [x] Terminal-specific acceptance checklist and next execution plan exist.
- [ ] Confirm build and launch in the project owner's Xcode environment.

## Progress log

### 2026-07-15

Created the initial repository scaffold and documented the first product invariants. Added a detailed interaction contract so ordinary behaviors such as drag selection, multi-selection, copy/cut/paste, drag-and-drop, focus, scrollback, cancellation, and accessibility cannot be omitted by future implementation agents. Terminal and remote file backends remain intentionally unimplemented until their interface and dependency decisions are validated through focused spikes.

## Decisions

- Native macOS implementation: ADR 0001.
- No remote daemon: ADR 0002.

## Next action

Open `Package.swift` in Xcode, run the app, then execute `docs/exec-plans/0002-terminal-foundation.md` and complete ADR 0003/0004 with measured evidence.
