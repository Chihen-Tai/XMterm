# Task 1 Report: Pure Tab-Strip Sizing Policy

## Status

Complete. Task 1 is limited to the immutable sizing policy and its focused Swift
Testing suite. No SwiftUI view, workspace/session state, toolbar action, Session
Manager, SFTP, Settings, or terminal-process code changed.

## Requirements and scope

- Primary requirements: `TAB-002` and `A11Y-003`.
- Supporting numeric boundaries: `TAB-001` for the pinned new-terminal control and
  `MAC-001` for the independent toolbar boundary.
- Created:
  - `Sources/XMtermApp/TerminalTabStripLayout.swift`
  - `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`
- Report created at `.superpowers/sdd/task-1-report.md`.

The policy is an O(1), side-effect-free calculation over immutable values. It has
no process, SSH, input, persistence, dependency, or security impact.

## Implemented behavior

- Exact constants: 120-point minimum, 180-point preferred, 240-point maximum,
  4-point inter-tab spacing, 8-point leading padding, 4-point conditional gap,
  28-point new-terminal control, and 8-point toolbar separation.
- Preferred-width content remains content-sized and does not greedily consume the
  header.
- Tabs shrink equally until the exact 120-point threshold, then remain at 120
  points while the viewport becomes horizontally scrollable.
- Inter-tab spacing is included in preferred/minimum content widths.
- The new-terminal control is placed after the viewport and outside tab content;
  zero tabs omit its gap.
- A finite, nonnegative toolbar reservation is removed from the viewport budget;
  the toolbar boundary is exactly `stripWidth + toolbarSeparation` whenever the
  proposal can contain that geometry.
- Negative and nonfinite widths/reservations are sanitized, and negative tab counts
  are treated as zero.

Representative exact geometry is covered:

- 3 tabs at 1,000 points: content/viewport 548, new-terminal minX 560, strip end
  588, toolbar minX 596.
- 3 tabs at 500 points: equal tab width 148.
- 3-tab thresholds: 596 is the exact preferred fit; 416 is the exact minimum fit;
  415 overflows with 120-point tabs.
- 8 tabs at 900 points with 120 reserved: strip plus separation ends at 780.
- Zero tabs: new-terminal minX 8 and strip end 36.

## TDD evidence

### Literal focused command and Command Line Tools harness

Command required by the brief:

```bash
swift test --filter TerminalTabStripLayoutTests
```

Result before production code: exit 1, but the first failure was the repository's
documented Command Line Tools limitation, `no such module 'Testing'`, in an
existing test target. Because that did not exercise the new test, it was not
accepted as the feature RED.

### Valid RED

The focused filter was rerun with the repository-documented Testing framework and
runtime flags:

```bash
swift test --filter TerminalTabStripLayoutTests \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Result: exit 1 with the expected feature failure:

```text
cannot find 'TerminalTabStripLayoutPolicy' in scope
```

No production policy existed at that point.

### Initial GREEN

After the minimal immutable policy was added, the same flagged focused command
exited 0:

```text
Test run with 3 tests in 1 suite passed
```

### Edge coverage and final GREEN

The suite was extended for pinned-control coordinates, toolbar reservation, zero
tabs, invalid/nonfinite inputs, exact thresholds, and sub-minimum header proposals.
One intermediate compile run exposed invalid test-only key-path syntax in an
`allSatisfy` expectation; changing it to an explicit closure corrected the test
harness without changing production behavior.

Fresh final focused result after self-review/refactoring:

```text
Test run with 10 tests in 1 suite passed after 0.001 seconds.
```

## Full verification

```bash
./scripts/verify.sh
```

Fresh final result: exit 0; **136 tests in 23 suites passed** and the verifier
reported `XMterm verification: OK`.

```bash
swift build --scratch-path /tmp/xmterm-tab-layout-task1-debug \
  -Xswiftc -warnings-as-errors
```

Fresh final result: exit 0; debug build completed with no warnings.

## Self-review

- Inspected both created files directly because the XMterm-starter directory is
  untracked in its parent repository; no partial parent-repository diff, stage, or
  commit was created.
- Confirmed the values are internal, immutable, `Equatable`, and `Sendable`.
- Split sizing selection into a small private pure helper; no duplicated geometry
  branch or mutation remains.
- Confirmed all returned widths are finite and nonnegative for tested invalid
  inputs, and exact threshold comparisons use inclusive fit checks to avoid
  oscillation.
- Confirmed no generated build artifacts were written under `Sources` or `Tests`.
- No critical/high correctness, security, performance, or scope issue found.

## Concerns and explicit boundaries

- On this Command Line Tools-only host, the literal unflagged `swift test` command
  cannot import Swift Testing. Use `./scripts/verify.sh` or the documented framework
  flags above. This pre-existing harness condition was not changed in Task 1.
- A proposal narrower than 36 points cannot physically contain the exact 8-point
  leading padding plus fixed 28-point new-terminal control. The policy therefore
  keeps the viewport at zero and preserves the fixed control geometry; the strip
  may exceed such an impossible proposal. From 36 through 43 points the control
  fits but the complete 8-point toolbar separation does not, so
  `toolbarRegionMinX` is clamped to available width. At 44 points the complete
  zero-tab strip and separation fit exactly.
- Active-tab reveal and SwiftUI header/scroll integration are Tasks 2 and 3 and are
  intentionally absent here.
