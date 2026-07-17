# Execution Plan 0005: Phase 2 SSH Terminal Integration

- **Status:** Complete; deterministic, staged, and bounded real-relay evidence recorded
- **Started:** 2026-07-16
- **Scope:** One fixed relay-host SSH terminal type through the existing Phase 1 PTY
- **Depends on:** Execution Plans 0003 and 0004

## Goal

Add independently selectable SSH terminal tabs that directly execute system
OpenSSH for the one declared relay target while preserving every Phase 1 local
terminal behavior and lifecycle invariant.

The fixed production launch is:

```text
executable: /usr/bin/ssh
arguments:  -p
            54426
            allen921103@140.109.226.155
```

The executable and arguments remain separate structured values all the way to
`execve`. No shell wrapper, command string, second hop, profile editor, SFTP, or
reconnect behavior belongs to this plan.

## Acceptance requirements

Phase 2 directly implements or preserves the applicable subsets of:

- `APP-002`, `APP-003`, `APP-007`, `APP-008`
- `TERM-SEL-001` through `TERM-SEL-004`
- `TERM-CLIP-001` through `TERM-CLIP-003`
- `TERM-SCROLL-001`, `TERM-FIND-001`
- `TERM-KEY-001` through `TERM-KEY-004`, `TERM-PROC-001`
- `TERM-RENDER-001`, `TERM-RENDER-002`, `TERM-RESIZE-001`
- `TERM-STATE-001`, `TERM-SEC-001`
- the create/select/status subsets of `TAB-001`, `TAB-002`, and `TAB-005`
- the SSH close and tab-isolation requirements in `TAB-003`
- the fixed relay action subset of `SESS-002`
- the raw in-terminal OpenSSH prompt subset of `SESS-003`
- the argument-safe system OpenSSH subset of `SESS-004`
- applicable `A11Y-001` through `A11Y-003`, `MAC-001`, `MAC-002`, and `MAC-006`

`SESS-001`, the richer connection-state portions of `SESS-005`, reconnect in
`TERM-STATE-001`, and the remainder of `TAB-002`, `TAB-004`, and `TAB-005` stay
partial or deferred. `SESS-006` is not applicable until SFTP exists.

## Baseline and preparation evidence

Before this plan was written, the engineering contract, every required top-level
document, every file under `docs/`, the Phase 1 plans/audit, and the relevant
process, session, tab, close, UI-command, and test sources were read completely.

The untouched baseline command was:

```bash
./scripts/verify.sh
```

It exited 0 on 2026-07-16 with **97 tests in 16 suites passed** and
`XMterm verification: OK`. Phase 1 Audit 0002 and Execution Plans 0003/0004 remain
historical evidence and will not be rewritten as Phase 2 evidence.

## Design alternatives considered

### Selected: typed launch target over the existing session and PTY

Add a small terminal-target value, a fixed SSH launch specification, and
target-aware presentation/close policy. Continue to use the same
`TerminalSession`, `XMtermTerminalView`, `PTYProcessController`, and C `forkpty` /
`execve` shim. This is the smallest design that preserves one renderer, one bounded
scrollback buffer, and the proven cleanup behavior.

### Rejected: separate SSH terminal/session implementation

A second SSH-specific session or renderer would duplicate input, selection,
clipboard, resize, output filtering, scrollback, and cleanup logic and would create
avoidable Phase 1 regressions.

### Prohibited: shell command construction

Launching `/bin/zsh -c`, `/bin/sh -c`, interpolating a command string, or parsing
prompt text would violate `SESS-004`, weaken argument safety, and invent connection
state that OpenSSH has not exposed reliably.

## Current architecture reuse

```text
TerminalWorkspaceStore (stable local and SSH tab IDs)
  -> TerminalSession (one target-aware launch and lifecycle coordinator)
    -> retained XMtermTerminalView / SwiftTerm 1.14.0
      -> TerminalOutputSecurityFilter
      -> narrow TerminalProcess protocol
        -> PTYProcessController actor
        -> CXMtermPTY forkpty/chdir/execve
          -> local login shell OR /usr/bin/ssh
```

No file descriptor enters the UI. No terminal output is copied into SwiftUI state.
`PTYProcessController` remains executable-agnostic and retains its bounded,
readiness-driven I/O, resize coalescing, final drain, signal escalation, descriptor
closure, and direct-child reaping behavior.

`TerminalSession` currently depends directly on the concrete controller, despite
`TESTING.md` requiring a deterministic PTY fake. Add only the process operations
the session already consumes—read, write, resize, wait, foreground classification,
and close—to a package protocol plus an injected async launcher. The production
launcher remains `PTYProcessController.launch`; a controllable test actor makes
session/store lifecycle tests deterministic without opening the real relay or
weakening production launch.

## SSH launch specification

Create one immutable `SSHRelayLaunchSpecification` whose production constants are:

- executable URL/path: `/usr/bin/ssh`;
- argument zero: no custom login-shell value;
- ordered arguments: `-p`, `54426`, `allen921103@140.109.226.155`;
- local working directory: the current user's home directory;
- environment: inherited process environment plus XMterm's existing `TERM` and
  `TERM_PROGRAM` overrides.

The SSH process must not set `SHELL=/usr/bin/ssh`. Local shell launch retains its
existing login `argv[0]` and `SHELL` override. Missing, non-executable, or denied SSH
launches flow through the existing pre-exec startup error pipe into a typed launch
failure.

The endpoint is a direct user-authorized exception to the repository's normal
fixture rule against real endpoints. It is treated as declared public launch data,
not as a credential. No other production host, username, key path, password, OTP,
prompt content, terminal input, or clipboard content enters source, tests, or logs.

## Tab model changes

- Add `TerminalTabKind.local` and `TerminalTabKind.relaySSH`.
- Store the kind immutably on each `TerminalTab` beside its stable UUID.
- Generalize immutable tab creation to accept a kind.
- Preserve local titles (`Local Shell`, `Local Shell 2`, ...).
- Give relay tabs an initial title of `Relay Host`, then `Relay Host 2`, ... for
  additional relay tabs.
- Keep independent selected ID, retained terminal view, process, selection,
  scrollback, output status, and lifecycle for every tab.
- Keep dynamic title filtering unchanged; Phase 2 does not add rename or OSC title
  support.

## Connection-state design

The shared process lifecycle gains an explicit pre-launch `idle` state and a
`startRequested` event:

```text
idle -> starting -> running -> closing -> exited(exit code or signal)
              \-> failed(PTY creation or launch)
       running \-> failed(read, write, or resize)
```

For SSH presentation, expose the exact semantic projection:

```text
idle
starting
processRunning
closing
exited
failed
```

`running`/`processRunning` means only that `/usr/bin/ssh` successfully replaced the
child and has not exited. It does not mean connected, authenticated, or at a remote
shell. XMterm will not parse `$`, `#`, hostnames, prompt phrases, or terminal output
to infer connection success. User-facing copy is neutral: `Starting SSH`,
`SSH session active`, `SSH process exited`, or `SSH failed`.

## Authentication- and host-key-prompt behavior

OpenSSH remains inside the real PTY and owns config, `ssh-agent`, macOS Keychain
integration, `IdentityFile`, `known_hosts`, first-use and changed-host-key handling,
passwords, keyboard-interactive/OTP, and key-passphrase prompts. XMterm forwards
the same unlogged PTY input and filtered output used by local terminals.

OpenSSH diagnostics and prompts remain visible in the relay tab. Phase 2 adds no
prompt parser, custom credential dialog, credential store, authentication logging,
or host-key bypass. The broader typed prompt experience in `SESS-003` remains
partial because the tab shows OpenSSH's own terminal flow.

## Error and process-exit behavior

- PTY creation and pre-exec launch failure produce target-appropriate concise UI
  state without hiding the typed failure.
- Network, connection-refused, authentication, host-key, and remote-side errors
  remain visible as OpenSSH terminal output.
- A normal, nonzero, or signal exit remains typed as `exited`; nonzero OpenSSH exit
  is not reclassified by parsing its text.
- Read, write, and resize failures remain typed failures and trigger existing
  deterministic cleanup.
- Final PTY output drains before exit completion. The exited relay tab retains its
  terminal view, selection, and scrollback with input disabled.
- Closing one relay tab cannot remove, close, or reroute output to a local or other
  relay tab.

## Close-tab and shutdown behavior

Local tabs keep the exact Phase 1 `tcgetpgrp` policy.

For relay tabs:

- `exited` or `failed`: close immediately;
- SSH process still running: always return a new `confirmSSHSession` disposition;
- do not query the local PTY foreground group to infer remote activity;
- confirmation title: `Close this SSH terminal?`;
- confirmation body: `Closing the tab will terminate the SSH session and may stop
  a command currently running in this terminal.`;
- Cancel leaves the session untouched;
- Close invokes the existing PTY/process cleanup and never injects `Control-C`,
  `Control-D`, or `exit`.

Window close and application quit aggregate live SSH sessions separately from
local foreground jobs and unknown local foreground states. One aggregate prompt
uses honest wording and cleanup completion still waits for every retained session.

## UI and accessibility design

- Replace the tab-strip plus button with an accessible menu containing `New Local
  Terminal` and `Connect to Relay Host`.
- Add matching File/menu commands routed through one weakly rebound window command
  router. `Command-T` remains the unchanged local-terminal shortcut; relay launch
  is keyboard reachable through the menu without stealing a Control sequence.
- Keep the sidebar unchanged; the plus and File menus are the clear local/relay
  action surfaces for this fixed-target slice.
- Parameterize terminal-pane accessibility labels, starting/status copy, tab
  symbols/help, empty state, and close prompts by tab kind.
- Preserve focus restoration to the created/selected/replacement terminal.
- Keep status non-color-only through icon plus text/help/accessibility labels.

## Files to create

- `Sources/XMtermCore/Models/TerminalTabKind.swift`
- `Sources/XMtermTerminal/PTY/TerminalProcess.swift`
- `Sources/XMtermTerminal/Session/SSHRelayLaunchSpecification.swift`
- `Sources/XMtermApp/TerminalPresentationPolicy.swift`
- `Tests/XMtermCoreTests/SSHTerminalTargetTests.swift`
- `Tests/XMtermTerminalTests/SSHRelayLaunchSpecificationTests.swift`
- `Tests/XMtermTerminalTests/TerminalSessionSSHTests.swift`
- `Tests/XMtermTerminalTests/TestSupport/ControllableTerminalProcess.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceStoreSSHTests.swift`
- `Tests/XMtermAppTests/TerminalPresentationPolicyTests.swift`
- `docs/exec-plans/0005-phase-2-ssh-terminal-integration.md`
- `docs/checklists/ssh-terminal-acceptance.md`
- `docs/audits/0003-phase-2-ssh-terminal-evidence.md`

## Files expected to modify

Production and tests:

- `Sources/XMtermCore/Models/TerminalTab.swift`
- `Sources/XMtermCore/Terminal/TerminalLifecycle.swift`
- `Sources/XMtermCore/Terminal/TerminalTabsState.swift`
- `Sources/XMtermTerminal/PTY/PTYProcessController.swift` only to conform to the
  narrow process protocol; its spawn/I/O/cleanup algorithms remain unchanged
- `Sources/XMtermTerminal/Session/TerminalSession.swift`
- `Sources/XMtermTerminal/Session/TerminalSessionModels.swift` if target-specific
  presentation state needs a focused value type
- `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- `Sources/XMtermApp/TerminalWorkspaceCommands.swift`
- `Sources/XMtermApp/TerminalTabStrip.swift`
- `Sources/XMtermApp/TerminalPane.swift`
- `Sources/XMtermApp/RootView.swift`
- `Tests/XMtermCoreTests/TerminalDomainTests.swift`
- `Tests/XMtermTerminalTests/TerminalSessionIOFailureTests.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- `Tests/XMtermAppTests/XMtermApplicationDelegateTests.swift` only if menu routing
  changes require additional normalization coverage
- `scripts/verify.sh`

Status and contract documentation:

- `README.md`
- `ARCHITECTURE.md`
- `INTERACTIONS.md` only for an implementation-status note; canonical future
  requirements remain intact
- `PLANS.md`
- `PERFORMANCE.md`
- `SECURITY.md`
- `TESTING.md`
- `docs/checklists/interaction-parity.md`
- `docs/checklists/terminal-acceptance.md`
- `docs/decisions/0004-macos-sandbox-and-distribution.md`
- `docs/design-docs/v0.1-mvp.md`
- `docs/design-docs/session-tabs-ux.md`
- `docs/design-docs/terminal-ux.md`
- `docs/design-docs/terminal-keyboard.md`
- `docs/design-docs/terminal-compatibility.md`
- `docs/design-docs/ssh-connection-lifecycle.md`

Historical Phase 1 audit, plans, and ADR 0003 are intentionally not modified.

## TDD implementation sequence

### 1. Tab kind and honest lifecycle

- [x] Add failing domain tests for idle/start transitions, exact SSH process-state
  projection, stable relay identity/title, local/relay coexistence, independent
  selection, neighboring close, and local title regression.
- [x] Run the focused domain/full verifier and verify the failures are due
  to missing kind/state behavior.
- [x] Add the smallest immutable kind, lifecycle, and tab-state implementation.
- [x] Re-run the focused suite and keep all existing domain tests green.

### 2. Exact launch specification

- [x] Add failing tests asserting `/usr/bin/ssh`, the exact three arguments and
  their order, normal argument zero, absolute local working directory, structured
  argv, no shell wrapper, no command string, and no secret-bearing launch field.
- [x] Verify RED, then implement `SSHRelayLaunchSpecification` and target-aware
  launch-configuration construction.
- [x] Add a controlled process actor through the same configuration boundary and
  retain existing real-PTY executable fixtures; no automated test connects to the
  relay host.
- [x] Re-run launch and existing PTY validation/lifecycle tests.

### 3. Session lifecycle, failure, exit, and close policy

- [x] Add failing policy tests proving a running relay returns
  `confirmSSHSession` regardless of local foreground-process classification, while
  idle/exited/failed relay and all existing local cases remain correct.
- [x] Reuse the existing `/bin/cat`, missing-file, status, signal, cleanup, and
  real-PTY fixtures. Add an injected `ControllableTerminalProcess` actor for precise
  session output, EOF, exit, input/resize, launch, close, and foreground-query tests.
- [x] Verify RED, introduce the narrow `TerminalProcess`/launcher seam, generalize
  `TerminalSession` from shell resolution to a typed launch provider, and add
  target-specific failure/status copy without changing production
  input/output/resize/security-filter behavior.
- [x] Re-run focused session/PTY suites.

### 4. Workspace coexistence and shutdown

- [x] Add failing workspace tests for relay creation, stable kind/identity, one
  local plus one relay session, switching, independent close, live relay Cancel and
  Close, exited/failed immediate close, stale decision isolation, and aggregate
  relay counts.
- [x] Verify RED, extend the session factory and immutable creation path, and add
  SSH close/shutdown disposition handling.
- [x] Re-run the entire app test target and existing real-local-shell close matrix.

### 5. Native action and presentation

- [x] Add or update focused command/presentation tests where behavior is separable from
  SwiftUI layout.
- [x] Add the plus menu, File/menu action, kind-aware labels/status, creation
  availability, and exact close alert copy without redesigning the sidebar.
- [x] Build with warnings as errors and manually inspect keyboard reachability,
  focus restoration, non-color status, and local/relay action parity.

### 6. Documentation and evidence

- [x] Create the SSH acceptance checklist and Phase 2 evidence audit.
- [x] Update architecture, roadmap, requirement status, security exception,
  performance notes, testing strategy, interaction parity, and known limitations.
- [x] Mark implemented, partially implemented, deferred, blocked, or not applicable
  without upgrading unverified canonical requirements.

## Automated test plan

Required new coverage includes:

- exact executable and ordered arguments; no wrapper or command string;
- stable relay tab ID and title;
- local and relay coexistence, selection, retained session/view state, and close
  isolation;
- idle, starting, process-running, normal/nonzero/signal exit, launch failure, and
  failed I/O projection;
- live-relay conservative close, Cancel, confirmed cleanup, exited/failed immediate
  close, window/quit aggregate behavior, and unchanged local foreground policy;
- final output drain, descriptor/process cleanup, no zombie, and independent child
  lifetime through controlled local fixtures;
- exact session launch capture plus deterministic output/EOF/exit/failure/close
  behavior through a fake process that implements the same narrow protocol;
- unchanged exact Control bytes, local Command shortcuts, multiline paste safety,
  resize, selection, scrollback, search, Unicode, and output-filter suites;
- absence of password/OTP/passphrase persistence, terminal-input logging, prompt
  logging, clipboard logging, shell interpolation, and secret-bearing SSH options.

Automated tests must not depend on the real relay or mutate the user's SSH config,
agent, Keychain, or known-hosts state.

## Security risks and mitigations

- **Credential disclosure:** do not log terminal input/output, prompts, clipboard,
  environment dumps, passwords, OTPs, passphrases, or key paths.
- **Command injection:** fixed executable and ordered argument array; no shell.
- **Host-key bypass:** never add `StrictHostKeyChecking=no` or alter `known_hosts`.
- **Remote escape effects:** preserve the complete Phase 1 output filter, including
  denied OSC 52; SSH output receives no special bypass.
- **Misleading state:** never claim connected/authenticated based on process
  lifetime or prompt parsing.
- **Accidental remote termination:** every live relay close confirms and uses
  lifecycle cleanup rather than injected shell bytes.
- **Endpoint exposure:** only the explicitly authorized public relay endpoint is
  committed; all other fixtures remain synthetic/local.

## Performance risks and mitigations

- Reuse one bounded SwiftTerm buffer per tab; do not add a second scrollback copy.
- Reuse readiness-driven dispatch sources; add no timer, polling loop, or network
  monitor.
- Keep PTY reads/writes off the main actor and input/resize queues bounded.
- Avoid per-character SwiftUI updates; only lifecycle/alert/title/focus state is
  observable.
- Keep inactive retained terminal views from unnecessary redraw as in Phase 1.
- Compare local-terminal verification and a settled relay process against the
  documented CPU/memory budgets when feasible; do not attribute network latency to
  local input routing.

## Manual acceptance plan

Run the staged app and, only when user credentials/interactive access are already
available, verify the exact relay command in the new tab. Record each check as
passed, failed, not encountered, blocked, or not performed. Never claim password,
OTP, passphrase, changed-host-key, Keychain, or host-key-first-use verification
unless that exact flow occurs.

The checklist covers relay launch, agent/Keychain behavior, prompts, resize and
`stty size`, Control/Command distinctions, selection/copy/paste, scrollback/search,
Traditional Chinese committed input, emoji, `vim`, `less`, manual `ssh g207` and
return, active/exited close behavior, cross-tab isolation, child reaping, and log
privacy.

## Explicitly deferred

- SFTP and remote file browser;
- Session Manager, profile editor, alias discovery, and SSH config import UI;
- `ssh -G` inspection UI and effective-config presentation;
- ProxyJump UI or automatic second-hop SSH;
- direct `g207`, `g204`, or `g209` profiles/tabs;
- reconnect, automatic reconnect, sleep/wake recovery, and network monitoring;
- tunnel management, tmux, terminal splitting, and shell integration;
- password, OTP, passphrase, or private-key storage;
- custom SSH protocol, libssh/libssh2, SwiftNIO SSH, remote daemon, or remote agent;
- SFTP/terminal authentication coordination and connection reuse;
- unrelated Phase 1 terminal compatibility gaps.

## Completion gate

Phase 2 is complete after focused RED/GREEN evidence, the full verifier,
warnings-as-errors builds, coverage, security/code review, documentation/status
updates, and an honest manual-check report are recorded in Audit 0003. Real relay
verification may remain explicitly blocked or not performed; it must never be
inferred from deterministic local tests.

That gate is satisfied. Audit 0003 records 126 passing tests in 22 suites, fresh
debug/release warnings-as-errors builds, an 82.80% scoped line gate, staged UI
inspection, a bounded real-relay login/`stty`/close exercise, and the exact manual
items that remain unperformed.

The recommended follow-up is Phase 3 Session Manager unless the finalized roadmap
explicitly keeps remote files ahead of session management.
