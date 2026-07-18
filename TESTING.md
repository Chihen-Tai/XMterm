# XMterm Testing Strategy

XMterm combines terminal protocol behavior, PTY/process lifecycle, network I/O,
filesystem watching, drag/drop, and native UI. No single test layer is sufficient.

## Test layers

### Domain tests

Pure Swift tests cover:

- terminal-tab and connection state transitions;
- saved-session schema validation, immutable collection transforms, stable
  identity, launch snapshots, favorites, recency, and picker projection;
- one-time default seeding, persistence/recovery state, and failed-write
  persist-before-publish behavior;
- transfer revision ordering;
- conflict detection;
- file selection and batch action rules;
- collision policy;
- editor mapping identity;
- safe retry and cancellation behavior.

### Terminal parser/emulator tests

Use deterministic byte fixtures and expected screen-grid snapshots for:

- cursor movement and erase;
- SGR/colors;
- alternate screen;
- scroll regions;
- Unicode width and combining marks;
- OSC titles, hyperlinks, bell, and denied OSC 52;
- wrapped-line copy semantics.

If a third-party terminal engine is used, keep XMterm integration tests for the
capabilities the product advertises rather than assuming upstream coverage is
sufficient.

### PTY integration tests

Spawn a local fixture process inside a PTY to verify:

- exact Control bytes;
- key sequences;
- resize rows/columns;
- process exit and signal status;
- shell versus foreground-job process-group ownership, completion returning to the
  shell, background jobs, and foreground pipelines;
- output chunking and UTF-8 boundary handling;
- cancellation and close behavior.

Tests must not require a real private server.

### SSH/SFTP integration tests

Use a disposable local test host or isolated CI fixture with test-only keys. Cover:

- config alias resolution through OpenSSH;
- key, passphrase, password, and keyboard-interactive flows where automation is
  safe;
- host-key first-use and changed-key failure;
- ProxyJump fixture;
- list/upload/download/rename/delete;
- symlinks, permissions, Unicode paths, conflicts, cancellation, and disconnects.

Never use production hostnames, usernames, paths, keys, or OTPs in fixtures.

### Filesystem watcher tests

Simulate:

- in-place write;
- atomic save by temporary-file rename;
- rapid repeated saves;
- local delete/recreate;
- editor swap/lock files;
- newest-revision-wins ordering;
- app restart with pending mapping.

### UI tests

Critical UI tests cover:

- terminal tab create/select/reorder/close;
- saved-session picker search/grouping/keyboard policy, editor draft validation,
  manager actions, launch coordination, and error/recovery presentation policy;
- focus-routed Copy/Paste/Select All;
- file single/multiple/range selection;
- context-menu selection preservation;
- keyboard-only navigation;
- collision and close/quit sheets;
- transfer status and retry;
- accessibility labels for icon-only controls.

### Manual compatibility tests

Run `docs/checklists/terminal-acceptance.md` and
`docs/checklists/interaction-parity.md`. Phase 3 also requires
`docs/checklists/session-manager-acceptance.md` against the packaged app. Record
exact exceptions; “works on my machine” is not release evidence.

## Test doubles and architecture

Infrastructure protocols require deterministic fakes for:

- PTY process;
- SSH config resolver;
- remote file service;
- transfer staging;
- local cache;
- filesystem watcher;
- editor launcher;
- pasteboard and drag promises;
- clock and retry scheduler.

Fakes model cancellation, delay, partial failure, out-of-order completion, and
network loss. Happy-path-only fakes are insufficient.

## CI baseline

CI should eventually run:

1. formatting/lint checks;
2. domain/unit tests on every change;
3. terminal fixture tests;
4. macOS build and selected PTY/UI integration tests;
5. secret/path scanning;
6. dependency/license audit;
7. `scripts/verify.sh`.

Performance and full interactive SSH/VoiceOver tests may remain scheduled/manual but
must run before release.

## Phase 1 local-terminal verification

The local-terminal slice has deterministic Swift Testing suites for:

- immutable tab creation, selection, closure, identity, and lifecycle transitions;
- shell fallback and login arguments;
- exact Command-versus-Control byte routing and paste policy;
- PTY grid sizing and resize coalescing;
- real Darwin PTY round trips, resize, status/signal decoding, output draining,
  exact tail preservation, stubborn foreground cleanup, independent children,
  reaping, and `tcgetpgrp` foreground ownership;
- local close disposition for idle, foreground, completed, exited/failed/closed,
  query-failure, aggregate-shutdown, independent-tab, and stale-result cases;
- terminal-engine configuration, security filtering, selection/copy semantics,
  scroll-follow behavior, and application shortcut routing.

Run the repository baseline with:

```bash
./scripts/verify.sh
```

On Command Line Tools installations, that script supplies the Swift Testing
framework and runtime search paths automatically. The Phase 1 audit records the
exact clean debug/release build, coverage, app staging, signing, and manual GUI
commands. This host does not have full Xcode, so XCUITest and a release-signed GUI
test run remain blocked; focused AppKit integration tests and manual accessibility
inspection provide the current UI evidence.

The Phase 1 line-coverage gate covers the testable domain, PTY, session, output-
security, metadata, and input/mouse-routing boundary. Declarative SwiftUI layout and
AppKit event delivery remain outside that numerical gate and require XCUITest/manual
evidence. Audit 0002 reports both the gated result and the unfiltered first-party
source result so the exclusion is visible rather than mistaken for repository-wide
coverage.

## Phase 2 fixed-relay verification

Phase 2 adds deterministic suites for:

- the exact `/usr/bin/ssh` executable and ordered `-p`, `54426`, and relay-target
  arguments, with no wrapper, command string, host-key bypass, or secret option;
- immutable local/relay tab identity, selection, title, and lifecycle projection;
- actual `TerminalSession` configuration capture through a narrow
  `TerminalProcess` fake, raw final-output delivery before EOF/exit, normal,
  nonzero, and signal exits, typed launch failure, input, resize, and live-close
  policy without a foreground-process query;
- workspace coexistence, Cancel/Close isolation, immediate exited/failed close,
  aggregate SSH counting, and shutdown creation availability;
- honest presentation/accessibility copy and the exact SSH close decision.

The existing real-PTY suites remain the production evidence for descriptor
closure, direct-child reaping, no-zombie behavior, signal escalation, bounded I/O,
and final-output draining because local and SSH sessions use the identical
`PTYProcessController`. Automated tests never contact the real relay, mutate
`known_hosts`, inspect Keychain, or require credentials. Real authentication,
host-key, agent/Keychain, remote applications, and manual second-hop checks are
tracked separately in `docs/checklists/ssh-terminal-acceptance.md` and must never be
inferred from deterministic tests.

## Phase 2 tab-strip polish verification

`TerminalTabStripLayoutTests` contains 17 pure Swift tests for:

- the exact 180/120/240-point width constants, equal shrinking, and the exact
  preferred/minimum overflow thresholds;
- content-sized non-overflow geometry, minimum-width overflow state, zero/invalid
  proposals, and invalid toolbar reservations;
- the pinned `+` coordinate, strip width, and reserved toolbar boundary;
- contained/stale reveal targets, viewport width participating in reveal-request
  identity, and the pure scheduling decision: 16 ms initial/tab-state settle,
  tab-state-only animation, and 75 ms unanimated viewport debounce.

These tests prove deterministic policy and target selection. They do not instantiate
the SwiftUI hierarchy or prove that `ScrollViewReader.scrollTo` produced the
expected pixels. The stable-ID `LazyHStack`, non-scrolling `+` sibling, title
truncation, fixed close target, cancellation guards, and exactly one final
`scrollTo` per accepted scheduled request are source-reviewed implementation facts;
the staged manual pass separately verifies the core rendered layout and reveal
outcomes below.

On 2026-07-16, the final `./scripts/verify.sh` run passed **143 tests in 23
suites in 7.203 seconds**. Final clean debug and release SwiftPM builds using
isolated `/tmp` scratch paths and `-Xswiftc -warnings-as-errors` exited 0 with no
warnings in 38.56 and 58.22 seconds, respectively. The isolated
`/tmp/xmterm-tab-polish-final-coverage` run passed the same 143 tests in 23 suites
in 7.132 seconds. Its scoped Phase 1/2 logic gate plus
`ApplicationShortcutCoordinator` and `TerminalTabStripLayout` covered **83.42% of
lines** (3,008/3,606) and **85.20% of functions**; the pure layout file itself had
100% line/function coverage. All first-party `Sources`, including declarative
SwiftUI that the unit harness does not invoke, covered **63.36% of lines**
(3,242/5,117) and **66.14% of functions**. The lower unfiltered number is retained
so scoped coverage is not misrepresented as whole-source coverage.

The final independent re-review is **READY** for the source/automated slice: the
single-final-scroll scheduling fix resolves the prior finding, the focused 17-test
suite passes, and no Critical, Important, or Minor finding remains in scope.

The staged app was manually inspected with one, two/three, six, and ten/eleven tabs.
It showed content-sized preferred-width tabs, equal shrink, readable horizontal
overflow with pinned `+`, two-way computer-use scrolling, and selected-tab reveal
after activation/create/close/resize. The unchanged local/relay menu opened by
pointer and dismissed with Escape, and AX inspection found the tab container,
selected/status state, close labels, `+` metadata, and separate toolbar sibling.

Physical trackpad momentum, rendered long-title truncation, full Tab-key focus
traversal, actual VoiceOver, a system Reduce Motion toggle, relay invocation, and
quantitative performance inspection remain open. The Command Line Tools-only host
still cannot run the missing full XCUITest suite. Exact commands, provenance, and gaps are in
`docs/audits/0004-phase-2-tab-strip-polish-evidence.md`.

## Phase 3 Session Manager verification

Phase 3 adds deterministic coverage for:

- tagged local/direct-SSH/alias-SSH profile decoding and structural validation;
- immutable create, edit, rename, duplicate, delete, favorite, recency, and
  one-time built-in-default behavior with stable, independent IDs;
- deterministic schema-version-1 JSON, user-only permissions, same-directory
  atomic replacement, partial/corrupt/unsupported recovery, and preservation of
  the prior primary file on failed writes;
- persist-before-publish store behavior, including repeat-action retry, load retry,
  and explicit recovery;
- deferred path inspection, field-specific save/launch errors, and the absence of
  filesystem checks from draft typing;
- Recent/Favorites/SSH/Local grouping, name/host/user/alias/shell search, stable
  keyboard selection, empty results, and the `Command-T` saved-local policy;
- exact local/direct/alias launch construction, source-profile provenance,
  independent tab/session identities, and immutable launched-tab snapshots after
  profile edits or deletion;
- coordinator ordering, recency only after successful tab creation, error
  surfacing, accessibility presentation copy, and existing terminal coexistence.

The Phase 3 isolated coverage invocation passed **268 tests in 35 suites in 7.199
seconds**. Coverage is reported at three deliberately different scopes:

- all first-party `Sources`: **53.79% lines**, **58.54% functions**;
- UI-inclusive Phase 3 production files: **48.27% lines**, **54.90% functions**;
- supplementary testable Phase 3 logic, excluding declarative SwiftUI bodies that
  the unit harness cannot instantiate: **87.97% lines**, **89.07% functions**.

The lower UI-inclusive and whole-source numbers are retained so the supplementary
logic result is not misrepresented as application-wide coverage. The pure
100-profile picker projection test completed in **0.004 seconds**. Isolated debug
and release builds with `-Xswiftc -warnings-as-errors` completed successfully in
**45.08 seconds** and **66.80 seconds**, respectively.

The Command Line Tools-only host still cannot run a full XCUITest suite. Search
focus, pointer/keyboard workflows, native sheets/popovers, appearance, Reduce
Motion, VoiceOver-facing labels, restart persistence, packaged process arguments,
and persistence/recovery errors therefore require the packaged-app matrix rather
than being inferred from unit coverage. Exact commands, results, exceptions, and
known limitations are recorded in
`docs/checklists/session-manager-acceptance.md` and
`docs/audits/0005-phase-3-session-manager-evidence.md`. No SFTP, remote-file, or
editor-sync test is attributed to Phase 3 because those implementations have not
started.

## Phase 4A Remote Workspace verification

Phase 4A adds deterministic Swift Testing coverage for:

- raw-byte path identity, Unicode/invalid-byte safe display, breadcrumbs, shell
  quoting, and validation limits (`RemotePathTests`, `RemoteFileEntryTests`);
- the provider contract, all typed error categories, cancellation, close, and
  listing bounds (`RemoteFileProviderContractTests`);
- the bounded LRU cache (`RemoteDirectoryCacheTests`) and workspace state machine
  navigation/history/refresh/expansion/race/close behavior
  (`RemoteWorkspaceTests` plus lifecycle, close-settlement, boundedness, and
  contract suites);
- session-centric runtime composition, store registry migration, and aggregate
  close settlement (`RuntimeSessionTests`, store suites);
- presentation, sidebar policy, and pasteboard policies
  (`RemoteWorkspacePresentationTests`, `RemoteWorkspaceSidebarPolicyTests`,
  `RemotePathPasteboardTests`);
- focused command routing: exact-owner guards, stale-tab rejection,
  Back/Forward/Parent/Refresh/open/retry routing to the exact workspace methods,
  copy routing through the pasteboard adapter, sidebar interaction routing,
  `Command-Down`/`Command-Up` bindings, an unbound Return, and unchanged terminal
  command routing (`TerminalWorkspaceCommandTests`, 18 tests);
- the explicit env-gated simulated developer fixture
  (`RemoteWorkspaceDeveloperFixtureTests`);
- the 1,000-entry model/order/publication performance gate
  (`RemoteWorkspacePerformanceTests`, 20.84 ms p90 against the 100 ms budget).

On 2026-07-17 the full-suite coverage invocation passed **404 tests in 51 suites
in 9.967 seconds**. Coverage is reported at deliberately different scopes:

- `XMtermRemote` sources: **93.27% lines**, **94.25% functions**;
- new app remote-workspace policy/runtime logic excluding SwiftUI view bodies
  (`RemoteWorkspacePresentation`, `RemotePathPasteboard`,
  `RemoteWorkspaceFocusedValues`, `RemoteWorkspaceDeveloperFixture`,
  `RuntimeSession`): **94.49% lines**, **82.54% functions**;
- the UI-inclusive remote-workspace app scope, including declarative
  `RemoteWorkspaceSidebar`/`RemoteEntryRow` bodies and menu commands the unit
  harness cannot instantiate: **42.29% lines**, **45.89% functions**;
- all first-party `Sources`: **58.11% lines**, **63.42% functions**.

The lower UI-inclusive and whole-source numbers are retained so the scoped logic
results are never misrepresented as application-wide coverage. Isolated
`-Xswiftc -warnings-as-errors` debug and release builds completed cleanly in
**82.55 s** and **147.59 s**. SwiftUI listing rows, sidebar composition, and menu
rendering remain covered by source review plus the packaged simulated-fixture
manual pass recorded in
`docs/audits/0006-phase-4a-remote-workspace-evidence.md`; no automated result is
claimed for them. Automated tests never contact the real Relay Host, and no
simulated listing is presented as real remote evidence.

### Phase 4A hardening additions (2026-07-18)

The hardening pass adds deterministic coverage for three new boundaries:

- **Trusted provider mode and release fail-closed composition**
  (`RemoteWorkspaceDeveloperFixtureTests`, `RemoteWorkspacePresentationTests`):
  the `RemoteProviderMode` carried by each workspace comes only from trusted
  composition; the exact environment value activates the simulated fixture only
  when the compile-time developer flag is true; release-parameterized
  composition fails closed to the unavailable provider; the SIMULATED badge
  presentation derives from the mode alone, and provider capability text
  containing "Simulated" cannot create it.
- **Actual workspace focus gating** (`TerminalWorkspaceCommandTests`,
  `RemoteWorkspaceSidebarPolicyTests`): `RemoteWorkspaceFocusedActions` carries
  an injected workspace-focus signal fed by the sidebar's `@FocusState`;
  `RemoteWorkspaceCommandRoute` menu/shortcut routing requires focus in
  addition to the exact owner and policy, while direct sidebar controls and
  context menus stay focus-independent; a closed workspace performs no
  operation for stale snapshots.
- **Shared visible-entry projection and descendant selection**
  (`RemoteWorkspaceVisibleEntryProjectionTests`,
  `RemoteWorkspaceDescendantSelectionTests`): one pure projection produces both
  the rendered rows and the selectable-path set (rows, depths, honest status
  rows, bounded depth equal to the workspace expansion bound, raw-byte and
  lossy-path identity, and a 1,000-entry projection/lookup budget); workspace
  selection accepts exactly the projected entries, collapse moves a hidden
  descendant selection to the collapsed directory, refresh restores only the
  exact surviving raw path (nearest-visible-ancestor repair, never display-name
  redirection), history restores exact recorded paths only, and selection never
  triggers provider I/O.
