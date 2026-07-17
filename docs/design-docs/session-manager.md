# Native Session Manager Design

- **Status:** Implemented in Phase 3
- **Date:** 2026-07-16
- **Owner:** Project owner
- **Decision scope:** Saved local and SSH launch templates, persistence, picker,
  profile management, and profile-backed terminal creation
- **Canonical requirements:** `TAB-001`, `TAB-002`, `TAB-003`, `TAB-005`,
  `SESS-001` through `SESS-004`, `SESS-007` through `SESS-010`, `APP-003`,
  `APP-004`, `APP-007`, `APP-008`,
  `A11Y-001` through `A11Y-003`, `MAC-001`, `MAC-003`, and `MAC-006`

## Goal

Replace XMterm's fixed local/relay creation choices with reusable saved launch
profiles while preserving the existing terminal, PTY, retained-view, close-policy,
and browser-like tab-strip behavior.

The Session Manager is intentionally small. It is not a settings framework, an
SSH configuration editor, a remote-file browser, or a credential store.

## Design alternatives

### Selected: tagged immutable profile values

`SessionProfile` owns common immutable metadata and one tagged payload:

```text
SessionProfile
├── SessionProfileID
├── name, favorite, dates, sortOrder
└── configuration
    ├── local(LocalSessionProfile)
    └── ssh(SSHSessionProfile)
        ├── direct(host, port, user, optional identity path)
        └── configAlias(alias)
```

This makes invalid mixed local/SSH states unrepresentable after validation and
produces a stable, explicit JSON schema.

### Rejected: one flat model with optional fields

A flat model is initially shorter, but permits contradictory states such as a
login-shell profile with SSH credentials or an alias profile that also launches a
direct host. Every consumer would need to repeat the same validity rules.

### Rejected: class hierarchy plus database-backed settings

Separate subclasses and a database add identity, migration, and observation
complexity without value for two small profile kinds. A full preferences window is
also outside the requested phase.

## Architecture and ownership

```text
RootView (window presentation and focus coordination)
├── SessionProfileStore (MainActor observable application state)
│   └── JSONSessionProfileRepository actor
│       └── Application Support/XMterm/sessions.json
├── SessionPickerModel (pure grouping/search/keyboard policy)
├── SessionPickerView (popover anchored to pinned +)
├── SessionManagerView / SessionProfileEditorView (native sheets)
└── TerminalWorkspaceStore (window-local active terminals)
    └── immutable SessionLaunchSpecification
        └── TerminalSession (distinct session identity)
            └── PTYLaunchConfiguration
                └── existing PTYProcessController / forkpty / execve
```

The profile store never owns a PTY or terminal view. The workspace never performs
JSON I/O. SwiftUI views never invoke shell commands or write files directly.

`JSONSessionProfileRepository` performs synchronous Foundation file operations on
its actor executor, not on `MainActor`. Its public operations are asynchronous and
serialized. Profile mutations are validated before persistence and are published
to the observable store only after the write succeeds.

## Identity and snapshot rules

Four identities remain distinct:

- `SessionProfileID`: stable UUID-backed identity stored in JSON;
- `TerminalTab.ID`: identity of one visible launched tab;
- `TerminalSessionID`: identity of one retained runtime session/view/process owner;
- native child PID/process-group identity: infrastructure-only process identity.

Opening the same profile twice creates two tab IDs and two terminal-session IDs.
Neither equals the profile ID.

Before opening a tab, XMterm validates the selected profile and creates an
immutable `SessionLaunchSpecification`. The specification contains only the source
profile ID, trusted initial title, terminal kind, and copied launch fields. It does
not contain favorite or recent metadata. `TerminalTab` retains that specification.

Editing, renaming, favoriting, or deleting the saved profile therefore cannot
change or close an existing tab. A tab title change cannot change the profile.

## Profile model

### Common metadata

- `id: SessionProfileID`
- `name: String`
- `favorite: Bool`
- `createdAt: Date`
- `updatedAt: Date`
- `lastOpenedAt: Date?`
- `sortOrder: Int`
- one tagged configuration payload

All stored values are immutable. Editing returns a new value with the same ID and
creation date. Duplicate returns a new ID, copies launch fields, appends ` Copy` to
the name, resets `favorite` to `false`, clears `lastOpenedAt`, and assigns a new
sort order.

### Local payload

The editor exposes a clear two-mode policy:

- **Use Login Shell on:** use the exact Phase 1 account/`SHELL`/`/bin/zsh`
  resolution and login `argv[0]`; the custom shell field is disabled and omitted.
- **Use Login Shell off:** require an absolute executable shell path and launch it
  directly with no wrapper and normal `argv[0]`.

Both modes may specify an absolute existing working directory. No startup command
or shell command string is stored.

### SSH payload

The editor exposes Direct Host and SSH Config Alias as mutually exclusive modes.

- Direct mode stores host, port, user, and an optional identity-file path reference.
- Alias mode stores only the alias for launch purposes. Direct fields and identity
  path are disabled and omitted when saved.

The model never contains passwords, OTPs, passphrases, or private-key bytes.

## Validation

Validation produces field-specific errors keyed to stable fields. Structural checks
are pure; filesystem checks run asynchronously behind `SessionProfilePathInspector`.

Common rules:

- trim surrounding whitespace from user-entered fields;
- require a nonempty name;
- reject C0/C1 control characters while preserving ordinary Unicode;
- allow duplicate display names because identity is ID-based.

Direct SSH rules:

- host and user are required and contain no whitespace, control characters, or
  ambiguous `@` separators;
- user cannot begin with `-`;
- port is an integer in `1...65535`;
- identity path, when present, is absolute and refers to an existing readable file;
- `/usr/bin/ssh` must exist and be executable before tab creation.

Alias rules:

- alias is required, contains no whitespace/control characters, and cannot begin
  with `-`;
- no host, port, user, or identity argument is emitted in alias mode.

Local rules:

- custom shell path is required when login-shell mode is off;
- custom shell path is absolute, exists, and is executable;
- optional working directory is absolute and is an existing directory.

Decoded values receive structural validation. Missing local paths are not treated
as JSON corruption because a previously valid executable or directory may have
been removed; the profile remains visible with a runtime/editor validation error.

## Immutable launch construction

The existing `PTYLaunchConfiguration` remains the final process boundary.

Default Relay Host direct SSH produces exactly:

```text
executable: /usr/bin/ssh
arguments:  -p
            54426
            allen921103@140.109.226.155
```

Generic direct SSH without an identity path produces:

```text
/usr/bin/ssh -p PORT USER@HOST
```

With an identity path, arguments are discrete and ordered:

```text
/usr/bin/ssh -i IDENTITY_PATH -p PORT USER@HOST
```

Alias mode produces exactly:

```text
/usr/bin/ssh ALIAS
```

Validation rejects option-shaped aliases instead of changing the required alias
argument contract. No `sh -c`, `bash -c`, `zsh -c`, interpolated command string,
remote command, host-key bypass, or config reimplementation is introduced.

## Persistence format and path

ADR 0005 selects Codable JSON at the bundle-appropriate user Application Support
directory. The production path is:

```text
~/Library/Application Support/XMterm/sessions.json
```

The path is resolved with `FileManager`'s `.applicationSupportDirectory`; no home
directory string is hard-coded.

The version-1 envelope is:

```json
{
  "schemaVersion" : 1,
  "profiles" : [
    {
      "id" : "UUID",
      "name" : "Local Terminal",
      "kind" : "local",
      "favorite" : false,
      "createdAt" : "ISO-8601",
      "updatedAt" : "ISO-8601",
      "lastOpenedAt" : null,
      "sortOrder" : 0,
      "local" : {
        "useLoginShell" : true,
        "shellPath" : null,
        "workingDirectory" : null
      }
    }
  ]
}
```

SSH entries use an `ssh` payload with a `mode` discriminator. Encoder keys are
sorted and profile-array order is stable, making output deterministic.

Writes create a uniquely named temporary file in the destination directory, apply
mode `0600`, and atomically replace or move it into `sessions.json`. The directory
uses mode `0700`. A failed encode, temporary write, permission change, or replace
leaves the prior primary file untouched and removes only XMterm's temporary file.

## First-launch seeding

File absence with no preserved recovery file means the store has never been
initialized. XMterm creates and persists exactly two profiles:

1. `Local Terminal`, login-shell mode;
2. `Relay Host`, direct SSH to the specified public relay endpoint.

IDs are generated once and become stable through persistence. A valid version-1
file with an empty profile array is initialized state and is never reseeded. Deleting
or renaming either default therefore persists normally and is not undone at launch.

## Corruption, recovery, and migration

The loader parses the version envelope first, then decodes profiles independently
so one malformed entry does not discard valid siblings. Duplicate IDs are treated
as malformed entries after the first valid occurrence.

If the envelope is corrupt, unsupported, or contains rejected entries, the primary
file is moved to a uniquely named sibling such as:

```text
sessions.corrupt-20260716T120000Z.json
```

The corrupt/unsupported bytes are therefore preserved and are not overwritten.
XMterm publishes recovered valid profiles when practical, otherwise in-memory
built-in defaults, and enters an explicit recovery-required state. Normal profile
mutations are disabled until the user chooses `Use Recovered Profiles` or `Reset
to Defaults`, which writes a new version-1 primary file. On a later launch, the
presence of a recovery file plus no primary file continues recovery mode instead
of incorrectly treating the store as a first launch.

Version 1 is the initial persisted schema, so no legacy disk migration exists.
Future readers switch on `schemaVersion`, decode an old envelope into the current
model, validate it, and write the migrated document only after the complete
migration succeeds. Unknown newer schemas are preserved and never downgraded.

## Picker behavior

The existing 28-point `+` remains outside the horizontal tab viewport and directly
after it. It becomes a button that anchors a compact native popover. Opening the
popover never launches a process.

The picker contains:

- focused `Search sessions…` field;
- unique Recent rows, newest first, capped at 8;
- Favorites excluding rows already shown in Recent;
- SSH excluding rows already shown above;
- Local excluding rows already shown above;
- New SSH Session, New Local Session, and Manage Sessions actions.

Using precedence rather than duplicate rows keeps each SwiftUI row keyed directly
by one stable `SessionProfileID`. The underlying profile array is never copied into
section-owned models.

Search trims the query and performs case/diacritic-insensitive substring matching
against name, SSH host, SSH user, SSH alias, and local shell path. An empty query
restores grouped sections. Search performs no process, filesystem, or network work.

While the search field has focus, Up/Down move the stable selected profile, Return
opens it, and Escape dismisses the popover. Pointer selection and double-click also
open. Dismissal restores focus to the created terminal or, when no launch occurs,
the `+` button/previous sensible target.

Favorite toggles are available from picker rows and profile-manager context menus.
Recency updates only after `TerminalWorkspaceStore` successfully creates, selects,
and retains a tab/session pair. Highlighting, searching, or opening the picker does
not affect recency.

## Profile management and editing

`SessionManagerView` is one native sheet with a single-selection list and detail
actions. It supports add, edit, duplicate, favorite/unfavorite, and delete through
buttons and context menus. Single selection is the intentional Phase 3 collection
policy; there are no batch actions, drag/drop, copy/cut/paste semantics, or range
selection because profiles are not moved/copied as a collection in this slice.

The editor uses an isolated draft. Save is enabled only after current field-specific
validation passes. Return cannot activate a disabled save; Escape cancels. Saving
is the only persistence point, so typing never writes. Deleting uses:

```text
Delete “PROFILE NAME”?

Existing terminal tabs using this profile will remain open.
The saved profile will be removed.
```

Loading, empty, persistence-error, and recovery-required states have explicit
native presentations. Load failures provide `Try Again`; after a mutation failure,
the prior collection remains published and the user repeats the original action
after repairing the cause. Recovery provides explicit accept/reset actions.

## Tab integration and recency policy

Launching a profile performs these ordered steps:

1. resolve the current profile by stable ID;
2. validate it, including relevant executable/path checks;
3. build an immutable `SessionLaunchSpecification`;
4. create a distinct terminal tab and terminal session;
5. publish/select the tab;
6. start the retained terminal session;
7. dismiss the picker and restore terminal focus;
8. let the existing tab-strip request reveal the selected stable tab ID;
9. update and persist `lastOpenedAt`.

If steps 1–4 fail, recency does not change. If the tab/session pair is created but
the child later fails to launch, recency still reflects the user's successful tab
creation request; the new tab shows the existing typed launch failure.

`Command-T` retains the Phase 1 behavior by opening the first saved login-shell
local profile, normally `Local Terminal`. If no local login-shell profile exists,
it opens the picker instead of reintroducing a hidden hard-coded launch template.

## Error behavior

- Read and write errors are typed and shown without terminal or credential data.
- Recovery-required state preserves the source file and blocks destructive saves.
- Invalid profiles remain in the manager and show field-specific repair guidance.
- Missing `/usr/bin/ssh`, custom shell, identity path, or working directory prevents
  tab creation and names the affected field without logging its sensitive value.
- Once a terminal tab exists, process launch/read/write/resize/cleanup failures use
  the existing terminal lifecycle and isolation behavior.

## Performance

- No idle polling, network request, alias discovery, or `ssh -G` call is added.
- JSON I/O and path checks stay off `MainActor`.
- Search is O(n); section ordering makes the complete picker projection O(n log n).
- Profile changes do not recreate `TerminalSession`, PTY, or retained terminal views.
- SwiftUI collections use stable profile IDs; terminal tab reveal identity remains
  unchanged.
- A 100-profile fixture is part of automated projection coverage and staged
  qualitative verification.

## Security and privacy

- Stored JSON has no password, OTP, passphrase, private-key bytes, terminal input,
  clipboard content, environment dump, or terminal output.
- Identity files are path references only and are never copied.
- Error UI and future logs do not print identity paths or full profile payloads.
- System OpenSSH keeps authority over config, keys, agents, Keychain, host keys, and
  prompts. XMterm adds no host-key bypass and no telemetry.
- The existing terminal-output filter remains unchanged.

## Explicitly deferred

- SSH config alias discovery/import and `ssh -G` presentation;
- SFTP and Remote File Browser;
- external-editor synchronization;
- ProxyJump editing, automatic second hop, and internal-node built-ins;
- reconnect and automatic reconnect;
- tunnels, tmux, startup commands, snippets, cloud sync, and plugins;
- password, OTP, passphrase, or private-key-content storage;
- multi-selection/batch profile operations;
- full Settings redesign and signed/sandboxed distribution approval.

Manual alias entry and exact `/usr/bin/ssh ALIAS` launch are implemented; alias
discovery is not claimed.

## Acceptance criteria

- First initialization persists exactly Local Terminal and Relay Host once.
- `+` stays pinned and opens the searchable, keyboard-operable picker.
- Local, direct SSH, and alias SSH profiles produce exact immutable launch specs.
- CRUD, duplicate, favorite, and recent behavior persist across reloads.
- Editing/deleting profiles cannot mutate or close existing tabs.
- Corruption preserves the source and requires explicit recovery.
- No credential material is encoded.
- Existing Phase 1/2 terminal and tab behavior remains green.
- Phase 4A is not started.

## Phase 3 closeout evidence

The completed Phase 3 surface satisfies the criteria above at its documented
scope; packaged interaction criteria are governed by the row-level acceptance
checklist and are never inferred from unit coverage. The
isolated warnings-as-errors debug and release builds passed
in **45.08 seconds** and **66.80 seconds**. The isolated coverage run passed **268
tests in 35 suites in 7.199 seconds** and reported **53.79% line / 58.54% function**
coverage for all first-party `Sources`, **48.27% / 54.90%** for the UI-inclusive
Phase 3 production set, and **87.97% / 89.07%** for the supplementary testable
Phase 3 logic set. The pure 100-profile projection test completed in **0.004
seconds**.

Numerical coverage does not stand in for native interaction evidence. Exact
packaged-app outcomes, including retained limitations, are in
[`../checklists/session-manager-acceptance.md`](../checklists/session-manager-acceptance.md).
Commands, stored-data/log inspection, review results, and final requirement status
are in
[`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).
The final security review found no Critical, High, or Medium issue in scope.

Phase 3 contains saved-profile and terminal-launch work only. It introduces no
SFTP transport, remote-file browsing, remote-path mutation, transfer queue,
filesystem watcher, external-editor launch, or editor synchronization.

## Unresolved questions

None for Phase 3. Alias discovery/import, signed distribution behavior, and SFTP
belong to later decisions and are not hidden completion gates for this design.
