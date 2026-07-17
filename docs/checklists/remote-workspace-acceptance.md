# Phase 4A Remote Workspace Acceptance Checklist

- **Date:** 2026-07-16
- **Target:** read-only session-owned Remote Workspace
- **Current status:** Planning complete; implementation evidence pending
- **Production transport:** Blocked by ADR 0007; no real listing may be claimed

`[x]` means direct automated, inspection, performance, or packaged-app evidence has
been recorded in `docs/audits/0006-phase-4a-remote-workspace-evidence.md`. An
unchecked item includes its present status and must never be inferred as a pass.

## Contract and ownership

- [ ] **Pending:** `SESS-011` runtime aggregate owns sibling terminal and optional
  workspace capabilities.
- [ ] **Pending:** Local sessions construct no provider, cache, or remote tasks.
- [ ] **Pending:** Two launches from one profile have independent workspace state,
  history, selection, cache, provider, and cancellation.
- [ ] **Pending:** Profile edit/delete cannot mutate a launched workspace.
- [ ] **Pending:** Workspace failure cannot stop or relabel the terminal.
- [ ] **Pending:** Closing one tab cancels only its owning workspace and terminal.

## Domain and provider contract

- [ ] **Pending:** Raw-byte path identity covers root, parent, Unicode, CJK, emoji,
  spaces, apostrophes, leading hyphens, dotfiles, controls, and invalid UTF-8.
- [ ] **Pending:** Entry values preserve kind, optional metadata, executable,
  hidden, symlink target, and completeness without guessing.
- [ ] **Pending:** Ordering is deterministic and stable.
- [ ] **Pending:** In-memory provider obeys the same cancellation/error/listing
  contract as production providers.
- [ ] **Pending:** Shipping unavailable provider reports a visible transport error
  and never fabricates an empty or mock Relay directory.
- [ ] **Blocked:** A reviewed production provider lists the real Relay Host through
  structured SFTP data while preserving system OpenSSH behavior.

## Navigation, cache, and concurrency

- [ ] **Pending:** Initial directory is provider-resolved and published only after
  its listing succeeds.
- [ ] **Pending:** Child open, Back, Forward, Parent, breadcrumb, and Refresh follow
  `FILE-NAV-002`, including selection/history restoration.
- [ ] **Pending:** Failed targets do not become current and failed loads do not
  appear empty.
- [ ] **Pending:** Refresh changes no history and preserves only surviving exact
  selection.
- [ ] **Pending:** Each runtime has a bounded LRU cache and targeted invalidation.
- [ ] **Pending:** Listing is immediate-child-only; expansion is lazy; no recursive
  scan, symlink traversal, prefetch, or polling occurs.
- [ ] **Pending:** Cancellation and generation tests prove stale results cannot
  overwrite newer navigation or another tab.
- [ ] **Pending:** Remote work runs off `MainActor`; observable publication is on
  `MainActor`; every task has runtime ownership.

## Native UI and commands

- [ ] **Pending:** Sidebar remains resizable while terminal remains dominant.
- [ ] **Pending:** Local and SSH unavailable/loading/loaded/empty/failed/cancelled
  states are distinct and accessible.
- [ ] **Pending:** Single click, arrows, disclosure, double-click, `Command-Down`,
  `Command-Up`, context menu, focus restoration, and Retry work where applicable.
- [ ] **Pending:** Back, Forward, Parent, Refresh, and breadcrumbs share one action
  availability policy.
- [ ] **Pending:** Copy Path, Name, Parent, and Shell-Quoted Path put exact text on
  the pasteboard without Return; lossy raw paths disable exact actions.
- [ ] **Pending:** Switching tabs immediately shows the selected runtime's state and
  never recreates the retained terminal view.
- [ ] **Pending:** VoiceOver labels/roles, keyboard-only traversal, Light/Dark, and
  Reduce Motion have direct evidence.

## Performance and security

- [ ] **Pending:** A 1,000-entry model/order/publication benchmark is below 100 ms.
- [ ] **Pending:** Scripted interaction has no observed main-thread stall above
  100 ms; scrolling and tab switching remain responsive.
- [ ] **Pending:** Cache, response, path, component, diagnostics, entry-count, and
  provider concurrency bounds are tested.
- [ ] **Pending:** Idle CPU is near zero and no poll/timer loop exists.
- [ ] **Pending:** Source/process/log inspection finds no shell wrapper, command
  interpolation, host-key bypass, credential/clipboard/terminal logging, remote
  daemon, recursive indexer, or human `ls` parsing.
- [ ] **Pending:** Full `./scripts/verify.sh`, focused coverage, whole-source
  coverage, dependency licenses, packaging, and app-signing evidence are recorded.

## Scope boundary and completion

- [ ] **Pending:** Audit confirms no Phase 4B mutation/transfer, Phase 5 terminal
  directory synchronization, or Phase 6 editor-sync code was started.
- [ ] **Blocked:** Packaged manual Relay acceptance resolves initial directory,
  lists real entries, navigates, refreshes, copies paths, switches tabs, and closes
  cleanly.
- [ ] **Blocked:** Phase 4A is marked complete only after ADR 0007's production
  transport gate and every applicable row above pass.
