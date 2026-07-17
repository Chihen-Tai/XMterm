# Execution Plan 0004: Local Terminal Close Confirmation

- **Status:** Complete
- **Started:** 2026-07-15
- **Completed:** 2026-07-16
- **Scope:** Foreground-job-aware close behavior for local PTY terminal tabs

## Goal

Close a local terminal immediately when its shell owns the PTY foreground process
group, and ask for confirmation when another foreground process group owns the
terminal. Exited, failed, closing, and already-unavailable PTYs close immediately;
an unexpected query failure on an otherwise-live PTY receives one conservative
confirmation.

## Acceptance requirements

- `TAB-003`: close only the requested tab; local idle shells close immediately,
  while a known active foreground job receives one concise confirmation.
- `TERM-PROC-001`: tab close remains distinct from interrupt, suspend, EOF, or
  injected shell input, and PTY cleanup still reaps the child process.
- `TERM-STATE-001`: exited and failed sessions close immediately and lifecycle
  transitions remain typed.
- `MAC-002`: close buttons, `Command-W`, window close, and application quit follow
  the same local-terminal policy.

## Pre-change condition and root cause

Phase 1 already launches each shell with `forkpty`, owns the master descriptor in
`PTYProcessController`, and exposed `tcgetpgrp` through the C shim. The workspace
checked `TerminalLifecycle.requiresCloseConfirmation`, which only said whether a
process might still need cleanup. It did not describe foreground-job activity, so
every live shell produced a confirmation.

## Design

1. Record the direct shell PID and its PTY-created process-group ID on the PTY
   controller. `forkpty` makes the child the session/process-group leader, so the
   initial shell process-group ID is the child PID.
2. Add a typed foreground state at the PTY boundary:
   - shell process group in foreground: idle/waiting shell;
   - different foreground process group: active foreground job;
   - terminal unavailable because it exited/closed: no active PTY remains;
   - query failed while the PTY is live: no reliable foreground determination.
3. Query `tcgetpgrp` on the PTY master when close is requested. Do not inspect
   output, prompt text, process existence, or elapsed time.
4. Let `TerminalSession` translate lifecycle plus PTY foreground state into a
   small close disposition. A known foreground job or an exceptional live query
   failure requires confirmation.
5. Let `TerminalWorkspaceStore` resolve that disposition asynchronously, then
   revalidate the stable tab/session identity before presenting or closing. Apply
   the same rule when aggregating window/application shutdown.
6. If the PTY is already closed or reaped, close immediately. If `tcgetpgrp`
   unexpectedly fails while the PTY is otherwise live, show one conservative,
   honestly worded confirmation. This exceptional fallback does not infer activity
   from shell liveness and does not restore the old normal-path annoyance.

## TDD sequence

1. Add failing real-PTY tests for recorded shell identity, idle-shell detection,
   foreground-job detection, return to idle after completion/interruption, and
   query-unavailable behavior after PTY closure.
2. Add failing session/workspace tests for immediate versus confirmed close,
   exited/failed behavior, independent tabs, and stale asynchronous results.
3. Implement the smallest PTY, session, and workspace changes required to pass.
4. Update aggregate shutdown tests so idle terminals close without a prompt and
   known foreground jobs produce the aggregate prompt.
5. Run focused tests, the full suite, `./scripts/verify.sh`, build/stage/sign the
   app, and perform the feasible local-shell manual checks.

## Files expected to change

- `Sources/XMtermTerminal/PTY/PTYProcessController.swift`
- `Sources/XMtermTerminal/Session/TerminalSession.swift`
- `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- `Sources/XMtermApp/RootView.swift`
- `Tests/XMtermTerminalTests/PTYProcessControllerTests.swift`
- `Tests/XMtermTerminalTests/TerminalSessionIOFailureTests.swift` or a focused
  terminal-session close test file
- `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- `INTERACTIONS.md`
- `ARCHITECTURE.md`
- `docs/design-docs/terminal-ux.md`
- `docs/design-docs/terminal-keyboard.md`
- `docs/checklists/terminal-acceptance.md`
- `docs/exec-plans/0003-native-local-terminal-vertical-slice.md`

## Risks and mitigations

- Foreground ownership may change after the query. Treat the close decision as a
  point-in-time snapshot and revalidate tab/session identity before acting.
- A shell may exit while the query is in flight. Terminal lifecycle revalidation
  makes that an immediate close.
- Async results could target a removed tab. Stable tab and session identity checks
  discard stale results.
- Window shutdown spans multiple tabs. Resolve each tab independently and count
  only known foreground jobs and live-query failures before presenting one
  aggregate prompt.
- Process-group semantics cannot distinguish work that deliberately remains in the
  shell process group, such as a long-running builtin or `exec` replacement. This
  is an explicit limitation of the requested no-prompt-parsing design.

## Deferred work

- SSH/remote foreground-process detection and shell integration.
- Settings to override confirmation policy.
- Prompt parsing or command-history heuristics (intentionally prohibited).

## Outcome

| Surface | Status | Result |
|---|---|---|
| Idle local shell | Implemented | A live shell closes immediately when `tcgetpgrp(masterFD)` matches its recorded shell process group. |
| Foreground job | Implemented | A different foreground process group produces the local close confirmation. |
| Completed job | Implemented | Completion or interruption returning foreground ownership to the shell restores immediate close. |
| Exited, failed, or unavailable terminal | Implemented | The tab closes immediately without querying process liveness. |
| Foreground query failure | Implemented | An otherwise-live terminal receives one honestly worded, conservative confirmation; a closed PTY does not. |
| Multiple tabs and aggregate shutdown | Implemented | Each stable tab/session is classified independently; idle tabs do not inflate warning counts, stale results are discarded, and overlapping shutdown requests are coalesced. |
| Child cleanup | Implemented | Close escalation targets the current foreground group through PTY semantics, verifies every observed non-shell group, then reaps the pinned direct shell PID without polling. |
| Full interactive command matrix | Partially implemented | Real-PTY automation covers `sleep`, a finite command, shell builtins, a pipeline, and a background job. The staged GUI covers a fresh prompt, `sleep 100`, Cancel, and return to the prompt after `Control-C`; `python3`, `vim`, `less`, `top`, and a foreground pipeline remain checklist items. |
| Same-process-group work | Partially implemented | PTY foreground-group semantics cannot distinguish a long-running shell builtin or an `exec` replacement that deliberately retains the shell process group. |
| SSH foreground detection | Deferred | No remote-process inference was added. |
| Blocked work | None | No blocking ambiguity remains for the local-terminal policy. |

## Actual change set

- `Sources/CXMtermPTY/include/CXMtermPTY.h`
- `Sources/CXMtermPTY/CXMtermPTY.c`
- `Sources/XMtermCore/Terminal/TerminalLifecycle.swift`
- `Sources/XMtermTerminal/PTY/PTYLaunchConfiguration.swift`
- `Sources/XMtermTerminal/PTY/PTYSpawn.swift`
- `Sources/XMtermTerminal/PTY/PTYProcessController.swift`
- `Sources/XMtermTerminal/Session/TerminalSession.swift`
- `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- `Sources/XMtermApp/RootView.swift`
- `Tests/XMtermTerminalTests/PTYProcessControllerTests.swift`
- `Tests/XMtermTerminalTests/TerminalSessionIOFailureTests.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- `README.md`, `ARCHITECTURE.md`, `INTERACTIONS.md`, `PLANS.md`, and `TESTING.md`
- Terminal design, ADR, audit, execution-plan, and acceptance-checklist documents under `docs/`
- `scripts/verify.sh`

## Verification evidence

- `PTYProcessControllerTests`: 21/21 passed, including real-PTY idle,
  foreground, completion, pipeline, background-job, exact-drain, and cleanup cases.
- `TerminalWorkspaceStoreTests`: 13/13 passed, including idle, foreground,
  query-failure, exited, failed, independent-tab, stale-result, and aggregate-close
  behavior.
- `./scripts/verify.sh`: exit 0; 97 tests in 16 suites passed; verifier reported
  `XMterm verification: OK`.
- Warnings-as-errors debug and release scratch builds both exited 0.
- Coverage run: 97 tests passed; the scoped Phase 1 logic gate covers 84.30% of
  lines (2,100/2,491), while all first-party `Sources` covers 63.04%
  (2,756/4,372).
- `./script/build_and_run.sh --verify` staged and launched the native app;
  `codesign --verify --deep --strict --verbose=4 dist/XMterm.app` passed. The
  verification app and its direct login-shell child were both reaped after
  shutdown.
- Independent final review found no P0-P2 implementation findings.
