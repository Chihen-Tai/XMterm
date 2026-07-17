# Audit 0003: Phase 2 Fixed-Relay SSH Terminal Evidence

- **Date:** 2026-07-16
- **Host:** macOS 26.5.2 (25F84), Apple silicon arm64, Command Line Tools
- **Swift:** Apple Swift 6.3.3
- **Terminal engine:** SwiftTerm 1.14.0
- **Scope:** one fixed OpenSSH terminal target through the Phase 1 PTY

## Outcome

Phase 2 adds stable `Relay Host` tabs beside local terminals. Production directly
executes:

```text
/usr/bin/ssh
argv: ["/usr/bin/ssh", "-p", "54426", "allen921103@140.109.226.155"]
```

No shell wrapper or command string exists. The relay reuses the production
`TerminalSession` → `TerminalProcess` → `PTYProcessController` → `forkpty/execve`
path and the retained SwiftTerm view. System OpenSSH owns configuration,
`ssh-agent`, Keychain integration, `known_hosts`, host-key warnings, and all
authentication prompts in the terminal.

The app reports only local process truth: idle, starting, process running, closing,
exact exit/signal, or failure. `SSH session active` does not mean connected or
authenticated. Raw output is not parsed for prompts or shell markers.

## TDD evidence

The pre-change baseline passed 97 tests in 16 suites. The implementation then
recorded failing compile/test runs before each production slice:

1. domain RED for missing idle/kind/SSH state, followed by 102 passing tests;
2. session RED for missing `TerminalProcess`, target-aware launch, and SSH close
   disposition, followed by 107 passing tests;
3. workspace RED for missing relay creation/factory kind and aggregate count,
   followed by 112 passing tests;
4. presentation RED for missing honest state/exact close-copy policy, followed by
   117 passing tests;
5. normal/signal SSH-exit and creation-availability additions, followed by the
   initial 118 passing test cases in 21 suites;
6. review-driven RED coverage for an already-exited child, delayed-launch close,
   injected read/write/resize failures, local/SSH close isolation, SSH-only
   aggregate shutdown, and non-injected close input;
7. staged-UI RED evidence for unavailable File commands, followed by a weakly
   rebound window command router and alert-safe menu/shortcut availability tests.

The closing result is 126 passing tests in 22 suites. The final verifier,
warnings-as-errors builds, coverage, staged-app smoke, real relay subset, and
review results are recorded below.

## Requirement status

| Requirement/scope | Status | Evidence and boundary |
|---|---|---|
| `TERM-KEY-001`–`TERM-KEY-003`, `TERM-PROC-001` | Implemented for Phase 2 | Shared input tests, Phase 1 byte/shortcut suites, direct close cleanup; no injected `exit`/Control byte |
| `TERM-CLIP-001`, `TERM-CLIP-002`, `TERM-SCROLL-001`, `TERM-FIND-001`, `TERM-RESIZE-001`, `TERM-SEC-001` | Implemented for the existing advertised subset | SSH reuses the retained terminal view, paste policy, bounded scrollback/find/resize, and unchanged output filter |
| `TERM-STATE-001` | Partially implemented | Exit/signal/failure preserve final output and disable input; reconnect and richer disconnect/network state are deferred |
| `TAB-001` | Partially implemented | Plus/File actions open local or fixed relay; Session Manager-selected profiles and double-click session creation are deferred |
| `TAB-002` | Partially implemented | Click selection, horizontal strip, stable retained state are implemented; reorder and keyboard tab navigation remain deferred |
| `TAB-003` fixed-relay close/isolation | Implemented | Every live SSH process confirms; Cancel/Close and exited/failed immediate close are tested; middle-click remains outside this slice |
| `TAB-004` | Deferred | Rename, duplicate, reconnect, Close Others/Right, and copy connection description are not added |
| `TAB-005` process status | Implemented for Phase 2 | Non-color icon plus neutral text/help/accessibility; no Connected claim or prompt parsing |
| `SESS-001` | Deferred | No Session Manager, alias discovery, favorites, or persistence |
| `SESS-002` | Partially implemented | Fixed `Connect to Relay Host` action only; file browser/profile actions are deferred |
| `SESS-003` | Partially implemented | Raw trusted OpenSSH prompt path is preserved and no credential field/storage exists; a real login completed without a prompt, while host-key/password/OTP/passphrase flows were not encountered |
| `SESS-004` | Partially implemented | Direct system OpenSSH and structured argv are implemented; alias discovery and `ssh -G` presentation are deferred |
| `SESS-005` | Deferred | Sleep/wake, network monitoring, cancellation state, and reconnect are not added |
| `SESS-006` | Not applicable | SFTP does not exist in Phase 2 |
| `MAC-001` applicable terminal actions | Implemented | Plus/File commands share store actions and creation availability; Command-T remains local |
| `MAC-002` terminal subset | Implemented | Live SSH sessions aggregate separately; exited/failed/local-idle semantics remain honest; transfers/editor mappings do not exist |
| SFTP, remote browser, editor sync, ProxyJump UI, automatic second hop, internal-node tabs, tunnels, tmux | Deferred | Explicitly excluded from Phase 2 |
| Blocking ambiguity | None | Deterministic implementation and a bounded real login/close smoke are complete; unencountered credential and application flows remain explicit evidence gaps, not code blockers |

## Automated verification

Current debug verifier result:

```text
./scripts/verify.sh
Test run with 126 tests in 22 suites passed
XMterm verification: OK
```

Fresh warnings-as-errors builds both exited 0 with no warnings:

```text
swift build --scratch-path /tmp/xmterm-phase2-debug-final3 -Xswiftc -warnings-as-errors
Build complete! (49.10s)

swift build -c release --scratch-path /tmp/xmterm-phase2-release-final3 -Xswiftc -warnings-as-errors
Build complete! (72.37s)
```

The coverage run passed all 126 tests in 22 suites. The scoped logic gate—Core,
PTY/session, selected engine security/input/mouse boundaries, workspace store,
presentation policy, and command router—covers **82.80% of lines** (2,860/3,454)
and **84.13% of functions**. All first-party `Sources`, including declarative
SwiftUI/AppKit delivery that cannot be meaningfully invoked by unit tests, covers
**64.79% of lines** (3,143/4,851) and **66.72% of functions**; that unfiltered
number is reported transparently rather than represented as 80%.

Automated tests never connect to the real relay. Controlled actors capture the
production launch configuration and drive ordered output, EOF, immediate/delayed
exit, input, resize, launch and I/O failure, close, and command routing. Existing
real-PTY tests exercise descriptor closure, final drain, signal escalation,
direct-child reaping, independent processes, and no-zombie behavior.

## Security observations

- The only non-fixture endpoint committed is the explicitly declared public Phase
  2 relay. No internal-node address, credential, OTP, passphrase, or private key is
  present.
- Launch tests reject wrappers, command strings, remote commands, password-like
  options, `BatchMode`, host-key bypass, and known-hosts bypass.
- The real inherited environment enables normal agent/config behavior but is not
  logged. Terminal input, output, prompt contents, and clipboard contents are not
  logged or persisted.
- The Phase 1 bounded untrusted-output filter remains unchanged for SSH, including
  denied OSC 52 and other host-affecting control strings.
- No telemetry, custom SSH protocol, credential UI, storage, or remote agent was
  added.

## Performance observations

The implementation adds no polling, duplicate terminal renderer, duplicate
scrollback, synchronous network wait, or per-character SwiftUI observation.
Read/write/reap behavior remains readiness/event-driven and off the main actor;
resize and input queues remain bounded. No new relay CPU, memory, cold-launch, or
latency measurement is claimed. Phase 1 measurements remain the only resource
numbers until the checklist's real/staged relay measurement is performed.

## Staged and real-relay verification

`./script/build_and_run.sh --verify` rebuilt, staged, ad-hoc signed, and launched
the final native bundle from `dist/XMterm.app`; the final staging build completed
in 5.07 seconds.

Observed in the staged UI:

- the plus menu and enabled File menu both offered `New Local Terminal` and
  `Connect to Relay Host`;
- `Command-T` created a second local tab, and command routing remained enabled
  after window workspace recreation;
- the fixed relay action launched a `Relay Host` tab whose neutral status was
  `SSH session active`;
- existing OpenSSH state completed a real login without an interactive prompt;
  no credential was entered, and the authentication mechanism was not inferred;
- `printf 'XMTERM_PHASE2_SMOKE\\n'; stty size` returned the marker and a live
  `47 143` grid from the relay shell;
- live close rendered the exact SSH title/body with Cancel and Close; Cancel kept
  the relay active, then Close removed only the relay tab and left both local tabs
  alive;
- an escalated process-list check after Close returned no matching fixed-relay SSH
  process.

Not encountered or not performed: first-use/changed host-key, password, OTP,
keyboard-interactive, private-key passphrase, a provable `ssh-agent` versus
Keychain mechanism, a changed window size followed by `stty size`, remote
Control/Command interaction, selection/copy/paste/find against relay output,
Traditional Chinese/emoji, `vim`, `less`, manual `ssh g207`, and privacy-log
inspection. No OTP or Keychain claim is made.

See [`../checklists/ssh-terminal-acceptance.md`](../checklists/ssh-terminal-acceptance.md)
for the itemized status.

## Known limitations and follow-up

- The fixed relay is compiled into this Phase 2 slice; there is no Session Manager
  or profile editor.
- Running means only the local OpenSSH process exists. Remote idle/foreground,
  authentication, and connection success are unknowable without a reliable future
  signal and are not guessed.
- Reconnect, sleep/wake, network-loss classification, ProxyJump UI, automatic
  second hops, direct internal-node tabs, SFTP, remote files, editor sync, tunnels,
  tmux, and shell integration are absent.
- Dynamic OSC titles remain filtered, so the fixed relay title is stable.
- The exact recommended next task is **Phase 3 Session Manager**, not SFTP.
