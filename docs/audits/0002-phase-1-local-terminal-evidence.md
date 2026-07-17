# Audit 0002: Phase 1 Native Local Terminal Evidence

- **Date:** 2026-07-15
- **Scope:** Native local-terminal vertical slice only
- **Host:** Apple M4 (arm64), macOS 26.5.2 build 25F84, 24 GiB memory
- **Toolchain:** Apple Swift 6.3.3, Command Line Tools only
- **Terminal engine:** SwiftTerm 1.14.0, exact revision
  `849e8a4f3d6f79ddee07152400137f1370c32621`, MIT
- **Result:** Phase 1 implemented; compatibility exceptions below remain explicit

## Post-Phase 1 close-policy addendum

Execution Plan 0004 supersedes the original blanket running-shell confirmation for
local tabs. XMterm now records the shell PID/process group and compares it with
`tcgetpgrp(masterFD)` at close time. Automated real-PTY and workspace tests cover an
idle prompt, a foreground `sleep`, interrupt/completion returning to idle, a
background job, exited/failed/closed state, live query failure, multiple tabs, and
stale async results. A live unexpected query failure prompts conservatively; an
already-closed/reaped PTY closes immediately. Remote SSH detection is unchanged and
out of scope. The staged GUI confirms immediate close at a fresh prompt,
foreground confirmation for `sleep 100`, Cancel preserving the job, and immediate
close after `Control-C` returns zsh to its prompt. The remaining application matrix
is tracked explicitly in the terminal acceptance checklist.

## Repository condition and pre-change plan

The starter was a small SwiftPM macOS skeleton embedded as an untracked directory
inside an unrelated parent repository. It did not contain a terminal engine, PTY,
process lifecycle, local-terminal tab runtime, or app-bundle staging workflow. The
source and build configuration were inspected after reading the engineering
contract, every required top-level document, and every file under `docs/`.

Execution Plan 0003 was written before implementation. It selected one native
terminal engine, isolated SwiftUI/AppKit, session, and PTY ownership, enumerated the
files and tests, and cited the relevant `INTERACTIONS.md` IDs. No SSH, SFTP, remote
file, editor-sync, tunnel, tmux, or settings implementation was added.

## Implementation and architecture

The implemented boundary is:

```text
TerminalWorkspaceStore (MainActor, stable tab IDs)
  -> TerminalSession (lifecycle and stale-output isolation)
    -> XMtermTerminalView (retained AppKit/SwiftTerm adapter)
    -> PTYProcessController actor (bounded descriptor/process owner)
      -> CXMtermPTY (forkpty, execve, ioctl, process-group signals)
        -> user's interactive login shell
```

- SwiftTerm owns xterm parsing, grid/rendering, Unicode cells, alternate screen,
  keyboard protocols, mouse protocols, selection, search, and scrollback.
- XMterm does not use SwiftTerm's process wrapper. It launches an executable path
  with structured argv/environment through `forkpty` and `execve`; no shell command
  construction or `/bin/bash -c` is involved.
- Shell resolution tries the user account shell, then `SHELL`, then `/bin/zsh`, and
  validates absolute executable paths. The shell receives a login `argv[0]`.
- PTY reads, writes, resize, close escalation, and reaping are asynchronous and do
  not block the main actor. Output and writes are bounded; resize is coalesced.
- Each tab retains one session and one terminal view. Switching tabs does not
  recreate the screen or route old asynchronous output into a new tab.
- `Command` shortcuts stay local; `Control` scalars and engine-generated special-key
  bytes reach the PTY. Only exact supported Command modifier sets are consumed.
- A bounded streaming security filter drops terminal-originated control strings and
  host-affecting actions before SwiftTerm parses them.
- Local terminal close, window close, and app quit query foreground process-group
  ownership before choosing immediate close or a per-terminal/aggregate prompt.
  Exited tabs close immediately and retain output.

## Requirement status

| Requirement surface | Status | Evidence or exception |
|---|---|---|
| `APP-002`, `APP-003` | Implemented | Focus-routed copy/paste, visible tab/focus state, AppKit tests and manual checks |
| `APP-004` | Partial | Terminal menu has Copy, Paste, Select All, Clear Selection, Find, Jump to Latest, Close; visible-screen copy, clear scrollback, cwd, URL, and reconnect are deferred |
| `TERM-SEL-001`, `TERM-SEL-002` | Implemented with one manual gap | Drag, historical drag, word, line, Escape-clear, visible selection; edge auto-scroll and Shift-click were not conclusively exercised |
| `TERM-SEL-003` | Partial | Adapter preserves local selection and supports Option-forced selection; reported-mouse application matrix and Help discoverability remain |
| `TERM-SEL-004` | Partial | Soft-wrap, hard-break, padding, and Unicode copy have evidence; block selection and drag export are deferred |
| `TERM-CLIP-001`, `TERM-CLIP-002` | Implemented | Selection-aware copy, Unicode paste, bracketed paste, paste safety, zero-byte cancel |
| `TERM-CLIP-003` | Partial | Implemented subset listed above |
| `TERM-SCROLL-001` | Implemented | Bounded scrollback, follow suspension, new-output indicator, jump to latest |
| `TERM-FIND-001` | Partial | Find/next/previous/case/word/regex work; result count is absent |
| `TERM-KEY-001`–`TERM-KEY-003`, `TERM-PROC-001` | Implemented | Exact shortcut/control tests plus manual interrupt, suspend, quoted insert, and word erase |
| `TERM-KEY-004` | Partial | SwiftTerm handles special modes and committed Unicode; Meta is fixed to Escape-prefix and live IME preedit timing is not conclusively verified |
| `TERM-RENDER-001`, `TERM-RENDER-002` | Partial | Real PTY, SwiftTerm profile, UTF-8 chunking, Unicode fixtures, alternate screen; no full xterm/color/style compatibility claim |
| `TERM-RESIZE-001` | Implemented | Grid calculation, coalescing, `TIOCSWINSZ`, manual `stty size`, full-screen redraw |
| `TERM-STATE-001` | Partial | Local exit/status/signal, retained scrollback/selection, input disabled; SSH disconnect/reconnect is out of scope |
| `TERM-SEC-001` | Implemented for Phase 1 policy | OSC 52 reads/writes and all OSC/DCS/APC/PM/SOS effects are dropped and bounded |
| `TAB-001`, `TAB-005` | Implemented | Startup tab, plus, `Command-T`, stable identity, running/exited/failed status |
| `TAB-002`, `TAB-003` | Phase 1 subset implemented | Click selection, independent state, close button/`Command-W`; reorder and number shortcuts are deferred |
| `TAB-004` | Deferred | Duplicate, reconnect, rename, and tab context menu are not Phase 1 |
| `A11Y-001`–`A11Y-003` | Partial | Keyboard commands, labels, target sizes, scrolling, and focus are present; complete VoiceOver terminal-grid access is incomplete upstream |
| `MAC-001`, `MAC-002` | Implemented for local terminals | Runtime menus and focus-independent exact shortcuts; distinct terminal/window/quit prompts |

The detailed checklist is
[`../checklists/terminal-acceptance.md`](../checklists/terminal-acceptance.md).

## Automated verification

Final repository baseline after the local close-policy change:

```bash
./scripts/verify.sh
```

Result: exit 0; **97 tests in 16 suites passed in 7.202 seconds** and the repository
verifier reported `XMterm verification: OK`.

The script supplies Command Line Tools Swift Testing framework and runtime paths.
The equivalent direct test command is:

```bash
swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Clean warnings-as-errors builds:

```bash
swift build --scratch-path /tmp/xmterm-close-debug-final2 -Xswiftc -warnings-as-errors
swift build -c release --scratch-path /tmp/xmterm-close-release-final2 -Xswiftc -warnings-as-errors
```

Result: both exited 0 with no warnings: clean debug completed in 44.69 seconds and
clean release completed in 63.29 seconds.

Coverage command:

```bash
swift test --enable-code-coverage \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Coverage reports were generated with:

```bash
xcrun llvm-cov report \
  .build/arm64-apple-macosx/debug/XMtermPackageTests.xctest/Contents/MacOS/XMtermPackageTests \
  -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
  Sources/XMtermCore Sources/XMtermTerminal/PTY Sources/XMtermTerminal/Session \
  Sources/XMtermTerminal/Engine/TerminalOutputSecurityFilter.swift \
  Sources/XMtermTerminal/Engine/TerminalMetadataSanitizer.swift \
  Sources/XMtermTerminal/Engine/XMtermTerminalView+Input.swift \
  Sources/XMtermTerminal/Engine/XMtermTerminalView+Mouse.swift

xcrun llvm-cov report \
  .build/arm64-apple-macosx/debug/XMtermPackageTests.xctest/Contents/MacOS/XMtermPackageTests \
  -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
  Sources
```

Result: exit 0; 97 tests in 16 suites passed in 7.907 seconds. The Phase 1 logic
gate—`XMtermCore`, PTY, session, output-security filter, metadata sanitizer, and
input/mouse routing—covers **84.30% of lines** (2,100/2,491) and 86.16% of
functions.

For transparency, all first-party source including declarative SwiftUI/AppKit view
delivery covers **63.04% of lines** (2,756/4,372). That unfiltered number is not
represented as 80%: full XCUITest was unavailable, and brittle tests that merely
evaluate SwiftUI body builders were not added to inflate it. Interactive behavior
instead has focused adapter tests plus the manual evidence below.

App-bundle staging and launch:

```bash
./script/build_and_run.sh --verify
codesign --verify --deep --strict --verbose=4 dist/XMterm.app
```

Result: exit 0; the arm64 bundle launched from its staged executable, strict deep
signature verification reported “valid on disk” and “satisfies its Designated
Requirement,” and one login zsh was its direct child. The bundle contains the
SwiftTerm resource bundle and MIT license. It is ad-hoc signed for development, not
Developer ID signed, hardened/notarized, or distribution-approved.

The final close-policy staging run completed the incremental app build in 5.56
seconds. Process inspection found the app and exactly one direct login-zsh child;
after terminating the verification instance, both PIDs were gone and no XMterm
process remained.

Focused regression suites additionally cover:

- tab creation, selection, neighboring closure, stable identity, and independent
  session/view objects;
- shell configuration fallback and launch validation;
- lifecycle state transitions and normal/nonzero/signal exit reconciliation;
- exact Control bytes and rejection of modified/deferred Command chords;
- grid-size calculation and latest-value resize coalescing;
- bounded 10,000-line engine configuration and disabled image cache;
- PTY output draining, close escalation, wait status, descriptor cleanup, and
  descendants retaining the PTY slave;
- shell PID/process-group capture, foreground ownership, idle return after command
  completion or interruption, pipelines, background jobs, exact tail draining,
  race-safe close signaling, and event-driven residual child reaping;
- per-tab and aggregate close disposition, query-failure fallback, stable session
  revalidation, independent tabs, and overlapping shutdown requests;
- terminal-output filtering across arbitrary chunk boundaries;
- soft-wrapped copy semantics and selection preservation in exited terminals.

## Manual GUI evidence

The staged application was launched as a native macOS app and checked through its
accessibility surface and terminal UI.

- A real login zsh appeared, accepted commands, and streamed output.
- `stty size` changed from `47 143` to `36 99` after a continuous window resize.
- `less` entered alternate screen, paged, quit, and restored the shell screen.
- `vim -u NONE -N` accepted insert/edit/navigation input, resized, quit, and restored
  the shell. `nano`, `top`, and `htop` were not all exercised.
- ASCII, pasted/committed Traditional Chinese, a combining-mark fixture, wide CJK,
  and emoji rendered. Live Traditional Chinese IME preedit timing remained
  inconclusive because the automation environment could not reliably hold the
  system input source and inspect marked text.
- `Control-C`, `Control-Z`, `Control-V`, and `Control-W` had their distinct shell
  effects. Exact `Control-D`, `Control-F`, and other bytes are covered by tests;
  destructive GUI automation of `Control-D` was inconclusive and is not claimed as
  a manual pass.
- `Command-V` pasted without duplication. A suspicious multiline paste displayed a
  confirmation describing line and byte counts; Cancel sent zero bytes.
- Double-click copied the exact selected word; triple-click copied a line without
  visual padding. A multirow drag preserved a hard newline. Selection across rows
  also worked while historical scrollback was visible. Soft-wrap correctness has a
  deterministic adapter test; Shift-click and long edge auto-scroll remain manual
  gaps.
- While scrolled upward, delayed output did not move the viewport. A visible New
  Output affordance appeared and returned to the latest output when activated.
- `Command-F` opened the native search bar; next/previous and search options worked
  on historical output. Result count is not implemented.
- `+` and `Command-T` produced independent shells. Switching preserved process,
  screen, and scroll state. `exit 7` produced an `Exited with status 7` tab retaining
  10,000 lines, and a new tab could be opened afterward.
- With two live tabs after an exited third process, process inspection showed two
  direct login shells and two PTY masters, with no extra direct child or zombie.
- During the original Phase 1 validation, every running tab showed a per-terminal
  confirmation and window/quit used aggregate confirmation. That observation is
  historical and is superseded for local PTYs by the addendum and updated GUI
  evidence above.

## Performance observations

The exact required stress command was run:

```bash
yes "XMterm output test" | head -n 100000
```

The prompt returned within a five-second observation window and the app remained
responsive. One idle terminal sampled at 0% CPU and approximately 122.2 MiB resident
memory. After the stress fixture with two tabs, resident memory was approximately
161.5 MiB and three CPU samples were 0.2%, 0%, and 0%. Idle reads use descriptor
readiness, not polling; output is chunked into the engine rather than copied into
per-character SwiftUI state.

These are debug observations. Cold-start latency, p95 input latency, five-tab release
memory, Instruments stalls, and the ten-minute output gate remain unmeasured.

## Security and review

- No hard-coded credential, private-key, developer-machine path, or terminal-content
  logging was found in the scoped scan. Test fixtures use `/Users/example` only.
- PTY launch and future process boundaries accept structured paths/arguments and
  reject NUL/relative executable and working-directory inputs.
- Terminal output cannot open a URL, update a title, ring a bell, write/read the
  pasteboard, invoke graphics, or reach known terminal-content log paths in Phase 1.
- Multiline/control-bearing paste is confirmed; oversized, bidi-spoofed, or injected
  bracket terminators are rejected.
- A final security review reported no P0–P2 finding. Two bounded code reviews found
  lifecycle and modifier/mouse edge cases; focused RED/GREEN tests and fixes were
  added before this audit's final verification run.

## Known limitations

- This is not yet an SSH terminal. SSH, SFTP, remote files, editor sync, tunnels,
  tmux, reconnect, duplicate/reopen, and settings are out of scope.
- Full xterm compatibility is not claimed. The complete color/style/cursor/mouse
  matrix, `nano`/`top`/`htop`, nested terminals, and long soak remain unverified.
- Dynamic titles, hyperlinks, bells, terminal graphics, and OSC clipboard writes
  are deliberately blocked pending explicit safe product behavior.
- Search has no result count; clear scrollback/reset, rectangular selection,
  selected-text drag export, and Shift-click evidence remain follow-up work.
- Option is fixed to Escape-prefixed Meta; configurable Option/Backspace/word rules
  require the deferred settings phase.
- Live IME preedit timing and comprehensive VoiceOver access are not conclusively
  verified. SwiftTerm upstream does not expose the complete terminal buffer, cursor,
  and selection as a full native accessibility model.
- The host has Command Line Tools but no full Xcode, so XCUITest was unavailable.
  The development app is ad-hoc signed only; Developer ID, hardened runtime,
  notarization, sandboxing, and release distribution remain open under ADR 0004.

## Task file inventory

Created for the vertical slice:

- `Package.resolved`
- `Sources/CXMtermPTY/CXMtermPTY.c`
- `Sources/CXMtermPTY/include/CXMtermPTY.h`
- `Sources/XMtermApp/ApplicationShortcutCoordinator.swift`
- `Sources/XMtermApp/TerminalPane.swift`
- `Sources/XMtermApp/TerminalTabStrip.swift`
- `Sources/XMtermApp/TerminalWorkspaceCommands.swift`
- `Sources/XMtermApp/WindowLifecycleBridge.swift`
- `Sources/XMtermApp/XMtermApplicationDelegate.swift`
- `Sources/XMtermCore/Terminal/TerminalConfiguration.swift`
- `Sources/XMtermCore/Terminal/TerminalGridSize.swift`
- `Sources/XMtermCore/Terminal/TerminalInputRouter.swift`
- `Sources/XMtermCore/Terminal/TerminalLifecycle.swift`
- `Sources/XMtermCore/Terminal/TerminalPastePolicy.swift`
- `Sources/XMtermCore/Terminal/TerminalShellResolver.swift`
- `Sources/XMtermCore/Terminal/TerminalTabsState.swift`
- `Sources/XMtermCore/Terminal/TerminalTitlePolicy.swift`
- `Sources/XMtermTerminal/Engine/RetainedTerminalView.swift`
- `Sources/XMtermTerminal/Engine/TerminalMetadataSanitizer.swift`
- `Sources/XMtermTerminal/Engine/TerminalOutputSecurityFilter.swift`
- `Sources/XMtermTerminal/Engine/XMtermTerminalView+Input.swift`
- `Sources/XMtermTerminal/Engine/XMtermTerminalView+Mouse.swift`
- `Sources/XMtermTerminal/Engine/XMtermTerminalView.swift`
- `Sources/XMtermTerminal/Engine/XMtermTerminalViewDelegateBridge.swift`
- `Sources/XMtermTerminal/PTY/PTYLaunchConfiguration.swift`
- `Sources/XMtermTerminal/PTY/PTYProcessController.swift`
- `Sources/XMtermTerminal/PTY/PTYSpawn.swift`
- `Sources/XMtermTerminal/Session/TerminalSession.swift`
- `Sources/XMtermTerminal/Session/TerminalSessionModels.swift`
- `Sources/XMtermTerminal/XMtermTerminal.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- `Tests/XMtermAppTests/XMtermApplicationDelegateTests.swift`
- `Tests/XMtermTerminalTests/PTYProcessControllerTests.swift`
- `Tests/XMtermTerminalTests/SwiftTermAdapterTests.swift`
- `Tests/XMtermTerminalTests/TerminalSessionIOFailureTests.swift`
- `Tests/XMtermTerminalTests/TerminalOutputSecurityFilterTests.swift`
- `script/build_and_run.sh`
- `docs/exec-plans/0003-native-local-terminal-vertical-slice.md`
- `docs/audits/0002-phase-1-local-terminal-evidence.md`

Modified from the starter or planning baseline:

- `.codex/environments/environment.toml`
- `.gitignore`
- `.vscode/launch.json`
- `Package.swift`
- `README.md`
- `ARCHITECTURE.md`
- `PERFORMANCE.md`
- `PLANS.md`
- `SECURITY.md`
- `TESTING.md`
- `Sources/XMtermApp/RootView.swift`
- `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- `Sources/XMtermApp/XMtermApp.swift`
- `Sources/XMtermCore/Models/SessionProfile.swift`
- `Sources/XMtermCore/Models/TerminalTab.swift`
- `Tests/XMtermCoreTests/SessionProfileTests.swift`
- `Tests/XMtermCoreTests/TerminalDomainTests.swift`
- `docs/checklists/terminal-acceptance.md`
- `docs/checklists/interaction-parity.md`
- `docs/decisions/0003-terminal-engine-selection.md`
- `docs/decisions/0004-macos-sandbox-and-distribution.md`
- `docs/design-docs/v0.1-mvp.md`
- `docs/exec-plans/0002-terminal-foundation.md`
- `scripts/verify.sh`

Generated `.build/`, `.swiftpm/`, `dist/`, and host metadata are ignored and are not
part of the source inventory.

## Recommended next task

Implement SSH terminal integration by executing `/usr/bin/ssh` directly through
the existing `PTYProcessController` and terminal/session/tab infrastructure. Resolve
effective configuration through system OpenSSH and `ssh -G`, preserve native host-
key/authentication prompts and the Phase 1 interaction/security boundaries, and use
a disposable local fixture. Do not combine that task with SFTP or remote files.
