# Task 2 Report: Stable Active-Tab Reveal Request

## Status

Complete. Task 2 adds only the immutable reveal request and its focused Swift
Testing coverage. No SwiftUI view, `RootView`, workspace/session state, SSH code,
or project documentation changed.

## Requirements and scope

- Primary requirements: `TAB-001`, `TAB-002`, and `TAB-003`.
- Modified:
  - `Sources/XMtermApp/TerminalTabStripLayout.swift`
  - `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`
- Report created at `.superpowers/sdd/task-2-report.md`.

`TerminalTabRevealRequest` is an internal immutable `Equatable`, `Hashable`, and
`Sendable` value. It stores the current ordered tab IDs, selected ID, and viewport
width. Its optional target is the selected ID only when that ID remains in the
current ordered IDs. Selection ownership remains unchanged in
`TerminalTabsState`.

The synthesized equality/hash identity includes all three stored inputs. A
viewport-width change therefore creates a distinct request and permits the view
integration in Task 3 to reveal the active tab again after resize.

## TDD evidence

### Valid RED

The reveal-target and request-identity tests were added before production code.
They were then run with the repository-documented Command Line Tools Swift Testing
framework/runtime flags:

```bash
swift test --filter TerminalTabStripLayoutTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Result before production implementation: exit 1 with the expected missing-feature
diagnostic at every new construction site:

```text
error: cannot find 'TerminalTabRevealRequest' in scope
```

The compiler also emitted downstream generic-inference diagnostics for the `Set`
assertion because its element type did not yet exist. The root failure was the
intended absent request type, not a test-harness or unrelated build failure.

### Focused GREEN

After adding the minimal immutable request, the identical flagged command exited
0:

```text
Suite "Terminal tab strip layout" passed
Test run with 13 tests in 1 suite passed
```

The 13 passing tests comprise all 10 Task 1 sizing regressions plus three Task 2
tests covering:

- appended creation targeting the newly selected tab;
- contained selection/replacement selection and rejection of a stale selected ID;
- stable equality/hash identity for equal inputs and distinct identity after a
  viewport-width change.

### Immutable tab-state regression GREEN

```bash
swift test --filter TerminalTabsStateTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Result: exit 0; **5 tests in 1 suite passed**. Creation still appends and selects
the injected ID; closing selected first/last/final tabs still preserves or chooses
the same replacement selection as before.

## Full verification

```bash
./scripts/verify.sh
```

Fresh final result: exit 0; **139 tests in 23 suites passed** and the verifier
reported `XMterm verification: OK`.

## Self-review and scope check

- The implementation is the exact minimal pure request from the approved brief:
  three immutable stored values plus a contained-selection projection.
- The target lookup is O(n) in the ordered tab count, occurs only when reveal work
  is requested, and introduces no I/O, process, SSH, persistence, or security
  surface.
- Synthesized `Equatable`/`Hashable`/`Sendable` conformance is appropriate for the
  immutable stored value types and avoids custom identity drift.
- Task 1 policy code and all ten existing layout tests remain unchanged in
  behavior and pass in the focused suite.
- A source/test modification-time scope check found only the two Task 2 files
  under `Sources` and `Tests`; no generated artifact was added there.
- The parent workspace is untracked, so no stage, commit, or branch operation was
  performed.

## Read-only code review

An independent read-only review compared the implementation and tests with the
Task 2 brief, approved design, Task 1 policy, and immutable tab-state ownership.
Verdict: **Ready**, with no Critical or Important issues. The reviewer confirmed
that the API, containment guard, synthesized identity, immutability, `Sendable`
conformance, scope, and preservation of Task 1/state behavior are correct.

Two optional non-blocking test-hardening ideas were noted: assert nil selection
directly, and explicitly assert identity changes for selection/tab-order changes in
addition to the brief-required width change. The production behavior already
follows from the tested containment guard and synthesized identity over all stored
properties; these suggestions do not identify a Task 2 requirement failure.

## Concerns and explicit boundaries

- On this Command Line Tools-only host, focused Swift Testing commands require the
  documented framework/runtime flags above. `./scripts/verify.sh` supplies them
  automatically; this pre-existing harness condition was not changed.
- This task defines the stable request only. SwiftUI `ScrollViewReader` wiring,
  cancellation/supersession, animation, and resize handling remain intentionally
  deferred to Task 3.
