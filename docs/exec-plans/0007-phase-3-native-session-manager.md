# Phase 3 Native Session Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable local and SSH launch profiles, a searchable native picker,
profile CRUD/favorites/recents, and profile-backed terminal creation without
changing the proven PTY/terminal behavior.

**Architecture:** Keep profile persistence in a serialized repository actor and
publish immutable profile state through a `MainActor` store. Convert a validated
profile into an immutable launch snapshot, then pass that snapshot through the
existing workspace, terminal-session, PTY launch, retained-view, focus, and tab
reveal paths.

**Tech Stack:** Swift 6, SwiftUI/AppKit on macOS 14+, Observation, Foundation
Codable/JSON/FileManager, Swift Testing, SwiftPM, existing SwiftTerm/PT​Y boundary.

---

- **Status:** Complete — Task 8 closed with retained limitations in Audit 0005
- **Started:** 2026-07-16
- **Design:** [`../design-docs/session-manager.md`](../design-docs/session-manager.md)
- **ADR:** [`../decisions/0005-session-profile-persistence.md`](../decisions/0005-session-profile-persistence.md)
- **Baseline:** `./scripts/verify.sh` passed 143 tests in 23 suites on 2026-07-16

## Acceptance requirements

- Existing: `TAB-001`, `TAB-002`, `TAB-003`, `TAB-005`, `SESS-001` through
  `SESS-004`, `APP-003`, `APP-004`, `APP-007`, `APP-008`, `A11Y-001` through
  `A11Y-003`, `MAC-001`, `MAC-003`, `MAC-006`, `TERM-STATE-001`, and
  `TERM-SEC-001`.
- Phase 3 additions to be added to `INTERACTIONS.md` before production code:
  - `SESS-007`: saved profiles are launch templates; launched tabs retain immutable
    snapshots and distinct identity;
  - `SESS-008`: versioned atomic persistence, one-time seeding, and corruption
    recovery;
  - `SESS-009`: searchable picker, favorites, recents, keyboard/focus behavior;
  - `SESS-010`: create/edit/duplicate/delete validation and existing-tab isolation.

## Scope and explicit deferrals

Implement saved local profiles, direct and alias SSH profiles, JSON persistence,
one-time defaults, picker, recents, favorites, CRUD, validation, launch snapshots,
tests, and documentation.

Do not implement alias discovery/import, `ssh -G` presentation, SFTP, remote files,
editor sync, ProxyJump UI, second-hop automation, direct internal-node profiles,
reconnect, tunnels, tmux, startup commands, credentials, cloud sync, plugins, or a
full Settings redesign.

## Locked policies

- Alias mode discards/disables direct fields and launches exactly one alias argument.
- Duplicate gets a new ID, ` Copy` name, no favorite, and no recency.
- Recent is derived from `lastOpenedAt`, newest first, unique, and capped at 8.
- Picker section precedence is Recent, Favorites, SSH, Local; each profile appears
  once so row selection is keyed directly by `SessionProfileID`.
- `Command-T` launches the first saved login-shell local profile; if none exists,
  it opens the picker.
- Recency updates after a tab/session pair is created, not on highlight or picker
  opening. A later child-process launch failure does not roll back that user action.
- A corrupt/unsupported store is preserved and read-only until explicit recovery.

## File map

### Domain and launch values

- Modify `Sources/XMtermCore/Models/SessionProfile.swift`: immutable common model,
  stable ID, tagged local/SSH payload, custom version-stable Codable.
- Create `Sources/XMtermCore/Sessions/SessionProfileDraft.swift`: editor-only draft
  and mode values.
- Create `Sources/XMtermCore/Sessions/SessionProfileValidation.swift`: structural
  field errors and normalization.
- Create `Sources/XMtermCore/Sessions/SessionProfileCollection.swift`: immutable
  seed/CRUD/favorite/recent behavior.
- Create `Sources/XMtermCore/Terminal/SessionLaunchSpecification.swift`: immutable
  profile-to-tab launch snapshot and `TerminalSessionID`.
- Modify `Sources/XMtermCore/Models/TerminalTab.swift`: launch snapshot and source
  profile provenance.
- Modify `Sources/XMtermCore/Terminal/TerminalTabsState.swift`: snapshot-based tab
  creation and trusted profile title.

### Persistence and application state

- Create `Sources/XMtermApp/SessionManager/SessionProfileRepository.swift`:
  repository protocol, version-1 document, typed load/recovery results and errors.
- Create `Sources/XMtermApp/SessionManager/JSONSessionProfileRepository.swift`:
  Application Support path, per-entry recovery, permissions, temp/atomic replace.
- Create `Sources/XMtermApp/SessionManager/SessionProfilePathInspector.swift`:
  asynchronous executable/file/directory checks.
- Create `Sources/XMtermApp/SessionManager/SessionProfileStore.swift`: observable
  load/seed/recovery/CRUD/favorite/recent state.
- Create `Sources/XMtermApp/SessionManager/SessionPickerModel.swift`: pure grouping,
  filtering, stable selection, and arrow/Return projection.

### Terminal and workspace integration

- Create `Sources/XMtermTerminal/Session/SessionLaunchConfigurationFactory.swift`:
  local-login/custom-shell and direct/alias SSH conversion to the existing PTY
  configuration.
- Modify `Sources/XMtermTerminal/Session/TerminalSession.swift`: accept immutable
  launch specifications and distinct terminal-session IDs.
- Modify `Sources/XMtermTerminal/Session/SSHRelayLaunchSpecification.swift`: retain
  a fixed-relay regression façade backed by the generic direct SSH builder.
- Modify `Sources/XMtermApp/TerminalWorkspaceStore.swift`: validated profile launch,
  success result, snapshot-retaining tabs, and existing close/focus behavior.
- Modify `Sources/XMtermApp/TerminalPresentationPolicy.swift`: generic local/SSH
  accessibility copy without hard-coded-only relay assumptions.
- Modify `Sources/XMtermApp/TerminalWorkspaceCommands.swift`: profile-backed
  `Command-T` and picker command routing.

### Native UI

- Create `Sources/XMtermApp/SessionManager/SessionPickerView.swift`: searchable
  focused popover with sections, favorite action, keyboard navigation, and empty/error states.
- Create `Sources/XMtermApp/SessionManager/SessionProfileEditorView.swift`: local/SSH
  form, isolated draft, inline errors, Cancel/Save focus and keyboard behavior.
- Create `Sources/XMtermApp/SessionManager/SessionManagerView.swift`: single-selection
  list, add/edit/duplicate/favorite/delete/context menu, loading/error/recovery states.
- Modify `Sources/XMtermApp/TerminalTabStrip.swift`: replace fixed menu with pinned
  popover anchor while preserving geometry and accessibility identifier.
- Modify `Sources/XMtermApp/TerminalWorkspaceHeader.swift`: pass picker/store actions
  without changing width ownership.
- Modify `Sources/XMtermApp/RootView.swift`: own presentation bindings, coordinate
  picker dismissal, launch, recency, management sheets, and focus restoration.
- Modify `Sources/XMtermApp/XMtermApp.swift`: own the app-scoped profile store.

### Tests

- Modify `Tests/XMtermCoreTests/SessionProfileTests.swift`.
- Create `Tests/XMtermCoreTests/SessionProfileCollectionTests.swift`.
- Create `Tests/XMtermCoreTests/SessionProfileValidationTests.swift`.
- Create `Tests/XMtermCoreTests/SessionLaunchSpecificationTests.swift`.
- Create `Tests/XMtermTerminalTests/SessionLaunchConfigurationFactoryTests.swift`.
- Create `Tests/XMtermTerminalTests/TerminalSessionProfileTests.swift`.
- Create `Tests/XMtermAppTests/JSONSessionProfileRepositoryTests.swift`.
- Create `Tests/XMtermAppTests/SessionProfileStoreTests.swift`.
- Create `Tests/XMtermAppTests/SessionPickerModelTests.swift`.
- Create `Tests/XMtermAppTests/TerminalWorkspaceStoreProfileTests.swift`.
- Create `Tests/XMtermAppTests/TestSupport/InMemorySessionProfileRepository.swift`.
- Modify existing terminal/workspace/command/presentation tests for the generalized
  factory while preserving their Phase 1/2 assertions.

### Documentation and evidence

- Create `docs/checklists/session-manager-acceptance.md`.
- Create `docs/audits/0005-phase-3-session-manager-evidence.md`.
- Update `README.md`, `PRODUCT.md`, `ARCHITECTURE.md`, `INTERACTIONS.md`, `PLANS.md`,
  `PERFORMANCE.md`, `SECURITY.md`, `TESTING.md`, `docs/design-docs/index.md`,
  relevant existing session/macOS/SSH design docs, interaction/terminal checklists,
  ADR 0004, this plan, and `scripts/verify.sh`.

The workspace is untracked inside an unrelated parent repository, so this plan does
not create parent-repository commits. Each task ends with direct file inspection and
verification instead of a misleading partial commit.

---

### Task 1: Freeze the Phase 3 contract and profile value model

**Files:**
- Modify: `INTERACTIONS.md`
- Modify: `Sources/XMtermCore/Models/SessionProfile.swift`
- Create: `Sources/XMtermCore/Sessions/SessionProfileDraft.swift`
- Test: `Tests/XMtermCoreTests/SessionProfileTests.swift`

- [x] **Step 1: Add `SESS-007` through `SESS-010` to the canonical interaction contract**

State template/instance identity, JSON seeding/recovery, picker keyboard/focus, and
CRUD validation behavior without weakening `SESS-001` through `SESS-004`.

- [x] **Step 2: Write RED model/Codable tests**

Tests must assert local/direct/alias round trips, stable IDs/dates/favorite/order,
explicit `kind`, no credential keys, and rejection of contradictory payloads.

- [x] **Step 3: Run the focused suite and confirm RED**

Run `swift test --filter SessionProfileTests`.

Expected: compile failures for the new tagged types and initializers.

- [x] **Step 4: Implement the minimal immutable model and custom Codable**

Required shape:

```swift
public struct SessionProfileID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct SessionProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: SessionProfileID
    public let name: String
    public let favorite: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let lastOpenedAt: Date?
    public let sortOrder: Int
    public let configuration: SessionProfileConfiguration
}

public enum SessionProfileConfiguration: Hashable, Sendable {
    case local(LocalSessionProfile)
    case ssh(SSHSessionProfile)
}
```

- [x] **Step 5: Run focused tests and confirm GREEN**

Run `swift test --filter SessionProfileTests`.

Expected: all model and encoded-security tests pass.

### Task 2: Validation, one-time defaults, CRUD, favorites, and recents

**Files:**
- Create: `Sources/XMtermCore/Sessions/SessionProfileValidation.swift`
- Create: `Sources/XMtermCore/Sessions/SessionProfileCollection.swift`
- Create: `Tests/XMtermCoreTests/SessionProfileValidationTests.swift`
- Create: `Tests/XMtermCoreTests/SessionProfileCollectionTests.swift`

- [x] **Step 1: Write RED validation tests**

Cover blank/control-bearing names; Unicode names; direct host/user/port boundaries;
option-shaped alias; contradictory alias/direct fields; absolute shell/working/
identity paths; and valid login-shell/direct/alias drafts.

- [x] **Step 2: Confirm validation RED**

Run `swift test --filter SessionProfileValidationTests`.

- [x] **Step 3: Implement normalized drafts and field-specific structural errors**

Use stable fields such as `.name`, `.host`, `.port`, `.user`, `.sshConfigAlias`,
`.identityFilePath`, `.shellPath`, and `.workingDirectory`.

- [x] **Step 4: Write RED collection tests**

Cover two-default seed, stable IDs, valid empty collection, create/edit/rename,
duplicate reset rules, delete, never-reseed behavior, favorite/unfavorite, recent
ordering/dedup/cap, and tab-independent value copies.

- [x] **Step 5: Implement immutable collection operations**

Every operation returns a new collection/profile array; no method mutates an
existing profile object.

- [x] **Step 6: Confirm both suites GREEN**

Run:

```bash
swift test --filter SessionProfileValidationTests
swift test --filter SessionProfileCollectionTests
```

### Task 3: Versioned atomic JSON persistence and recovery

**Files:**
- Create: `Sources/XMtermApp/SessionManager/SessionProfileRepository.swift`
- Create: `Sources/XMtermApp/SessionManager/JSONSessionProfileRepository.swift`
- Create: `Tests/XMtermAppTests/JSONSessionProfileRepositoryTests.swift`

- [x] **Step 1: Write RED real-temporary-directory tests**

Cover save/reload, schema version, deterministic order, valid empty document,
favorite/recent persistence, `0600` file/`0700` directory, absence of credential
keys, and the production path resolver's `Application Support/XMterm/sessions.json`
suffix.

- [x] **Step 2: Confirm repository RED**

Run `swift test --filter JSONSessionProfileRepositoryTests`.

- [x] **Step 3: Implement version-1 encode/load and atomic replacement**

Use a same-directory unique temporary file, `FileManager.replaceItemAt` for an
existing primary, `moveItem` for first initialization, and cleanup on every failure.

- [x] **Step 4: Add RED failure/recovery tests**

Cover replacement failure retaining prior bytes, corrupt-file preservation, one bad
entry with valid siblings, duplicate IDs, unsupported schema, missing primary plus
recovery file, and explicit recovered/default reset.

- [x] **Step 5: Implement typed recovery without automatic overwrite**

The loader returns `.uninitialized`, `.loaded`, or `.recoveryRequired`; it never
writes while handling corruption.

- [x] **Step 6: Confirm repository GREEN**

Run `swift test --filter JSONSessionProfileRepositoryTests`.

### Task 4: Observable profile store and asynchronous path validation

**Files:**
- Create: `Sources/XMtermApp/SessionManager/SessionProfilePathInspector.swift`
- Create: `Sources/XMtermApp/SessionManager/SessionProfileStore.swift`
- Create: `Tests/XMtermAppTests/TestSupport/InMemorySessionProfileRepository.swift`
- Create: `Tests/XMtermAppTests/SessionProfileStoreTests.swift`

- [x] **Step 1: Write RED store tests**

Cover load/seed once, loaded empty no reseed, renamed/deleted defaults surviving
reload, loading/content/error/recovery states, write failure leaving published state
unchanged, explicit recovery, CRUD, favorite, recency, and filesystem validation.

- [x] **Step 2: Confirm store RED**

Run `swift test --filter SessionProfileStoreTests`.

- [x] **Step 3: Implement the minimal `@MainActor @Observable` store**

The store injects repository, clock, ID source, and path inspector. It awaits the
serialized repository write before publishing CRUD changes and exposes concise
user messages plus typed internal error categories.

- [x] **Step 4: Confirm store GREEN and run Core regressions**

Run:

```bash
swift test --filter SessionProfileStoreTests
swift test --filter SessionProfile
```

### Task 5: Immutable launch snapshots and generic PTY configuration

**Files:**
- Create: `Sources/XMtermCore/Terminal/SessionLaunchSpecification.swift`
- Modify: `Sources/XMtermCore/Models/TerminalTab.swift`
- Modify: `Sources/XMtermCore/Terminal/TerminalTabsState.swift`
- Create: `Sources/XMtermTerminal/Session/SessionLaunchConfigurationFactory.swift`
- Modify: `Sources/XMtermTerminal/Session/TerminalSession.swift`
- Modify: `Sources/XMtermTerminal/Session/SSHRelayLaunchSpecification.swift`
- Create: `Tests/XMtermCoreTests/SessionLaunchSpecificationTests.swift`
- Create: `Tests/XMtermTerminalTests/SessionLaunchConfigurationFactoryTests.swift`
- Create: `Tests/XMtermTerminalTests/TerminalSessionProfileTests.swift`

- [x] **Step 1: Write RED identity/snapshot tests**

Assert profile, tab, and terminal-session IDs are distinct; snapshot title/target do
not change after profile edit/delete; tab rename does not change snapshot/profile;
and source profile provenance remains available.

- [x] **Step 2: Confirm snapshot RED**

Run `swift test --filter SessionLaunchSpecificationTests`.

- [x] **Step 3: Implement snapshot-based tab state**

`TerminalTabsState.creatingTab` accepts a `SessionLaunchSpecification`, appends and
selects a fresh tab ID, and never derives titles from hard-coded ordinals.

- [x] **Step 4: Write RED exact launch tests**

Assert Relay Host and generic direct SSH argv, identity argument order, alias-only
argv, local login resolution, custom shell, working directory, inherited OpenSSH
environment, no wrapper/command string, and missing executable failures.

- [x] **Step 5: Implement generic launch configuration factory**

Reuse `PTYLaunchConfiguration` unchanged. Retain the fixed-relay test façade but
route runtime defaults through the saved Relay Host profile.

- [x] **Step 6: Generalize `TerminalSession` and confirm GREEN**

Run:

```bash
swift test --filter SessionLaunchConfigurationFactoryTests
swift test --filter TerminalSessionProfileTests
swift test --filter TerminalSessionSSHTests
swift test --filter SSHRelayLaunchSpecificationTests
```

### Task 6: Picker projection and profile-backed workspace creation

**Files:**
- Create: `Sources/XMtermApp/SessionManager/SessionPickerModel.swift`
- Modify: `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- Modify: `Sources/XMtermApp/TerminalWorkspaceCommands.swift`
- Modify: `Sources/XMtermApp/TerminalPresentationPolicy.swift`
- Create: `Tests/XMtermAppTests/SessionPickerModelTests.swift`
- Create: `Tests/XMtermAppTests/TerminalWorkspaceStoreProfileTests.swift`
- Modify: existing workspace/command/presentation tests

- [x] **Step 1: Write RED picker-model tests**

Cover name/host/user/alias/shell search, trimmed/case-insensitive queries, empty/no
results, unique Recent/Favorites/SSH/Local grouping, recent cap/order, stable IDs,
arrow movement, stale selection, Return launch ID, and 100 profiles.

- [x] **Step 2: Confirm picker RED, then implement pure projection**

Run `swift test --filter SessionPickerModelTests` before and after implementation.

- [x] **Step 3: Write RED workspace profile tests**

Cover local/SSH coexistence, exact snapshot capture, new tab selected, source ID,
trusted initial title, same profile opened twice with independent tab/session IDs,
edit/delete unaffected tabs, failed pre-tab validation with no tab, and local/SSH
close isolation.

- [x] **Step 4: Generalize workspace/session factory and command router**

Return an explicit success value from `openProfile`. Preserve the current
publish/start/focus/reveal ordering and all shutdown guards.

- [x] **Step 5: Confirm app-layer GREEN**

Run:

```bash
swift test --filter TerminalWorkspaceStoreProfileTests
swift test --filter TerminalWorkspaceStoreTests
swift test --filter TerminalWorkspaceStoreSSHTests
swift test --filter TerminalWorkspaceCommandTests
swift test --filter TerminalPresentationPolicyTests
```

### Task 7: Native picker, editor, and management sheets

**Files:**
- Create: `Sources/XMtermApp/SessionManager/SessionPickerView.swift`
- Create: `Sources/XMtermApp/SessionManager/SessionProfileEditorView.swift`
- Create: `Sources/XMtermApp/SessionManager/SessionManagerView.swift`
- Modify: `Sources/XMtermApp/TerminalTabStrip.swift`
- Modify: `Sources/XMtermApp/TerminalWorkspaceHeader.swift`
- Modify: `Sources/XMtermApp/RootView.swift`
- Modify: `Sources/XMtermApp/XMtermApp.swift`

- [x] **Step 1: Wire app-scoped profile state and delayed initial local launch**

Load/seed profiles asynchronously, then open the saved login-shell default through
the same profile launch coordinator. Do not recreate terminals on profile changes.

- [x] **Step 2: Replace only the pinned `+` control's content behavior**

Keep the existing width, gap, accessibility identifier, and viewport sibling
position. Anchor the compact popover to that button; opening it starts no process.

- [x] **Step 3: Implement picker focus, keyboard, search, actions, and accessibility**

Use `@FocusState` plus scoped SwiftUI key handling for Up/Down/Return/Escape. Do not
install an application-wide event monitor that could steal terminal Control input.

- [x] **Step 4: Implement isolated profile editor and manager sheet**

Provide inline errors, async path validation, disabled invalid Save, Cancel/Escape,
default focus, list selection, add/edit/duplicate/favorite/delete, context menus,
exact delete confirmation, and loading/empty/error/recovery states.

- [x] **Step 5: Build with warnings as errors**

Run `swift build -Xswiftc -warnings-as-errors`.

Expected: no Swift 6 concurrency, SwiftUI availability, or accessibility warnings.

- [x] **Step 6: Run all focused Phase 3 suites**

Run every filter from Tasks 1–6, then `./scripts/verify.sh`.

### Task 8: Documentation, review, coverage, and manual acceptance

**Files:**
- Create: `docs/checklists/session-manager-acceptance.md`
- Create: `docs/audits/0005-phase-3-session-manager-evidence.md`
- Modify: all status/architecture/security/performance/testing documents listed in
  the file map plus `scripts/verify.sh`

- [x] **Step 1: Update contract and status documentation honestly**

Mark alias entry/launch implemented but alias discovery/import deferred. Do not
mark SFTP, Remote File Browser, editor sync, reconnect, ProxyJump editing, or
distribution approval complete.

- [x] **Step 2: Run canonical and warning-clean builds**

```bash
./scripts/verify.sh
swift build --scratch-path /tmp/xmterm-phase3-debug -Xswiftc -warnings-as-errors
swift build -c release --scratch-path /tmp/xmterm-phase3-release -Xswiftc -warnings-as-errors
```

- [x] **Step 3: Run isolated coverage and report both scoped and whole-source results**

Use `swift test --scratch-path /tmp/xmterm-phase3-coverage --enable-code-coverage`
with the Command Line Tools framework flags from `scripts/verify.sh`, then report
`llvm-cov` results without representing the scoped 80% gate as whole-source coverage.

- [x] **Step 4: Run security and independent code/requirements review**

Review encoded JSON, argument construction, input/path validation, error redaction,
atomic replacement, corruption preservation, actor/main-thread boundaries, stable
identity, and existing-tab isolation. Resolve every critical/high finding and add
RED regression tests for fixes.

- [x] **Step 5: Stage and perform the manual acceptance matrix**

Run `./script/build_and_run.sh --verify`, then verify pointer/keyboard picker use,
search focus, Return/Escape, correct Relay and local launches, restart persistence,
CRUD/favorite/recent, inline errors, existing-tab independence, long names, 100
profiles, dark/light/Reduce Motion, AX labels, and preserved Phase 1/2 behavior.

- [x] **Step 6: Record exact evidence and finish the plan**

Record exact files, commands, test counts/timings, coverage, manual passes/gaps,
security/performance observations, known limitations, and the exact next task:

```text
Phase 4A — Remote SFTP File Browsing
```

Do not begin Phase 4A.
