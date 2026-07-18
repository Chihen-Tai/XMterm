# Audit 0006 — Phase 4A Remote Workspace Evidence

- **Date:** 2026-07-17; hardening and Task 9 closeout added 2026-07-18
- **Scope:** Execution Plans 0008 and 0009; Phase 4A foundation plus production
  read-only SFTP transport and real Relay acceptance
- **Status:** Phase 4A is **COMPLETE**. ADR 0007 is Accepted and every required
  production, package, real Relay, security, lifecycle, and verification gate
  passed.
- **Honesty rule:** historical simulated results below used the explicit
  `XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` in-memory developer fixture, whose
  every listing is labeled simulated. Only the Task 9 section is real Relay Host
  evidence; old fixture results are not reinterpreted.

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

## Historical pre-Task-9 scope boundary confirmation

Inspection of every changed and untracked file confirms: no Phase 4B mutation or
transfer surface, no Phase 5 terminal-directory synchronization, no Phase 6
editor sync, no VS Code integration, no SFTP packet code, no `sftp`/`ls`
parsing, no new external dependency, and no host-key weakening was introduced.
At that checkpoint Task 9 remained untouched and blocked behind ADR 0007's
acceptance gate; the later Task 9 section supersedes this historical boundary.

## Independent hardening handoff review (2026-07-18)

The review recovered stable base `2f7ffb1` and handed-off HEAD `16ef945`, read the
complete range and every affected source/test file, and continued on
`codex/phase-4a-hardening-review`. The pre-edit disposition was:

- **Revise provider composition:** the mode was carried by the workspace, but an
  arbitrary provider could still be constructed as `.production`, so the trust
  boundary was representational rather than enforced.
- **Keep focus routing:** exact-owner plus `@FocusState` gating matched the command
  contract; only stronger direct rendered evidence was required.
- **Keep the shared projection and selection state machine:** one projection
  already drove rows and selection; add deterministic eviction/history/hidden
  completion regressions and a separate projection performance gate.
- **Revise evidence records:** the handoff ledger claimed completion before an
  independent review and before the new release/package evidence existed.

### Corrected provider composition

`RemoteProviderComposition` now has a private raw initializer and package-scoped
provider/mode storage. Public clients can construct only `.unavailable()`.
Package code can construct the simulated mode only from the typed
`InMemoryRemoteFileProvider`; ordinary deterministic providers use the explicit
`.packageTest` mode. No production constructor exists. A future production seam
must be added with the concrete reviewed ADR 0007 transport, so arbitrary
providers cannot claim production or simulated presentation trust. The app store
consumes the composition rather than separate provider/mode values. The simulated
badge appears only for `.simulatedDeveloperFixture`; `.production`,
`.unavailable`, and `.packageTest` have none.

Provider RED/GREEN evidence:

- the initial composition test failed to compile because
  `RemoteProviderComposition` and the composition initializer did not exist;
- an external-client compiler probe then demonstrated that the handed-off public
  arbitrary-production seam compiled, and after correction the same probe was
  rejected;
- stronger tests expecting `.packageTest` failed at three assertions before that
  mode existed;
- final debug fixture suite passed **8 tests / 1 suite in 1.899 s**; an actual
  `#if !DEBUG` release test passed **9 / 1 in 1.855 s**;
- independent provider specification/code-quality reviews and the final security
  review approved the corrected boundary.

### Selection, projection, focus, and performance evidence

The production selection state machine was retained. The projection depth now
derives from `RemoteWorkspace.maximumExpandedDirectoryCount`, removing the second
literal authority. New deterministic tests prove:

- cache eviction moves a selected descendant to the nearest still-visible
  ancestor;
- history clears an exact descendant that is absent after deterministic eviction
  and reload;
- a nested completion behind a collapsed ancestor does not render or reselect the
  hidden descendant, while nested expansion intent is restored on re-expansion.

Focused results: descendant selection **12 / 1 in 0.480 s**, visible projection
**8 / 1 in 0.018 s**, performance **2 / 1 in 0.229 s**, and command routing
**23 / 1 in 0.175 s** with warnings as errors where applicable. The original
1,000-entry model/order/cache-publication p90 gate remains unchanged. A separate
test now constructs a 1,000-entry visible projection and performs 1,000 iterations
of exact hit/miss entry and selectability lookups; fixture setup is outside timing,
with one warm-up plus 11 measured runs, and p90 passed the 100 ms budget. The
focused suite duration is not substituted for the measured p90.

### Historical 2026-07-18 hardening packaged manual evidence

Debug shipping/default mode showed the local explanation and, after launching the
Relay profile, exactly `Remote file transport unavailable`, with no fake listing
or simulated badge. In simulated debug mode, the persistent accessible warning
`Simulated developer fixture. This listing is not a real remote host.` appeared
with 12 items.

With terminal focus, every Remote menu command was disabled. Clicking the `large`
row enabled the applicable commands; returning focus to the terminal disabled them
again. Direct Refresh and Back sidebar buttons still worked while terminal focus
remained active, including navigation to `/simulated/測試資料`. Switching to a local
tab disabled all Remote commands; switching back retained workspace state but kept
commands disabled until list focus returned. Navigation labels/help and the
simulated warning were exposed through the accessibility tree.

For release acceptance, the cold warnings-as-errors build passed, its binary was
staged into `dist/XMterm.app`, ad-hoc signed, and strict code-sign verification
passed. Launching that actual release bundle with
`XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` still showed transport unavailable and
no badge/listing. Both packaged passes quit through the live-SSH confirmation and
left no packaged XMterm process.

This new pass did **not** manually re-exercise exact terminal `Command-C` copy,
Control-byte input to the PTY, nested-directory `Command-Down`, exact rendered
collapse/refresh selection repair, two simultaneous SSH sessions, VoiceOver
auditory output, full Tab traversal, Light/Dark, Reduce Motion, disclosure-click,
Instruments, or pixel screenshots. Automated/source evidence and the earlier
2026-07-17 manual observations remain recorded separately; these omissions are not
presented as new rendered passes.

### 2026-07-18 verification and safety scans

A required 12-suite combined warnings-as-errors run executed **123 tests**; 122
passed and the pre-existing real-PTY integration test
`TerminalWorkspaceStoreTests.defaultWorkspaceTracksForegroundJobCompletion`
timed out under parallel suite load. The exact test then passed **1 / 1 in 2.125
s**, the entire suite passed **13 / 1 in 7.106 s**, and the clean full verifier
passed the same case in 2.127 s. The combined invocation is not claimed as a pass;
all required suites have passing isolated or clean-full evidence.

Debug and release warnings-as-errors builds passed; the final cold release build
completed in **61.23 s**. After `swift package clean`, `./scripts/verify.sh` passed
**436 tests in 53 suites in 8.716 s** and printed `XMterm verification: OK`.
Static scans found no forbidden shell/SFTP/host-key pattern, production logging of
sensitive values, Phase 4B mutation or polling surface, machine-specific path,
tracked generated artifact, dependency change, or whitespace error. The only
“token” source hit was the non-secret `scrollRestorationToken`. The historical
`default.profraw` finding above remains preserved and resolved in `2f7ffb1`.

Independent final code and security reviews approved the resulting change set.
No file was removed and no external dependency was added. Task 9 and Phase 4B/5/6
remain untouched.

## Task 9 production transport and real Relay closeout (2026-07-18)

### Implemented production boundary

The accepted transport keeps the terminal on its interactive PTY-backed
`/usr/bin/ssh` process. Each supported SSH runtime independently owns a concrete
`OpenSSHSFTPRemoteFileProvider`, serialized `OpenSSHSFTPClient`, bounded binary
SFTP v3 codec, and noninteractive `/usr/bin/ssh -T -o BatchMode=yes -s ... sftp`
subsystem process. The codec sends only `INIT`, `REALPATH`, `OPENDIR`, `READDIR`,
and `CLOSE`; it parses structured `VERSION`, `STATUS`, `HANDLE`, `NAME`, and attrs,
preserves raw filename bytes, ignores `longname`, validates request IDs and bounds,
and tears down on any possible desynchronization.

The process channel keeps stdout binary-only and stderr separate/bounded. Its
writer is readiness-driven and nonblocking (`O_NONBLOCK` and `F_SETNOSIGPIPE`) with
finite timeout/cancellation. Close invalidates work, closes descriptors, escalates
HUP/TERM/KILL within bounds, and retains late reaping. Production composition is
constructible only with the concrete provider; release ignores the simulated
fixture gate.

### TDD, review, and automated evidence

RED evidence comprised missing codec/target/client/provider/process/composition
compile failures. The first review found one High synchronous-write wedge and
Medium malformed-name/reaping issues; security review found Medium write and auth-
diagnostic classification issues. A regression with a 1 MiB write and closed peer
failed by signal 13 before the nonblocking fix. All findings were fixed test-first.
Independent code and security re-review reported no remaining Critical, High, or
Medium finding and approved production acceptance.

Focused production suites passed **22 tests in 6 suites in 0.135 s**. The full
pre-closeout verifier passed **471 tests in 59 suites in 7.672 s** and printed
`XMterm verification: OK`. Debug and release warnings-as-errors builds passed; the
cold release build completed in **10.43 s**. The focused performance suite passed
**2 / 1 in 0.235 s**, preserving the original **20.84 ms p90** local publication
gate and the separate projection p90 below 100 ms. Static scans found no production
logging, human-output parser, shell wrapper, host-key bypass, mutation SFTP verb,
new dependency, or Phase 4B/5/6 surface.

### Packaged and real Relay evidence

The staged debug app and ad-hoc signed release both loaded real Relay data. The
signed package binary UUID matched the release build UUID
`E193E631-5778-3732-94B7-7E0036ED8998`; strict code-sign verification passed.
Launching that release with `XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` still
showed the real production listing and no SIMULATED badge. Local tabs owned no
workspace transport.

The exact subsystem argv observed for Relay was:

```text
/usr/bin/ssh -T -o BatchMode=yes -s -p 54426 allen921103@140.109.226.155 sftp
```

The interactive terminal simultaneously used its separate
`/usr/bin/ssh -p 54426 allen921103@140.109.226.155` process. Authentication was
public key through a configured OpenSSH key. `ssh-agent` exposed no identities,
`ControlMaster` was false, and normal known-host policy succeeded; no host-key
bypass or Keychain use is claimed.

Real listings resolved `/home/JoeyJen`, `/home/allen921103`, `/Data2`,
`/Data2/allen921103`, and `/`. Acceptance exercised Back, Forward, Parent,
breadcrumb, Refresh, lazy expansion, nested selection, and exact Copy Path/Name/
Parent/Shell-Quoted values. Expanding protected `/root` exposed an honest Retry
error rather than an empty listing. Two Relay runtimes showed independent current
directories/state and two independent subsystem processes.

After manually entering `ssh g207`, the terminal reached
`allen921103@g207:/Data2/allen921103` while the workspace remained attached to and
operable against the immutable Relay snapshot. Closing one Relay tab reaped its
provider process; quitting reaped the remainder. No XMterm or SFTP child remained.

### Scope and limitations

No mutation, transfer, multi-selection, drag/drop, local editor, sync, automatic
second-hop retargeting, reconnect, distribution signing, or notarization work was
added. Developer ID/notarization, full VoiceOver auditory output, exhaustive
keyboard traversal/appearance/Reduce Motion, Instruments, and the 10,000-entry
release benchmark remain later release evidence, not Phase 4A Task 9 blockers.

## Final verification

Historical checkpoints remain above: 404/51 for the original foundation and
436/53 for hardening. Task 9's pre-closeout verifier passed 471/59. At the final
stable checkpoint, `swift package clean` succeeded and `./scripts/verify.sh`
passed **471 tests in 59 suites in 7.891 s**, ending with `XMterm verification:
OK`.

## Recommended next task

**Phase 4B — Remote File Mutations and Transfers.** Phase 4A is complete; Phase 4B
was not started during this closeout.
