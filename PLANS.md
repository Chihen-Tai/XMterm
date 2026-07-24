# XMterm Plans

This is the high-level project board. Detailed implementation work belongs in
`docs/exec-plans/`.

## Completed — repository bootstrap and Phase 1 local terminal

- [x] Define product scope and non-goals.
- [x] Define initial architecture and agent rules.
- [x] Add a minimal native macOS shell.
- [x] Add deterministic repository verification.
- [x] Define the detailed interaction contract for normal macOS behavior.
- [x] Add terminal, remote file, session/tab, and editor-sync UX design documents.
- [x] Add an interaction parity review checklist.
- [x] Complete a second-pass gap audit for terminal protocol behavior, SSH lifecycle,
  transfer integrity, editor-sync safety, and native macOS behavior.
- [x] Add a terminal-specific acceptance checklist.
- [x] Build, stage, ad-hoc sign, and launch the native app on the target Mac using
  SwiftPM and Command Line Tools. Full Xcode/XCUITest remains unavailable on the
  validation host.
- [x] Select SwiftTerm 1.14.0 and implement the XMterm-owned PTY/process boundary;
  record license, compatibility, Unicode, resize, selection, output-security, and
  accessibility evidence in ADR 0003 and the Phase 1 audit.
- [x] Make local close confirmation foreground-job-aware with PTY process-group
  semantics; idle, exited, failed, and closed local tabs close immediately.
- [ ] Decide SSH/SFTP connection reuse strategy through an ADR.
- [ ] Decide app sandbox/notarization/distribution constraints through an ADR.

Completed Phase 1 plan:
[`docs/exec-plans/0003-native-local-terminal-vertical-slice.md`](docs/exec-plans/0003-native-local-terminal-vertical-slice.md)

Local close-behavior plan:
[`docs/exec-plans/0004-local-terminal-close-confirmation.md`](docs/exec-plans/0004-local-terminal-close-confirmation.md)

Evidence:
[`docs/audits/0002-phase-1-local-terminal-evidence.md`](docs/audits/0002-phase-1-local-terminal-evidence.md)

## Completed — Phase 2 fixed-relay SSH terminal

- [x] Add a narrow SSH launch model that executes `/usr/bin/ssh` directly through
  `PTYProcessController`; do not add SFTP or remote files in that change.
- [x] Use the exact fixed relay endpoint and preserve OpenSSH's in-terminal
  host-key, agent, Keychain, password, passphrase, and keyboard-interactive flows.
- [x] Model only honest local SSH process state; do not claim network connection or
  authentication success and do not parse prompts.
- [x] Reuse the existing terminal input, selection, paste, resize, scrollback,
  lifecycle, close-confirmation, and output-security surfaces.
- [x] Add deterministic launch/session/workspace fixtures; automated tests do not
  contact the real relay.

Execution plan:
[`docs/exec-plans/0005-phase-2-ssh-terminal-integration.md`](docs/exec-plans/0005-phase-2-ssh-terminal-integration.md)

Acceptance and evidence:
[`docs/checklists/ssh-terminal-acceptance.md`](docs/checklists/ssh-terminal-acceptance.md),
[`docs/audits/0003-phase-2-ssh-terminal-evidence.md`](docs/audits/0003-phase-2-ssh-terminal-evidence.md)

Still deferred from the broader terminal roadmap: alias discovery/`ssh -G`,
sleep/wake, reconnect, ProxyJump UI, automatic second hops, tab reorder/rename/duplicate,
block selection, selected-text drag export, result-count search UI, clear
scrollback/reset, configurable Option mapping, dynamic titles, links, bell,
terminal graphics, full terminal VoiceOver, and settings persistence.

## Completed implementation — Phase 2 browser-like tab-strip polish

- [x] Add a pure sizing policy with exact 180-point preferred, 120-point minimum,
  and 240-point maximum bounds; keep non-overflow viewports content-sized, shrink
  tabs equally, and switch to horizontal overflow at the minimum threshold.
- [x] Give the workspace header one width owner, render tabs as one stable-ID lazy
  sequence, keep the existing local/relay `+` menu pinned outside the viewport,
  and preserve an independent toolbar region with 8-point separation.
- [x] Request selected-tab reveal after creation, activation, replacement selection
  on close, and resize; use one final scroll after a 16 ms initial/tab-state settle
  or a 75 ms cancellation-coalesced viewport debounce, and remove the optional
  tab-state animation when Reduce Motion is enabled.
- [x] Preserve terminal/session/process ownership and the Phase 1/2 local/relay
  actions, close policy, focus routing, and isolation paths.
- [x] Add deterministic sizing, threshold, overflow, toolbar-boundary, and reveal-
  target/scheduling tests; the final repository gate passes 143 tests in 23 suites,
  and clean debug/release warnings-as-errors builds pass.

Execution plan:
[`docs/exec-plans/0006-phase-2-tab-strip-polish.md`](docs/exec-plans/0006-phase-2-tab-strip-polish.md)

Automated and rendered evidence:
[`docs/audits/0004-phase-2-tab-strip-polish-evidence.md`](docs/audits/0004-phase-2-tab-strip-polish-evidence.md)

The final independent re-review is READY for the source/automated implementation
slice. The staged app also passed the core content-sized/pinned-`+`, equal-shrink,
horizontal-overflow, selected-reveal, close, resize, menu, and AX-tree inspection.
Physical trackpad momentum, long-title rendering, full keyboard traversal, actual
VoiceOver, Reduce Motion, relay invocation, and quantitative performance inspection
remain explicitly open. Those evidence gaps did not expand the scope of the
historical Phase 2 polish slice.

## Completed — Phase 3 Native Session Manager

- [x] Add immutable local, direct-host SSH, and manually entered SSH-config-alias
  profiles with stable identity and non-secret metadata only.
- [x] Persist a schema-versioned profile collection through same-directory staging
  and atomic replacement with user-only permissions, one-time defaults, durable
  empty state, corruption preservation, and explicit recovery.
- [x] Preserve persist-before-publish semantics so failed writes leave the
  previously published collection unchanged.
- [x] Add a searchable keyboard-accessible picker with Recent, Favorites, SSH, and
  Local sections; keep each profile row unique and restore focus after dismissal.
- [x] Make the pinned `+` control open the picker without launching; make
  `Command-T` launch the first saved login-shell profile or fall back to the picker.
- [x] Add native create/edit/duplicate/favorite/delete flows with isolated drafts,
  inline structural errors, save/launch-boundary path validation, confirmation,
  loading/empty/error/recovery states, and persistence retry by repeating the
  original mutation after its cause is repaired.
- [x] Launch each selected profile through an immutable specification with distinct
  tab/session identity and retained profile provenance, so later profile or tab
  edits remain isolated.
- [x] Preserve the exact built-in `Relay Host` launch as `/usr/bin/ssh`, `-p`,
  `54426`, `allen921103@140.109.226.155`, and preserve normal login-shell launch for
  `Local Terminal`.

Execution plan:
[`docs/exec-plans/0007-phase-3-native-session-manager.md`](docs/exec-plans/0007-phase-3-native-session-manager.md)

Acceptance and evidence:
[`docs/checklists/session-manager-acceptance.md`](docs/checklists/session-manager-acceptance.md),
[`docs/audits/0005-phase-3-session-manager-evidence.md`](docs/audits/0005-phase-3-session-manager-evidence.md)

The Phase 3 implementation and Task 8 closeout are complete for the locked scope.
The audit is the source of truth for packaged-app acceptance, quantitative
evidence, and retained limitations; this status does not complete requirements
outside Phase 3. Automatic alias discovery/import, `ssh -G` presentation, reconnect,
sleep/wake recovery, ProxyJump editing, automatic second hops, SFTP, remote files,
editor sync, distribution signing, and notarization remain deferred.

## Complete — Phase 4A — Remote Workspace Foundation

- [x] Lock the Phase 4A contract: `SESS-011`, `FILE-WORKSPACE-001`, `FILE-NAV-002`,
  `FILE-CACHE-001`, `FILE-STATE-001`, and `FILE-COPY-001` in `INTERACTIONS.md`,
  the remote-workspace design, ADR 0006, ADR 0007, and Execution Plan 0008.
- [x] Add the dependency-free `XMtermRemote` target with raw-byte `RemotePath`
  identity, safe escaped display, entries with honest optional metadata,
  deterministic ordering, bounded listings, and typed `RemoteFileError` values.
- [x] Define the sendable `RemoteFileProvider` boundary with a deterministic
  `InMemoryRemoteFileProvider` and the honest shipping
  `UnavailableRemoteFileProvider`.
- [x] Implement the bounded per-runtime LRU directory cache and the `@MainActor`
  observable workspace state machine with success-only navigation publication,
  reciprocal history, refresh, lazy expansion, generation-guarded stale-result
  rejection, and settled close.
- [x] Migrate the window registry to session-centric `RuntimeSession` aggregates
  owning the retained terminal and an optional workspace as isolated siblings
  with aggregate close settlement.
- [x] Implement the immutable presentation/action policies, exact-owner focused
  actions, and the lossless single-item plain-text pasteboard adapter.
- [x] Add the native Remote Workspace sidebar (states, navigation, breadcrumbs,
  single selection, lazy disclosure, context/menu copy actions, Command-Down/Up),
  keep Saved Sessions compact above it, and preserve terminal identity and
  command routing.
- [x] Pass the 1,000-entry model/order/publication performance gate (20.84 ms p90
  against the 100 ms budget) and the full repository verifier.
- [x] Add the explicit env-gated simulated developer fixture for packaged
  foundation verification; release builds ignore it and retain production.
- [x] Accept ADR 0007 and ship the reviewed system-OpenSSH subsystem transport,
  bounded read-only SFTP v3 codec, concrete production provider, and real Relay
  Host listing. No human `ls` parsing or external dependency was added.

Status: **COMPLETE** — the foundation, production read-only transport, real Relay
acceptance, lifecycle isolation, testing, performance, security review, and
packaged debug/release gates passed.

Exact recommended next task: **Phase 4B — Remote File Mutations and Transfers.**

## In progress — Phase 4B — Remote File Mutations and Transfers

Design, transport ADR, execution plan, and acceptance checklist are locked in. Task
3 architecture-contract repair is complete, and Task 4 production streaming workers
and mutations are the active next implementation gate:
[`docs/design-docs/phase-4b-remote-file-mutations-and-transfers.md`](docs/design-docs/phase-4b-remote-file-mutations-and-transfers.md),
[`docs/decisions/0008-remote-file-mutation-and-transfer-transport.md`](docs/decisions/0008-remote-file-mutation-and-transfer-transport.md),
[`docs/exec-plans/0010-phase-4b-remote-file-mutations-and-transfers.md`](docs/exec-plans/0010-phase-4b-remote-file-mutations-and-transfers.md), and
[`docs/checklists/remote-file-mutations-and-transfers-acceptance.md`](docs/checklists/remote-file-mutations-and-transfers-acceptance.md).

- [x] Complete Task 3A request, endpoint, snapshot, retry, checkpoint, and exact
  bounds contracts without marking production execution implemented.
- [x] Complete Task 3B dedicated endpoint-provider/listing capability and
  per-session SSH workspace transfer ownership; local runtimes own none.
- [x] Complete Task 3C engine/coordinator migration, retry/conflict behavior,
  tests, review, and closeout before Task 4 production workers begin.
- [ ] Implement Task 4 production streaming workers and structured mutations. This
  is the next/in-progress Phase 4B task.
- [ ] Implement Task 5 recursive transfer, batch operations, and collisions.
  Before Task 5 acceptance, repair the Medium debt that `RemoteTransferItemFailure`
  must retain descendant-capable identity for recursive/batch failures.
- [ ] Implement Task 6 actual multi-selection UI plus Copy/Cut/Paste and action
  policy before any drag-and-drop acceptance.
- [ ] Implement Task 7 remote and Finder drag-and-drop on top of proven
  multi-selection and transfer execution.
- [ ] Complete Task 8 UX/accessibility/lifecycle/performance hardening.
- [ ] Complete Task 9 security, packaged acceptance, real Relay acceptance, and
  closeout from direct plan/checklist evidence only.

## Then — local editor auto-sync

- [ ] Cache mapping for remote documents.
- [ ] Configurable editor launcher, starting with VS Code.
- [ ] Directory-based file watcher with atomic-save handling and debounce.
- [ ] Save-triggered upload with revision coalescing and visible sync status.
- [ ] Remote modification conflict handling and Open Both comparison flow.
- [ ] Multiple simultaneous mappings and quit-with-unsynced-changes handling.
- [ ] Add offline pending upload, remote rename/delete, symlink-safe editing,
  executable-mode preservation, and custom editor launch failure handling.

## Later

Split panes, tunnel manager, snippets, session import/export, large-log viewer,
optional tmux integration, additional local editors, and advanced terminal profile
customization.
