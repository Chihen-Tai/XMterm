# Phase 3 Session Manager Acceptance Checklist

- **Date:** 2026-07-16
- **Target:** packaged native app at `dist/XMterm.app`
- **Automated status:** Passed; 268 tests in 35 suites
- **Packaged-app status:** Complete with the documented limitations below
- **Persistence boundary:** every destructive seed/CRUD/failure/recovery action used
  an isolated `CFFIXED_USER_HOME` root under `/private/tmp`; no destructive action
  targeted the normal XMterm profile store.

`[x]` means direct automated, file/process inspection, or packaged-app evidence
exists. An unchecked row is an explicitly retained limitation, not an inferred
pass. Exact commands, measurements, hashes, and requirement statuses are recorded
in [`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).

## Initialization and durable persistence

- [x] A fresh packaged-app data directory persisted exactly two profiles named
  `Local Terminal` and `Relay Host`.
- [x] The isolated Application Support directory was mode `0700`; `sessions.json`
  was mode `0600`.
- [x] Restart reused the same two profile IDs and did not add another seed copy.
- [x] Deleting the renamed seeded Relay profile, restarting the same isolated
  store, and observing no `Relay Host` or `Relay Renamed` proved deleted defaults
  do not return.
- [x] Before that deletion, renaming `Relay Host` to `Relay Renamed` survived
  restart with its original UUID; the old default name did not return.
- [x] A valid persisted empty collection reopened with zero profiles and the honest
  `No Saved Sessions` actions; it was not treated as first launch or reseeded.
- [x] Favorite and unfavorite both persisted. After unfavoriting `Manual Local`, a
  restart still showed `Add Manual Local to Favorites` and no Favorites section.
- [x] Created, edited, and duplicated profiles retained stable independent IDs and
  values after restart.

## Picker, search, sections, and focus

- [x] The pinned `+` opened the picker without starting a process.
- [x] `Search sessions…` received focus when the picker opened.
- [x] Search by profile name, direct SSH host, and SSH user selected the expected
  unique result. Automated coverage also checks alias and shell-path search,
  trimming, case/diacritic insensitivity, and no-result state.
- [x] With search focused, Up and Down changed the stable selected profile.
- [x] Return launched the selected profile.
- [x] Escape dismissed the picker and restored focus to the `+` control when no
  launch occurred.
- [x] Recent ordering updated after launch and placed the newest launch first.
- [x] Recent, Favorites, SSH, and Local section projection is unique: a profile is
  shown only in its highest-precedence section.
- [ ] **Retained evidence limitation:** double-click launch is source-implemented,
  but the packaged double-click attempt did not launch and was not debugged in this
  documentation-only task. Keyboard Return launch passed.

## Profile creation and management

- [x] A local profile was created through the packaged native editor.
- [x] A direct SSH profile was created through the packaged native editor.
- [x] Automated tests additionally cover manual SSH-config-alias entry and exact
  alias-only launch construction. Alias discovery/import is deferred.
- [x] A profile was edited through an isolated draft and the saved value persisted.
- [x] A profile was duplicated; file inspection confirmed an independent UUID.
  Automated tests also prove the ` Copy` name and cleared favorite/recency.
- [x] The packaged UI displayed this exact confirmation before deletion:
  `Delete “Relay Renamed”? Existing terminal tabs using this profile will remain
  open. The saved profile will be removed.`
- [x] Activating Delete removed the saved profile; restart confirmed it stayed
  deleted.
- [x] Blank/invalid fields showed field-specific inline validation and did not
  enable a valid save.
- [x] Typing a nonexistent absolute path caused no filesystem check in the
  per-keystroke editing path; the path error appeared only at Save, an explicit
  validation boundary.
- [x] Keyboard-only traversal from the focused picker opened Manage Sessions,
  created `Keyboard Local`, edited `Local Terminal`, duplicated it, selected
  `Relay Renamed`, opened the confirmation, and deleted it using Tab, arrows,
  Return, and Space.

## Immutable launch specifications and tab isolation

- [x] Packaged Relay Host process inspection observed exactly:

  ```text
  /usr/bin/ssh
  -p
  54426
  allen921103@140.109.226.155
  ```

- [x] No shell wrapper or interpolated command string was present in the Relay
  Host child process.
- [x] The packaged Local Terminal direct child was `-zsh`, confirming the normal
  login-shell convention on this host.
- [x] Local and SSH tabs coexisted in the packaged app.
- [x] Every launched tab retained its copied source-profile provenance while tab,
  terminal-session, and native-process identities remained distinct.
- [x] Editing/renaming a profile did not mutate an existing tab's title, launch
  arguments, terminal session, or child process.
- [x] Deleting `Relay Renamed` from the saved store left the already-running
  `Relay Renamed, SSH session active` tab open and selected.
- [x] Profile rename did not rename an existing tab.
- [ ] **Deferred UI:** Phase 3 has no user-facing tab-rename action, so a packaged
  tab-rename/profile-isolation gesture cannot be performed. Model tests prove that
  changing tab presentation state does not mutate the saved profile value.
- [x] Packaged `Command-T` launched a second selected local login-shell tab.
  Automated routing also covers the no-login-shell fallback to the picker.

## Loading, errors, empty state, and recovery

- [x] Focused store/view-model tests cover explicit loading, loaded-content, valid
  empty, persistence-error, and recovery-required states; pending/recovery work is
  never represented as successful content.
- [x] The valid-empty packaged fixture showed `0` profiles plus `No Saved Sessions`
  and create/manage actions.
- [x] A packaged write-fault captured the pre-action `sessions.json` SHA, forced a
  persistence error, and confirmed both the file SHA and published profile data
  stayed unchanged.
- [x] Restoring write access and repeating the original favorite action completed
  the requested mutation. Load failures separately expose `Try Again`; mutation
  failures intentionally have no dedicated Retry button.
- [x] The exact corrupt-store fixture was moved to a unique
  `sessions.corrupt-*.json` sibling with mode `0600`, size 49 bytes, and unchanged
  SHA-256 `9d41915d5bef243cd38eaf7ca64712ee84edb1c0f5dc41a63f48f2c067d0f7b5`.
- [x] Relaunch displayed `Recovery required` and explicit `Use Recovered Profiles`
  / `Reset to Defaults` actions rather than silently overwriting or reseeding.
- [x] Selecting `Reset to Defaults` wrote a new schema-1 primary containing exactly
  `Local Terminal` and `Relay Host`; the preserved corrupt sibling remained byte
  identical.

## Accessibility, appearance, and performance

- [x] Accessibility inspection found explicit labels for launching a profile and
  for favorite/unfavorite actions; icon-only actions do not rely on color alone.
- [ ] **Retained evidence limitation:** actual auditory VoiceOver traversal was not
  performed. The Task 8 requirement was label/role inspection, which passed.
- [x] Light appearance was observed with macOS explicitly set to Light.
- [x] Dark appearance was observed after macOS was temporarily set to Dark.
- [x] With Reduce Motion temporarily enabled, the 100-profile picker opened,
  focused search, filtered to `Fixture 099`, and launched it without a functional
  regression. Source inspection confirms optional picker/tab animation is removed.
- [x] After verification, macOS was restored to Light and Reduce Motion `off`;
  System Settings accessibility state confirmed both values.
- [x] A 100-profile picker opened and was searchable without a hang. Computer-use
  click plus accessibility-tree observation took 1,186 ms; search plus refreshed
  tree observation took 490 ms. These include automation/AX overhead and are not
  represented as app-only latency.
- [x] Pure 100-profile picker projection completed in approximately 0.004 seconds
  in the focused automated test.

## Security and privacy

- [x] The version-1 JSON contained no password, OTP, passphrase, private-key
  contents, terminal input/output, clipboard data, or environment dump.
- [x] Identity-file values are path references only; key contents are neither read
  into the profile model nor encoded.
- [x] Production-source inspection found no `Logger`, `os_log`, `NSLog`, `print`,
  `debugPrint`, or `dump` call under `Sources`.
- [x] Packaged stdout/stderr contained generic SwiftUI `AttributeGraph` cycle
  diagnostics and one generic Text Services Manager line, but no profile host,
  user, identity path, working directory, password, OTP, passphrase, or private-key
  content.
- [x] Error presentation uses bounded typed categories and does not print the
  profile payload, SSH target, identity path, or terminal contents.
- [x] No SFTP, Remote File Browser, Phase 4, editor synchronization, credential
  store, remote daemon, or remote indexer code was introduced.

## Temporary-system-state and fixture cleanup

- [x] Before the authorized appearance matrix, Appearance was `Automatic` (the
  observed effective presentation was dark) and Reduce Motion was `off`.
- [x] Final state is explicitly `Light` with Reduce Motion `off`, as requested.
- [x] Evidence was recorded before cleanup, then these exact fixtures were removed:

  ```text
  /private/tmp/xmterm-phase3-manual
  /private/tmp/xmterm-phase3-empty
  /private/tmp/xmterm-phase3-100
  /private/tmp/xmterm-phase3-recovery-action
  /private/tmp/xmterm-phase3-dark
  /private/tmp/xmterm-phase3-fixture.swift
  ```

- [x] A post-cleanup existence check reported `REMOVED` for all six paths.

## Retained limitations

The full Task 8 matrix is recorded. The only unchecked rows above are honest
non-blocking limitations: packaged double-click launch was not established, actual
VoiceOver traversal was not performed, and tab rename has no Phase 3 UI. They are
not represented as passes. All specifically requested destructive, recovery,
keyboard, appearance, motion, accessibility-label, launch, persistence, security,
and cleanup checks were completed.

The exact recommended next task is **Phase 4A — Remote SFTP File Browsing**. No
Phase 4 work starts in this checklist.
