# Audit 0006 — Phase 4A Remote Workspace Foundation Evidence

- **Date:** 2026-07-17
- **Scope:** Execution Plan 0008 Tasks 1–8 and 10 (Task 9 remains blocked)
- **Status:** Phase 4A is **PARTIAL**. The session-centric runtime, remote domain,
  provider boundary, state machine, cache, native simulated UI, navigation, copy
  actions, testing, and performance foundation are implemented. The production
  structured SFTP transport and the real Relay Host listing remain blocked by
  ADR 0007 (Proposed).
- **Honesty rule:** every simulated result below used the explicit
  `XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` in-memory developer fixture, whose
  every listing is labeled simulated. Nothing here is real Relay Host evidence.

## Interruption recovery

The prior working session was lost after committing the Task 7 Step 1 RED tests.
Recovery on 2026-07-17 confirmed: clean tree identical to `origin/main`
(`2a9894a`), production `swift build` green, and the test target failing to
compile with `cannot find 'RemoteWorkspaceCommandRoute' in scope` /
`cannot find 'RemoteWorkspaceKeyboardCommand' in scope` — the committed RED
state. `RemoteEntryRow.swift` and `RemoteWorkspaceSidebar.swift` did not exist.
Work continued from Task 7 without recreating any completed task.

## Task 7 implementation summary

Created production files:

- `Sources/XMtermApp/RemoteWorkspace/RemoteEntryRow.swift` — one entry row plus
  the honest child-status row; escaped display names, kind icons, metadata help,
  accessibility labels, directory-only disclosure, no tasks, no open/mutation.
- `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceSidebar.swift` — sidebar
  states (neutral, local explanation, connecting/loading, failed + Retry,
  listing, empty), navigation header, structured breadcrumbs, bounded row
  flattening over cached listings only, single selection bound to the workspace,
  shared-policy context menus, and the `RemoteWorkspaceSidebarInteraction` seam.
- `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceDeveloperFixture.swift` —
  the explicit env-gated simulated provider (Task 8 Step 6 injection seam);
  shipping default remains `UnavailableRemoteFileProvider`.

Modified production files:

- `Sources/XMtermApp/TerminalWorkspaceCommands.swift` — added
  `RemoteWorkspaceKeyboardCommand` (`Command-Down` open, `Command-Up` parent,
  Return deliberately unbound), `RemoteWorkspaceCommandRoute`,
  `RemoteWorkspaceActionPerformer`, `RemoteWorkspaceFocusedActions.forRuntime`,
  `TerminalWorkspaceStore.selectedRemoteWorkspaceFocusOwner`, and the Remote
  command menu (Back `⌘[`, Forward `⌘]`, Parent `⌘↑`, Open `⌘↓`, Refresh `⌘R`,
  four copy actions). Terminal commands are unchanged.
- `Sources/XMtermApp/RemoteWorkspace/RemoteWorkspaceFocusedValues.swift` — added
  the `isOwnerCurrent` exact-owner guard accessor; `perform` behavior unchanged.
- `Sources/XMtermApp/RootView.swift` — sidebar column now holds compact Saved
  Sessions above `RemoteWorkspaceSidebar`, width 240/320/420. The detail column,
  `TerminalPane` keyed by terminal-session identity, alerts, sheets, and command
  wiring are untouched.
- `Sources/XMtermApp/TerminalWorkspaceStore.swift` — the default
  `remoteWorkspaceFactory` routes through the developer-fixture gate (identical
  unavailable provider unless the env var is set).

Tests: `TerminalWorkspaceCommandTests.swift` grew from 9 committed RED tests to
18 (routing to exact workspace methods, retry routing, pasteboard routing,
context-copy policy parity, store focus-owner tracking, stale-owner rejection,
sidebar interaction routing, unbound Return, unchanged terminal routing; three
committed RED call sites gained a missing `try`).
`RemoteWorkspaceDeveloperFixtureTests.swift` (3 tests) covers the injection
gate, determinism, labeling, and bounds. This test file is an addition to the
plan's file map, recorded here.

## Cross-task review of Tasks 5–7

The multi-agent review workflow could not run (subagent session limits), so an
inline dimension-by-dimension review was performed instead across: RuntimeSession
ownership and aggregate close settlement; store registry and tab-switch
isolation; policy and exact-owner guards; pasteboard behavior; terminal
regression risk; and sidebar/row correctness. Findings:

1. **Medium (fixed):** current-directory copy context menu was unreachable in an
   empty directory (menu-bar commands still worked). Fixed by attaching the same
   shared-policy context menu to the empty state.
2. **Medium (fixed, found in packaged manual pass):** a failed navigation target
   (e.g. permission denied) kept the prior directory correctly but displayed the
   failure nowhere, violating FILE-NAV-002's "displays the failure honestly."
   Fixed: a collapsed directory whose last load failed or was cancelled now
   renders its honest status row beneath its row; Retry appears only where
   `RemoteWorkspace.retryDirectory` can actually act (expanded children).
3. No Critical or High finding. Stale policy snapshots cannot cause incorrect
   mutation because every workspace method re-guards internally; new menu
   shortcuts collide with no existing terminal shortcut; the ⌘W menu normalizer
   is unaffected. Tasks 5 and 6 were not reimplemented.

## Automated verification

- Focused: `TerminalWorkspaceCommandTests` 18/18; the nine related suites
  (presentation, sidebar policy, pasteboard, runtime session, registry, launch
  coordinator, profile store, SSH coordination, shutdown coordination) 80/80;
  developer fixture 3/3.
- Full verifier from a **clean build state** (`swift package clean` then
  `./scripts/verify.sh`): **404 tests in 51 suites in 7.302 s**, exit OK,
  94.45 s wall including the cold build. Re-run after the FILE-NAV-002 display
  fix: see the final verification section below.
- Warnings-as-errors isolated builds: debug **82.55 s**, release **147.59 s**,
  both clean.

## Coverage (2026-07-17, `swift test --enable-code-coverage`, 404 tests)

- `XMtermRemote` sources: **93.27% lines / 94.25% functions**.
- New app remote-workspace logic excluding SwiftUI bodies
  (`RemoteWorkspacePresentation`, `RemotePathPasteboard`,
  `RemoteWorkspaceFocusedValues`, `RemoteWorkspaceDeveloperFixture`,
  `RuntimeSession`): **94.49% lines / 82.54% functions**.
- UI-inclusive remote-workspace app scope (adds `RemoteWorkspaceSidebar`,
  `RemoteEntryRow`, and `TerminalWorkspaceCommands` menu bodies the unit harness
  cannot instantiate): **42.29% lines / 45.89% functions**.
- Whole first-party `Sources`: **58.11% lines / 63.42% functions**.

Scoped results are never presented as whole-project coverage; the lower
UI-inclusive and whole-source numbers are retained deliberately.

## Security and source-policy scans

`rg` source inspection found: no shell wrapper or `sh -c`/`bash -c`/`zsh -c`
usage; no `StrictHostKeyChecking`/`UserKnownHostsFile` override; no `sftp`/human
`ls` parsing; no `print`/`NSLog`/`os_log` logging in `Sources`; no
timers/polling; no recursive enumeration; no remote mutation verbs in
`XMtermRemote`; no credential or key material (test hits are negative-assertion
fixtures); no machine-specific paths beyond synthetic `/Users/example` and
`/Users/alice` fixtures (one of which asserts non-disclosure). The three
pre-existing `Task.detached` uses are the documented Phase 1 PTY blocking-I/O
boundary in `PTYProcessController`, unchanged by Phase 4A. Pasteboard writes are
exactly the two designed sites (terminal selection copy and the single-item
remote path adapter); neither logs content. External dependency count added by
Phase 4A: **zero** (SwiftTerm 1.14.0 pinned, plus its transitive
swift-argument-parser, both pre-existing).

**Finding (repository hygiene):** `default.profraw` (438 KB generated coverage
artifact) is tracked in git from an earlier commit. Recommended:
`git rm --cached default.profraw` plus a `*.profraw` ignore entry in the next
commit. Not applied here because this session was not asked to commit.

> **Resolved in commit `2f7ffb1`:** `default.profraw` was removed from version
> control and `*.profraw` was added to `.gitignore`. The original finding above
> is preserved as historical context; the repository no longer tracks any
> generated `.profraw` artifact.

## Packaged simulated manual foundation verification

Staged with `./script/build_and_run.sh --verify` (ad-hoc signed, codesign
verified). All remote listings below are the **simulated** fixture; the terminal
capability of an SSH tab still runs real `/usr/bin/ssh` and sat at its normal
in-terminal OpenSSH prompt with no credentials entered.

Shipping mode (no environment value):

- Local tab: sidebar showed `Remote Workspace` heading and
  `Remote Workspace is available for SSH sessions`; no tree, no fake data.
- Idle app: **0.0% CPU**, ~102.9 MB RSS after settling (≤120 MB idle budget).
- SSH tab (Relay Host profile launched keyboard-only through File ▸ Choose
  Session… → type `relay` → Return): sidebar showed exactly
  `Remote file transport unavailable` with the bounded ADR 0007 guidance — the
  honest blocked-transport state, no listing.
- Close Terminal on the live SSH tab presented the SSH confirmation
  (Cancel/Close); Close reaped the ssh child and the sidebar returned to the
  local explanation immediately.

Simulated fixture mode (`open -n dist/XMterm.app --env
XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated`):

- SSH tab loaded `/simulated`: status `12 items`, native outline with exactly
  12 rows; splitter at 248 pt (inside the 240–420 bound); terminal remained the
  dominant area.
- AX row selection routed through the workspace: selecting the `large` row and
  invoking Remote ▸ Copy Path wrote exactly `/simulated/large` — verified at
  byte level (16 bytes, **no trailing Return/newline**).
- Remote ▸ Open on `large`: `1000 items` published within ~2 s wall (including
  the fixture's deliberate 250 ms latency and AX polling); the outline
  materialized 1,000 rows; scroll-to-bottom-and-back stayed responsive; deep-row
  selection (row 100) plus Copy Name wrote the deterministic `folder-099`.
- Remote ▸ Back returned to `12 items`; Remote ▸ Refresh reloaded in place with
  no history change.
- Copy Shell-Quoted Path on `o'brien's notes.txt` wrote exactly
  `'/simulated/o'"'"'brien'"'"'s notes.txt'`.
- Arrow keys moved the native selection after focusing the list (row 9 → 10).
- `Command-Down` opened the selected directory (`1000 items`) and `Command-Up`
  returned to the parent (`12 items`) via the real menu shortcuts.
- Opening the `denied` directory failed honestly: the current directory and
  listing remained intact, and (after the fix above) an explicit
  `Couldn't load this directory` status row rendered beneath the denied row.
- Quit with a live SSH tab presented the aggregate confirmation
  (Cancel / Quit XMterm); confirming quit exited cleanly and reaped that
  instance's ssh child.
- The clipboard was empty before the pass and restored to empty afterward; no
  clipboard content was logged.

**Observation (pre-existing, not Phase 4A):** the staging script's
`stop_running_project_app` TERM→KILL path force-killed a prior app instance
during restage, orphaning that instance's ssh child (reaped manually). The
app-managed close and quit paths reaped their children in both verified flows.

Not performed on this Command Line Tools-only, scripted-AX host: an actual
VoiceOver auditory pass, full Tab-key traversal audit, Light/Dark rendered
appearance comparison, Reduce Motion toggle, rendered disclosure-click
inspection, Instruments main-thread stall capture, and pixel screenshots. Nav
button and row accessibility labels are set in source and unit-tested as
presentation strings, but their rendered AX exposure was only partially
confirmed (window/list structure, headings, status texts, and row selection
were; per-button label attributes were not readable through System Events at the
paths tried). These remain open rows in the acceptance checklist.

## Performance evidence

- 1,000-entry model/order/cache-publication gate: **20.84 ms p90** vs the 100 ms
  budget (`RemoteWorkspacePerformanceTests`; fixture construction measured
  separately; one warm-up plus 11 publications; debug/test overhead included).
- Packaged idle CPU 0.0% sampled after settling; no polling or timer exists in
  the workspace path.
- Bounds under test: 32 cached directories, 20,000 cached entries, 10,000
  entries/32 MiB per response, 32 KiB paths, 4 KiB components, two concurrent
  provider requests, one per directory, bounded history and expansion sets.

## Scope boundary confirmation

Inspection of every changed and untracked file confirms: no Phase 4B mutation or
transfer surface, no Phase 5 terminal-directory synchronization, no Phase 6
editor sync, no VS Code integration, no SFTP packet code, no `sftp`/`ls`
parsing, no new external dependency, and no host-key weakening was introduced.
Task 9 remains untouched and blocked behind ADR 0007's acceptance gate.

## Final verification

After the FILE-NAV-002 honesty fix, `./scripts/verify.sh` passed **404 tests in
51 suites** on 2026-07-17 (the clean-state run earlier the same day also passed
404/51). Both warnings-as-errors builds remain clean.

## Recommended next task

**Complete Phase 4A production SFTP transport under ADR 0007.** Do not begin
Phase 4B while the transport gate is unresolved.
