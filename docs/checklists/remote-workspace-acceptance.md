# Phase 4A Remote Workspace Acceptance Checklist

- **Date:** 2026-07-17 (planning 2026-07-16)
- **Target:** read-only session-owned Remote Workspace
- **Current status:** Foundation implemented; Phase 4A **PARTIAL**
- **Production transport:** Blocked by ADR 0007; no real listing may be claimed

`[x]` means direct automated, inspection, performance, or packaged-app evidence has
been recorded in `docs/audits/0006-phase-4a-remote-workspace-evidence.md`. An
unchecked item includes its present status and must never be inferred as a pass.
Every packaged listing referenced below is the explicit simulated developer
fixture, never a real remote host.

## Contract and ownership

- [x] `SESS-011` runtime aggregate owns sibling terminal and optional
  workspace capabilities (`RuntimeSessionTests`, store suites).
- [x] Local sessions construct no provider, cache, or remote tasks
  (composition tests plus packaged local-tab inspection).
- [x] Two launches from one profile have independent workspace state,
  history, selection, cache, provider, and cancellation
  (`TerminalWorkspaceCommandTests`, runtime suites).
- [x] Profile edit/delete cannot mutate a launched workspace
  (Task 5 store/profile suites).
- [x] Workspace failure cannot stop or relabel the terminal
  (`RuntimeSessionTests` isolation tests; packaged transport-unavailable tab
  kept its live terminal).
- [x] Closing one tab cancels only its owning workspace and terminal
  (close-settlement suites; packaged SSH close reaped only its own child).

## Domain and provider contract

- [x] Raw-byte path identity covers root, parent, Unicode, CJK, emoji,
  spaces, apostrophes, leading hyphens, dotfiles, controls, and invalid UTF-8
  (`RemotePathTests`).
- [x] Entry values preserve kind, optional metadata, executable,
  hidden, symlink target, and completeness without guessing
  (`RemoteFileEntryTests`).
- [x] Ordering is deterministic and stable (domain tests; packaged deep-row
  `folder-099` copy matched the deterministic order).
- [x] In-memory provider obeys the same cancellation/error/listing
  contract as production providers (`RemoteFileProviderContractTests`).
- [x] Shipping unavailable provider reports a visible transport error
  and never fabricates an empty or mock Relay directory (packaged shipping-mode
  SSH tab showed `Remote file transport unavailable`).
- [ ] **Blocked:** A reviewed production provider lists the real Relay Host through
  structured SFTP data while preserving system OpenSSH behavior.

## Navigation, cache, and concurrency

- [x] Initial directory is provider-resolved and published only after
  its listing succeeds (workspace suites; packaged initial `/simulated` load).
- [x] Child open, Back, Forward, Parent, breadcrumb, and Refresh follow
  `FILE-NAV-002`, including selection/history restoration (workspace suites;
  packaged Open/Back/Refresh/`Command-Up`/`Command-Down` pass).
- [x] Failed targets do not become current and failed loads do not
  appear empty (workspace suites; packaged denied-directory open kept the
  current listing and rendered an explicit failure row).
- [x] Refresh changes no history and preserves only surviving exact
  selection (workspace suites; packaged Refresh kept `12 items` in place).
- [x] Each runtime has a bounded LRU cache and targeted invalidation
  (`RemoteDirectoryCacheTests`, boundedness suites).
- [x] Listing is immediate-child-only; expansion is lazy; no recursive
  scan, symlink traversal, prefetch, or polling occurs (source scans plus
  provider/workspace suites).
- [x] Cancellation and generation tests prove stale results cannot
  overwrite newer navigation or another tab (workspace race suites;
  stale-owner command tests).
- [x] Remote work runs off `MainActor`; observable publication is on
  `MainActor`; every task has runtime ownership (workspace/lifecycle suites).

## Native UI and commands

- [x] Sidebar remains resizable while terminal remains dominant (240–420 point
  bound; packaged splitter observed at 248 pt with the terminal dominant).
- [x] Local and SSH unavailable/loading/loaded/empty/failed/cancelled
  states are distinct and accessible as presentation policy
  (`RemoteWorkspacePresentationTests`); packaged inspection covered local
  explanation, transport unavailable, loaded, and failed-child states.
  Rendered cancelled/empty states were not individually exercised in the
  packaged pass.
- [x] Single click, arrows, double-click, `Command-Down`, `Command-Up`,
  context menu, and Retry policy work where applicable (command/policy suites;
  packaged arrow-selection, menu navigation, and shortcut pass). Rendered
  disclosure-click and focus-restoration inspection remain open below.
- [x] Back, Forward, Parent, Refresh, and breadcrumbs share one action
  availability policy (`RemoteWorkspaceSidebarPolicyTests`, command tests).
- [x] Copy Path, Name, Parent, and Shell-Quoted Path put exact text on
  the pasteboard without Return; lossy raw paths disable exact actions
  (pasteboard suites; packaged byte-level pasteboard verification, including
  the apostrophe shell-quoted form).
- [x] Switching tabs immediately shows the selected runtime's state and
  never recreates the retained terminal view (owner-tracking tests; packaged
  SSH-close returned the sidebar to the local explanation immediately;
  `TerminalPane` keying is unchanged in source).
- [ ] **Partial:** VoiceOver labels/roles, full keyboard-only traversal,
  Light/Dark, and Reduce Motion have no direct rendered evidence on this
  scripted-AX host; labels are unit-tested presentation strings and headings/
  status texts/rows were AX-visible. See Audit 0006 "Not performed" list.

## Performance and security

- [x] A 1,000-entry model/order/publication benchmark is below 100 ms
  (20.84 ms p90 recorded).
- [x] Scripted packaged interaction stayed responsive while opening and
  scrolling the 1,000-entry simulated directory; no stall was observed through
  scripted AX polling. Instruments-grade main-thread stall capture remains
  open.
- [x] Cache, response, path, component, diagnostics, entry-count, and
  provider concurrency bounds are tested (boundedness/contract suites).
- [x] Idle CPU is near zero and no poll/timer loop exists (0.0% sampled;
  source scan found no timer/polling).
- [x] Source/process/log inspection finds no shell wrapper, command
  interpolation, host-key bypass, credential/clipboard/terminal logging, remote
  daemon, recursive indexer, or human `ls` parsing (Audit 0006 scan section;
  one repository-hygiene finding: tracked `default.profraw`).
- [x] Full `./scripts/verify.sh` (404 tests / 51 suites, clean state),
  scoped and whole-source coverage, dependency review (zero new external
  dependencies), and ad-hoc codesign verification are recorded. Developer ID
  signing and notarization remain out of scope (ADR 0004).

## Scope boundary and completion

- [x] Audit confirms no Phase 4B mutation/transfer, Phase 5 terminal
  directory synchronization, or Phase 6 editor-sync code was started.
- [ ] **Blocked:** Packaged manual Relay acceptance resolves initial directory,
  lists real entries, navigates, refreshes, copies paths, switches tabs, and closes
  cleanly.
- [ ] **Blocked:** Phase 4A is marked complete only after ADR 0007's production
  transport gate and every applicable row above pass.
