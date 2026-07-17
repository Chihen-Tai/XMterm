# Audit 0005: Phase 3 Native Session Manager Evidence

- **Date:** 2026-07-16
- **Status:** COMPLETE WITH DOCUMENTED LIMITATIONS — Task 8 closed
- **Host:** macOS 26.5.2 (25F84), Apple silicon arm64, Command Line Tools
- **Swift:** Apple Swift 6.3.3
- **Terminal engine:** SwiftTerm 1.14.0
- **Scope:** saved local/direct-SSH/alias-SSH launch templates, persistence,
  picker, profile management, immutable tab launch snapshots, and Phase 3 closeout

## Outcome

Phase 3 implements a native Session Manager on top of the unchanged Phase 1 PTY
and Phase 2 OpenSSH terminal path. The app owns schema-versioned saved profiles,
one-time defaults, Recent/Favorites/SSH/Local picker sections, name/host/user/alias/
shell search, isolated profile drafts, CRUD/favorite/recency persistence, and
immutable profile-derived launch specifications retained by terminal tabs.

The automated suite, warning-clean debug/release builds, coverage run, package
staging, final verifier, and independent reviews pass for the locked Phase 3
scope. The complete requested packaged-app matrix is recorded with explicit
results; the destructive delete and recovery checks ran only against isolated
stores, and keyboard-only CRUD, valid-empty, appearance, Reduce Motion, restart,
failure isolation, and cleanup were directly observed. Packaged double-click
activation, actual VoiceOver traversal, and a user-facing tab-rename gesture remain
explicit limitations rather than inferred passes.

No SFTP, Remote File Browser, remote directory loading, editor synchronization,
Phase 4 domain model, remote daemon, recursive indexer, or Phase 4 UI was added.

## Architecture and implementation summary

```text
XMtermApp (application-scoped profile store)
  -> SessionProfileStore (MainActor, persist before publish)
    -> JSONSessionProfileRepository actor
      -> Application Support/XMterm/sessions.json
  -> SessionPickerModel/View + SessionManager/Editor views
  -> SessionProfileLaunchCoordinator
    -> immutable SessionLaunchSpecification
      -> window-local TerminalWorkspaceStore
        -> TerminalSession + existing PTYProcessController
          -> direct login shell or /usr/bin/ssh argv
```

- `SessionProfile` is an immutable tagged value: local, direct SSH, or SSH config
  alias. Contradictory payloads and unknown encoded fields are rejected.
- The repository serializes filesystem work in an actor. The observable store
  runs on `MainActor`, awaits a successful repository save, then publishes the new
  collection. A failed write leaves the published collection unchanged.
- Structural validation is cheap and synchronous. Executable/file/directory
  existence checks use `SessionProfilePathInspector` only at Save or launch—not
  while the user types.
- Launch builds a copied `SessionLaunchSpecification`. `SessionProfileID`, tab ID,
  terminal-session ID, and process identity remain distinct.
- Existing tabs never observe later profile collection mutations. Provenance is a
  copied source profile ID on the retained launch specification.
- Direct and alias SSH use ordered argument arrays through the existing
  `forkpty`/`execve` boundary. No shell wrapper, remote command, SSH-config parser,
  host-key bypass, or credential UI was introduced.

## Persistence schema and location

Production resolves the location with Foundation's user-domain Application Support
API; no home path is hard-coded:

```text
~/Library/Application Support/XMterm/sessions.json
```

The parent directory is forced to mode `0700`; the primary, temporary, and
preserved-corrupt JSON files use mode `0600`. The version-1 top-level schema is:

```json
{
  "schemaVersion": 1,
  "profiles": [
    {
      "id": "UUID",
      "name": "Local Terminal",
      "favorite": false,
      "createdAt": "ISO-8601 timestamp",
      "updatedAt": "ISO-8601 timestamp",
      "lastOpenedAt": null,
      "sortOrder": 0,
      "kind": "local",
      "local": {
        "useLoginShell": true,
        "shellPath": null,
        "workingDirectory": null
      }
    }
  ]
}
```

SSH profiles use `kind: "ssh"` plus one `ssh` payload. Direct payload keys are
`mode`, `host`, `port`, `user`, and optional `identityFilePath`; alias payload keys
are only `mode` and `alias`. JSON keys are sorted, dates are normalized, document
size is limited to 4 MiB, and profile count is limited to 512.

Persisted timestamps use ISO-8601 millisecond precision. A newly published
in-memory mutation can retain finer `Date` precision until reload, so exact
timestamp equality and extremely close recency ties may normalize by less than one
millisecond across restart.

Writes encode to a unique same-directory `sessions.tmp-*.json`, set user-only
permissions, then atomically replace an existing primary or move the first primary
into place. Failed temporary writes/replacements clean up only XMterm's temporary
file. Corrupt/unsupported content is moved to `sessions.corrupt-*.json`; ordinary
mutations remain blocked until an explicit recovery choice persists a new primary.

The deliberate seed, CRUD, failure, recovery, empty, appearance, and 100-profile
acceptance fixtures used these isolated paths:

```text
/private/tmp/xmterm-phase3-manual
/private/tmp/xmterm-phase3-empty
/private/tmp/xmterm-phase3-100
/private/tmp/xmterm-phase3-recovery-action
/private/tmp/xmterm-phase3-dark
/private/tmp/xmterm-phase3-fixture.swift
```

All six were removed after evidence capture, and a post-cleanup check reported
`REMOVED` for each path. No authorized destructive action targeted the normal
store. The required `./script/build_and_run.sh --verify` staging command had
briefly launched once without an override before the isolated destructive matrix;
no pre/post hash exists for that ordinary launch, so this audit does not claim that
the earlier launch left normal `~/Library/Application Support/XMterm` data
untouched.

## Exact Phase 3 source files

### Production files created

- `Sources/XMtermCore/Sessions/SessionProfileDraft.swift`
- `Sources/XMtermCore/Sessions/SessionProfileValidation.swift`
- `Sources/XMtermCore/Sessions/SessionProfileCollection.swift`
- `Sources/XMtermCore/Terminal/SessionLaunchSpecification.swift`
- `Sources/XMtermTerminal/Session/SessionLaunchConfigurationFactory.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileRepository.swift`
- `Sources/XMtermApp/SessionManager/JSONSessionProfileRepository.swift`
- `Sources/XMtermApp/SessionManager/SessionProfilePathInspector.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileStore.swift`
- `Sources/XMtermApp/SessionManager/SessionPickerModel.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileEditorModel.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileLaunchPolicy.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileLaunchCoordinator.swift`
- `Sources/XMtermApp/SessionManager/SessionPickerView.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileEditorView.swift`
- `Sources/XMtermApp/SessionManager/SessionManagerView.swift`
- `Sources/XMtermApp/SessionManager/SessionProfileStatusViews.swift`

### Production files modified

- `Sources/XMtermCore/Models/SessionProfile.swift`
- `Sources/XMtermCore/Models/TerminalTab.swift`
- `Sources/XMtermCore/Terminal/TerminalTabsState.swift`
- `Sources/XMtermTerminal/Session/TerminalSession.swift`
- `Sources/XMtermTerminal/Session/SSHRelayLaunchSpecification.swift`
- `Sources/XMtermApp/TerminalWorkspaceStore.swift`
- `Sources/XMtermApp/TerminalWorkspaceCommands.swift`
- `Sources/XMtermApp/TerminalPresentationPolicy.swift`
- `Sources/XMtermApp/TerminalPane.swift`
- `Sources/XMtermApp/TerminalTabStrip.swift`
- `Sources/XMtermApp/TerminalWorkspaceHeader.swift`
- `Sources/XMtermApp/RootView.swift`
- `Sources/XMtermApp/XMtermApp.swift`

### Focused tests created

- `Tests/XMtermCoreTests/SessionProfileCollectionTests.swift`
- `Tests/XMtermCoreTests/SessionProfileValidationTests.swift`
- `Tests/XMtermCoreTests/SessionLaunchSpecificationTests.swift`
- `Tests/XMtermTerminalTests/SessionLaunchConfigurationFactoryTests.swift`
- `Tests/XMtermTerminalTests/TerminalSessionProfileTests.swift`
- `Tests/XMtermAppTests/JSONSessionProfileRepositoryTests.swift`
- `Tests/XMtermAppTests/SessionProfileStoreTests.swift`
- `Tests/XMtermAppTests/SessionPickerModelTests.swift`
- `Tests/XMtermAppTests/SessionProfileEditorModelTests.swift`
- `Tests/XMtermAppTests/SessionProfileLaunchCoordinatorTests.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceStoreProfileTests.swift`
- `Tests/XMtermAppTests/TestSupport/InMemorySessionProfileRepository.swift`

### Focused tests modified

- `Tests/XMtermCoreTests/SessionProfileTests.swift`
- `Tests/XMtermAppTests/TerminalPresentationPolicyTests.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceStoreTests.swift`
- `Tests/XMtermAppTests/TerminalWorkspaceCommandTests.swift`

The unchanged Phase 1/2 launch/session regression suites also ran in the full
verifier after the fixed launch choice became profile-backed. No production
dependency was added.

### Task 8 documentation files

Created by this closeout:

- `docs/checklists/session-manager-acceptance.md`
- `docs/audits/0005-phase-3-session-manager-evidence.md`

Modified by this closeout:

- `README.md`
- `PRODUCT.md`
- `ARCHITECTURE.md`
- `INTERACTIONS.md`
- `PERFORMANCE.md`
- `SECURITY.md`
- `TESTING.md`
- `PLANS.md`
- `docs/design-docs/index.md`
- `docs/design-docs/macos-app-behavior.md`
- `docs/design-docs/session-manager.md`
- `docs/design-docs/session-tabs-ux.md`
- `docs/design-docs/ssh-connection-lifecycle.md`
- `docs/design-docs/tab-strip-redesign.md`
- `docs/checklists/interaction-parity.md`
- `docs/checklists/ssh-terminal-acceptance.md`
- `docs/checklists/terminal-acceptance.md`
- `docs/decisions/0004-macos-sandbox-and-distribution.md`
- `docs/decisions/0005-session-profile-persistence.md`
- `docs/exec-plans/0007-phase-3-native-session-manager.md`
- `scripts/verify.sh`

## Warning-treated isolated builds

Debug command:

```bash
swift build \
  --scratch-path /private/tmp/xmterm-phase3-debug-final \
  -Xswiftc -warnings-as-errors
```

Result: exit 0, no warnings; `Build complete! (45.08s)`.

Release command:

```bash
swift build -c release \
  --scratch-path /private/tmp/xmterm-phase3-release-final \
  -Xswiftc -warnings-as-errors
```

Result: exit 0, no warnings; `Build complete! (66.80s)`.

## Tests, verifier, and coverage

### Focused Phase 3 test command

```bash
swift test \
  --filter 'SessionProfile|SessionPicker|SessionLaunch|TerminalWorkspaceStoreProfile' \
  -Xswiftc -F \
  -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Result: exit 0; build completed in 8.07 seconds, then **121 tests in 13
suites passed in 0.144 seconds**.

An earlier diagnostic `swift test list` probe omitted the repository's required
Command Line Tools framework/rpath flags and exited 1 with `no such module
'Testing'`. Comparison with `scripts/verify.sh` identified the missing invocation
flags; the flagged focused command above and canonical verifier both pass. No
source change was made in response to that environment-only probe.

### Isolated coverage test command

```bash
swift test \
  --scratch-path /private/tmp/xmterm-phase3-coverage \
  --enable-code-coverage \
  -Xswiftc -F \
  -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Result: exit 0; coverage build completed in 54.21 seconds, then **268 tests in
35 suites passed in 7.199 seconds**.

Reports used the test bundle
`/private/tmp/xmterm-phase3-coverage/arm64-apple-macosx/debug/XMtermPackageTests.xctest/Contents/MacOS/XMtermPackageTests`
and
`/private/tmp/xmterm-phase3-coverage/arm64-apple-macosx/debug/codecov/default.profdata`
with `xcrun llvm-cov report`.

Coverage is reported in three honest scopes:

| Scope | Regions | Functions | Lines |
|---|---:|---:|---:|
| All mapped first-party `Sources` | 1,975/3,265 (60.49%) | 689/1,177 (58.54%) | 5,490/10,207 (53.79%) |
| UI-inclusive Phase 3 selection | 1,209/2,079 (58.15%) | 448/816 (54.90%) | 3,547/7,349 (48.27%) |
| Supplementary testable Phase 3 logic, excluding eight zero-executed declarative UI files | 1,209/1,520 (79.54%) | 448/503 (89.07%) | 3,547/4,032 (87.97%) |

The 87.97% line result is the supplementary testable-logic gate; it is **not**
represented as whole-source coverage. Eight declarative SwiftUI composition files
were compiled but received no meaningful unit execution. The C PTY shim is not
measured by this Swift coverage report. Full XCUITest remains unavailable on the
Command Line Tools-only host, and brittle SwiftUI `body` evaluation tests were not
added to inflate the numbers.

### Canonical final verifier

Command:

```bash
./scripts/verify.sh
```

Final post-documentation result: exit 0. Required repository files were present;
the debug test build completed in 0.11 seconds; **268 tests in 35 suites passed in
7.434 seconds**; `git diff --check` passed; final output was `XMterm verification:
OK`. Total command wall time was 7.91 seconds.

## Packaged app and manual acceptance

The package/staging command was:

```bash
./script/build_and_run.sh --verify
```

Result: exit 0. The script built, staged, ad-hoc signed, verified, and launched
`dist/XMterm.app`. Its final output was:

```text
Building for debugging...
[0/3] Write swift-version...
Build of product 'XMterm' complete! (0.20s)
/Applications/codes/XMterm-starter/dist/.XMterm.app.staging.35638: replacing existing signature
XMterm is running from /Applications/codes/XMterm-starter/dist/XMterm.app/Contents/MacOS/XMterm
```

Manual persistence/recovery scenarios used only the isolated temporary Application
Support roots listed above.

### Direct packaged observations

- first launch persisted exactly `Local Terminal` and `Relay Host`; the isolated
  Application Support directory and primary file modes were `0700` and `0600`;
- restart reused the same two IDs, so seeding occurred once; a valid empty store
  reopened as `0` profiles with honest `No Saved Sessions` actions and was not
  reseeded;
- `+` opened the picker, search received focus, and name/host/user queries selected
  the expected unique profiles;
- Up/Down changed selection, Return launched, and Escape dismissed/restored focus;
- Recent order changed after launch; favorite and unfavorite both survived restart.
  After unfavoriting `Manual Local`, the restarted picker exposed `Add Manual Local
  to Favorites` and no Favorites section;
- local and direct-SSH profiles were created, a profile was edited, and a duplicate
  had an independent UUID. The final isolated CRUD store held six profiles with six
  unique IDs;
- renaming the seeded Relay profile persisted across restart without reseeding the
  old name, while its already-open tab retained the pre-edit `Relay Host` title;
- keyboard-only Tab/arrow/Return/Space traversal opened Manage Sessions, created
  `Keyboard Local`, renamed the local default to `Local Terminal Keyboard`,
  duplicated it, selected `Relay Renamed`, accepted its exact delete confirmation,
  and returned to the workspace;
- deleting the renamed seeded Relay profile removed it from the store and did not
  close the existing selected `Relay Renamed, SSH session active` tab. Restart kept
  the deleted default absent while the local rename and independent duplicates
  remained;
- packaged `Command-T` launched another selected `Local Terminal` tab from the
  first saved login-shell profile;
- invalid fields showed inline errors; a nonexistent absolute path was not checked
  while typing and failed only at Save;
- a forced write failure left both the file SHA and published profile state
  unchanged; repeating the original favorite action succeeded after write access
  was restored (there is no dedicated mutation `Retry` button);
- a 49-byte corrupt primary with SHA-256
  `9d41915d5bef243cd38eaf7ca64712ee84edb1c0f5dc41a63f48f2c067d0f7b5`
  was preserved byte-for-byte as
  `sessions.corrupt-1784204436913-13d097fb-4591-4df9-ad73-10ec4fa21c94.json`;
  relaunch showed `Recovery required`, and `Reset to Defaults` wrote a mode-`0600`,
  931-byte schema-1 primary containing exactly `Local Terminal` and `Relay Host`
  with SHA-256
  `9d8171c308f2e1687007750c1b33926a979fa51cb7273772aa3766c8a61e999c`;
- process inspection observed Relay Host as exactly
  `/usr/bin/ssh -p 54426 allen921103@140.109.226.155` and Local Terminal as a
  login `-zsh`; local and SSH tabs coexisted;
- accessibility inspection exposed launch and favorite action labels;
- macOS Appearance began at `Automatic` with a visibly dark effective presentation
  and Reduce Motion `off`. Packaged XMterm was observed in explicit Light and Dark
  settings. With Reduce Motion `on`, the 100-profile picker focused search,
  filtered to `Fixture 099`, and launched it without a functional regression;
- after the matrix, System Settings showed explicit Light selected and Reduce
  Motion `off`, satisfying the requested final state;
- the 100-profile picker remained interactive. Computer-use click plus AX-tree
  observation took 1,186 ms and search plus refreshed tree took 490 ms; automation
  overhead is included, so neither is represented as pure app latency;
- XMterm was stopped before cleanup, and all six exact isolated fixture paths
  listed above were removed and verified absent.

### Complete manual result and retained limitations

The itemized matrix is
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md).
All Task 8 manual rows requested by the user were executed or recorded with an
explicit result. Three broader interaction gaps remain and are not inferred as
passes:

- the source contains a double-click launch gesture, but the packaged double-click
  attempt did not launch and this documentation-only task did not debug it;
- actual VoiceOver auditory traversal was unavailable, although the requested
  launch/favorite accessibility labels and roles were inspected;
- tab rename cannot be exercised because Phase 3 has no user-facing tab-rename UI.
  Model tests prove snapshot/profile independence, but the absent UI remains a
  deferred requirement.

## Requirement status

| Requirement | Status | Evidence and boundary |
|---|---|---|
| `SESS-007` | **Implemented for the Phase 3 profile-launch scope** | Immutable profile-to-tab snapshots, distinct identities, provenance, and edit/delete isolation are automated. Packaged edit, rename, delete, and existing-tab isolation were observed. User-facing tab rename is deferred. |
| `SESS-008` | **Implemented for Phase 3** | Versioned deterministic JSON, atomic writes, one-time seed, valid-empty semantics, failure preservation, corrupt preservation, and recovery actions are automated and packaged-observed, including an explicit recovery write. |
| `SESS-009` | **Implemented for the Phase 3 picker** | Search focus/name/host/user, unique sections, Up/Down/Return/Escape, recency, favorites, launch, dismissal, and focus restoration have automated and packaged evidence. Alias/shell search and 100-profile projection are automated. |
| `SESS-010` | **Implemented for Phase 3** | Isolated drafts, local/direct/alias forms, CRUD, duplicate identity, inline structural errors, save-boundary path checks, persist-before-publish, packaged deletion, and keyboard-only management are verified. Alias discovery remains outside this requirement's implemented entry/edit scope. |
| `SESS-001` | **Partial** | Non-secret saved profiles, manual alias entry, favorites, and recents are implemented. Reading/importing aliases from `~/.ssh/config` is deferred. |
| `SESS-002` | **Partial** | Open Terminal and non-secret edit/duplicate/favorite/remove actions are implemented. Open File Browser is Phase 4A and absent. |
| `SESS-003` | **Partial, unchanged** | System OpenSSH still owns terminal host-key/password/OTP/passphrase prompts. No new credential flow was encountered or claimed. |
| `SESS-004` | **Partial** | Structured direct/alias argv and system OpenSSH delegation are implemented. Alias discovery and `ssh -G` presentation remain deferred. |
| `TAB-001` | **Partial canonical / implemented Phase 3 picker subset** | Profile picker and Command-T routing are automated and packaged-observed. Double-click launch remains a packaged evidence gap; the broader tab requirement remains partial. |
| `TAB-002`–`TAB-005` | **Partial, unchanged beyond profile integration** | Stable selection/identity, retained sessions, reveal, and close isolation remain green. Reorder, number/adjacent shortcuts, middle-click, full context menu, reconnect, and unread state remain deferred. |
| `APP-004` | **Partial** | Manager rows implement edit/duplicate/favorite/delete context actions. Packaged secondary-click traversal and the broader multi-selection/batch contract were not exercised. |
| `APP-007` | **Unchanged / not applicable to Phase 3 local writes** | Phase 3 adds no long-running network listing, transfer, or reconnect operation. Future Phase 4 cancellation remains required. |
| `APP-008` | **Implemented for the Phase 3 state surface** | Loading, saving, validation, content, valid empty, persistence-error, and recovery-required states are explicit in source/tests. Packaged observation covered valid empty, persistence error, and recovery required; loading/saving presentation is not inferred from those observations. |
| `APP-003`, `A11Y-001`–`A11Y-003` | **Partial beyond the completed Phase 3 matrix** | Picker/manager keyboard traversal, focus restoration, AX labels, Light/Dark, and Reduce Motion behavior are observed. Actual VoiceOver traversal and pre-existing complete terminal-grid accessibility remain deferred. |
| `MAC-001` | **Partial** | Picker/manager commands share application actions; Command-T policy is automated. Full focused-region/menu/context parity across future file surfaces does not exist. |
| `MAC-003` | **Unchanged / deferred** | Profile provenance is retained, but window/tab restoration and `Command-Shift-T` recently-closed reopening are not implemented. |
| `MAC-006` | **Partial** | Stored data, source logging, and captured packaged output were inspected for credential/path leakage. Diagnostic exports and privacy-aware notifications do not yet exist. |
| `TERM-STATE-001`, `TERM-SEC-001` | **Unchanged** | Phase 3 reuses the established process lifecycle and bounded terminal-output security filter. Reconnect/network state remains deferred. |

## Performance observations

- Profile JSON I/O and path inspection run off `MainActor`; no path inspection is
  triggered by per-keystroke draft edits.
- Picker search/section projection is local O(n log n) work over stable immutable
  values;
  it performs no filesystem, network, `ssh -G`, process, or recursive work.
- The focused 100-profile projection took approximately 0.004 seconds. The
  packaged automation observations were 1,186 ms to click/open/collect a complete
  AX tree and 490 ms to enter a search/collect the refreshed tree; both include
  computer-use and accessibility serialization overhead.
- `SessionPickerView` currently rebuilds the pure projection at several access
  points and resolves displayed IDs with linear lookups. The 100-profile cap test
  remained responsive, but this avoidable rendered-path superlinearity has no
  app-only latency or memory benchmark and remains a low performance limitation.
- Saving performs one bounded JSON encode and same-directory replacement. The
  repository caps documents at 4 MiB and profiles at 512.
- Editing, favoriting, renaming, deleting, and reloading profiles do not recreate
  retained terminal views, terminal sessions, PTYs, or child processes.
- No idle polling, alias scan, network probe, remote directory enumeration, remote
  daemon, or background indexer was introduced.
- No Instruments CPU/RSS/energy run, cold-launch timing, or app-only picker input
  latency trace was performed; no such number is inferred from AX automation.

## Security and privacy observations

- The encoded model has no field for password, OTP, passphrase, private-key bytes,
  terminal input/output, clipboard contents, or environment data. Tests reject
  contradictory/unknown payloads and assert absence of credential keys.
- An identity file is only an optional path reference passed as the distinct
  argument following `-i`; XMterm does not copy or encode key contents.
- Direct SSH arguments are exactly `-i PATH` when present, then `-p PORT`, then
  `USER@HOST`; alias SSH is exactly one validated non-option alias argument.
- `/usr/bin/ssh`, shell, working-directory, and identity-path existence/type checks
  occur at Save/launch boundaries. Pure typing performs no filesystem access.
- Repository permissions, bounded reads/counts, unique temp files, atomic replace,
  cleanup, unknown-key rejection, corrupt preservation, and unsupported-schema
  refusal are covered by focused tests.
- Replacement is namespace-atomic, but the implementation does not explicitly
  `fsync` the file and parent directory; sudden-power-loss durability is therefore
  not proven. Explicit symlink/TOCTOU defenses are also not claimed for a hostile
  same-user filesystem threat model.
- Failed writes preserve both the prior bytes and the observable store collection;
  the packaged write-fault exercise additionally confirmed an unchanged SHA.
- Production-source inspection found no logging calls under `Sources`, so Phase 3
  does not log profile payloads, usernames/hosts, identity paths, credentials,
  terminal contents, or environment values. User-facing repository errors are
  typed and bounded rather than interpolating those values.
- Captured packaged runtime stdout/stderr contained repeated generic SwiftUI
  `AttributeGraph: cycle detected…` diagnostics and one generic Text Services
  Manager line. It contained no profile host, user, identity path, working
  directory, password, OTP, passphrase, or private-key content.
- System OpenSSH continues to own config, keys, `ssh-agent`, Keychain, known-hosts,
  and authentication prompts. Phase 3 adds no bypass, telemetry, credential store,
  shell command construction, remote agent, or new dependency.

### Independent review verdict

Independent final code and security reviews found no Critical, High, or Medium
production finding. Persist-before-publish ordering, corrupt preservation, launch
snapshot isolation, exact Relay argv, schema/key rejection, permissions/bounds,
log privacy, and the absence of Phase 4 implementation were independently
rechecked. The low durability, retention, timestamp, rendered-picker, retry,
in-flight editor-dismissal, packaging, and diagnostic-noise limitations are listed
below.

The first independent requirements review correctly returned **NOT READY** while
packaged rows and the final verifier were still open. After the authorized manual
matrix, system-state restoration, fixture cleanup, documentation reconciliation,
and final verifier, the independent re-review returned **READY WITH DOCUMENTED
LIMITATIONS**. It confirmed every user-listed matrix item is explicitly recorded,
found no remaining closeout blocker, and again found no Phase 4/SFTP source.

## Known limitations and deferred requirements

- SSH config alias discovery/import and `ssh -G` presentation are deferred; users
  may enter a validated alias manually.
- SFTP, Remote File Browser, remote lazy loading/cancellation, transfer state,
  terminal/SFTP authentication coordination, and remote file actions do not exist.
- External-editor download/watch/upload synchronization does not exist.
- Reconnect, automatic reconnect, network-loss classification, sleep/wake handling,
  ProxyJump editing, automatic second hop, and internal-node built-ins are deferred.
- Tab rename UI is absent. Existing snapshot tests establish the model invariant,
  but the requested user-facing rename isolation flow cannot be manually performed.
- Canonical tab reorder, number/adjacent selection shortcuts, middle-click close,
  full tab context menu, and unread-output state remain deferred from earlier phases.
- The packaged double-click attempt did not launch even though the row gesture is
  source-implemented. Return-to-launch is verified; double-click requires a future
  focused diagnosis rather than an inferred pass.
- Actual VoiceOver auditory traversal was unavailable. Accessibility roles and the
  requested launch/favorite labels were inspected, and keyboard-only management
  passed, but full spoken traversal is not claimed.
- The app is an ad-hoc-signed development package. Developer ID signing,
  notarization, sandbox/distribution approval, and release packaging remain future
  work.
- Saved host/user and optional identity/working-directory path references are
  plaintext metadata protected by `0700`/`0600`, not encryption; another process
  running as the same macOS user can read them.
- Namespace-atomic replacement has no explicit file/parent `fsync`, and storage
  symlink/TOCTOU hardening was not established. Power-loss durability and a hostile
  same-user filesystem threat model remain unverified.
- Preserved `sessions.corrupt-*` siblings are not automatically aged or removed,
  and crash-left `sessions.tmp-*` siblings have no startup scavenger. They remain
  user-only files but can accumulate historical connection metadata until a future
  cleanup UI/policy exists.
- JSON dates normalize to millisecond precision. Newly published state can retain
  submillisecond precision until reload, so exact timestamp equality or extremely
  close recency ties may change by less than one millisecond after restart.
- Full XCUITest, whole-source 80% coverage, Instruments performance traces, and a
  quantitative app-only 100-profile render latency are not available/claimed.
- Mutation failures have no dedicated `Retry` button; after repairing the cause,
  the user repeats the original action. Load failures separately expose
  `Try Again`.
- Editor Cancel/Escape remain available while an asynchronous save is in flight.
  Dismissing the sheet does not cancel the already-started persist-before-publish
  operation, so a successful save can finish after the editor closes.
- Packaged debug output includes repeated generic SwiftUI `AttributeGraph` cycle
  diagnostics. They exposed no sensitive values but remain diagnostic noise to
  investigate outside this documentation-only closeout.
- No password, OTP, passphrase, private-key-content, startup-command, snippet,
  tunnel, tmux, cloud-sync, plugin, or full Settings feature is implemented.

## Phase boundary and exact recommendation

Source/file-map review confirms there is no SFTP client, remote-file repository,
remote browser view, transfer actor, editor-sync watcher/uploader, Phase 4 model, or
Phase 4 package target. Task 8 changes are documentation/evidence only.

The final source/package boundary scan was:

```bash
rg -ni 'SFTP|RemoteFileService|RemoteFileBrowser|EditorSync|RemoteDirectory|SFTPClient|FileTransfer' Sources Package.swift
```

Result: exit 1 with empty output, as expected when none of those implementation
symbols or feature names is present.

Phase 4 has **not** started. Phase 3 is closed for its locked scope with the known
limitations above. No SFTP, remote-file, transfer, or editor-sync implementation
was introduced during Task 8.

The exact recommended next task is:

```text
Phase 4A — Remote SFTP File Browsing
```

Do not begin Phase 4A as part of this audit.
