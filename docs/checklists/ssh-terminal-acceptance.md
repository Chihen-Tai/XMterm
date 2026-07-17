# Phase 2 SSH Terminal Acceptance Checklist

- **Target:** `/usr/bin/ssh -p 54426 allen921103@140.109.226.155`
- **Date:** 2026-07-16
- **Automated status:** Passed
- **Real relay status:** Partially performed; only checked rows are claimed
- **Phase 3 saved-profile regression:** Passed for the locked Phase 3 scope;
  packaged-app details and limitations are recorded separately

`[x]` means direct automated evidence exists. An unchecked row states **Not
performed**, **Not encountered**, **Deferred**, **Blocked**, or **Not applicable**;
it must not be inferred from a nearby passing test. Exact commands and results are
in [`../audits/0003-phase-2-ssh-terminal-evidence.md`](../audits/0003-phase-2-ssh-terminal-evidence.md).

## Automated launch and architecture

- [x] Production executable path is exactly `/usr/bin/ssh`.
- [x] Ordered arguments are exactly `-p`, `54426`, and
  `allen921103@140.109.226.155`.
- [x] Executable and arguments remain separate; no shell wrapper, command string,
  remote command, ProxyJump, or automatic second hop exists.
- [x] The SSH tab uses the shared `TerminalSession`, `PTYProcessController`,
  `CXMtermPTY` `forkpty`/`execve` shim, SwiftTerm view, security filter, bounded
  queues, resize path, and cleanup path.
- [x] Automated tests use controlled process actors and do not contact the relay,
  change `known_hosts`, read Keychain, or require credentials.

## Automated tab, state, and close behavior

- [x] Phase 2 wired Plus/File actions to fixed-relay creation. Phase 3 preserves the
  exact relay process contract through the saved Relay Host profile; `Command-T`
  chooses the first saved login-shell profile and Control input remains remote.
- [x] Local and SSH tabs coexist with stable, independent IDs, retained sessions,
  selection, lifecycle, and initial `Relay Host` title.
- [x] State is limited to idle, starting, local process running, closing, exact
  exit status/signal, and typed failure; presentation never says Connected.
- [x] Raw final output reaches the retained terminal before nonzero exit is shown,
  and input is disabled after exit.
- [x] Normal, nonzero, and signal SSH exits remain exact.
- [x] Every live SSH process requires the exact SSH-specific close confirmation;
  local foreground-process-group probing is not used.
- [x] Cancel preserves the SSH tab/session; Close uses normal PTY/process cleanup.
- [x] Exited and failed SSH tabs close immediately; closing SSH leaves local tabs
  intact; aggregate window/quit prompts count SSH separately.
- [x] Existing real-PTY tests cover final drain, descriptor closure, escalation,
  direct-child reaping, independent children, and no zombies for the shared
  production controller.

## Automated terminal and security regressions

- [x] SSH input and resize use the same bounded routes as local terminals.
- [x] Phase 1 exact Control mappings, Command shortcut isolation, multiline paste
  confirmation, selection/copy, scrollback, find, Unicode byte routing, and resize
  suites remain green.
- [x] `SSH_AUTH_SOCK`, `SHELL`, locale/config environment, `TERM`, and
  `TERM_PROGRAM` reach OpenSSH without setting `SHELL=/usr/bin/ssh`.
- [x] No password, OTP, passphrase, key, `BatchMode`, `StrictHostKeyChecking=no`,
  or `UserKnownHostsFile=/dev/null` launch argument is added.
- [x] Terminal input/output, prompt contents, environment dumps, and clipboard
  contents are not logged; the unchanged output filter continues to deny OSC 52
  and other prohibited host effects.

## Staged native UI smoke

- [x] The Phase 2 staged app opened its plus menu with `New Local Terminal` and
  `Connect to Relay Host`. Phase 3 replaces that menu with the searchable saved-
  session picker while preserving the pinned control and exact Relay Host launch.
- [x] The Phase 3 File menu exposes New Terminal, Choose Session, and Manage
  Sessions; `Command-T` launches the first saved login-shell profile and actions
  rebind after window workspace recreation.
- [x] Relay status/help/accessibility text is neutral in the accessibility tree,
  and the rendered close alert has title `Close this SSH terminal?`, buttons
  Cancel and Close, and the documented body.
- [ ] **Not performed yet:** exiting a staged SSH fixture leaves selectable,
  searchable scrollback and closes without a prompt.

## Real relay manual matrix

Only checked rows below were performed. Unchecked rows state the exact partial,
unencountered, or unperformed boundary; no credential-flow claim is inferred.

- [x] Relay tab opened the real command and reached an interactive remote shell.
- [ ] **Partially observed:** login completed without an interactive credential
  prompt, but the run did not distinguish key file, `ssh-agent`, or another
  existing OpenSSH mechanism.
- [ ] **Not encountered:** macOS Keychain behavior.
- [ ] **Not encountered:** first-use or changed host-key prompt.
- [ ] **Not encountered:** password prompt.
- [ ] **Not encountered:** OTP/keyboard-interactive prompt.
- [ ] **Not encountered:** private-key passphrase prompt.
- [ ] **Partial:** live `stty size` returned `47 143`; changing the window size and
  confirming a second value was not performed.
- [ ] **Not performed:** `Control-C`, `Control-Z`, `Control-V`, and `Control-W` on
  the remote side.
- [ ] **Not performed:** `Command-C`, `Command-V`, drag selection, scrollback, and
  terminal search against relay output.
- [ ] **Not performed:** Traditional Chinese committed input and emoji remotely.
- [ ] **Not performed:** remote `vim` and `less` behavior.
- [ ] **Not performed:** manual `ssh g207` second hop and return.
- [x] Real active-SSH close confirmation, Cancel, confirmed close, local-tab
  isolation, and absence of a matching SSH process after close were observed.
- [ ] **Not performed:** naturally exited real-tab close and privacy-safe log
  inspection.

## Deferred and not applicable to Phase 2

- [x] **Implemented in Phase 3:** saved local/direct-SSH/manual-alias profiles,
  picker search/grouping, profile editing/duplicate/delete/favorite, immutable
  launched-tab snapshots, and versioned local persistence.
- [ ] **Deferred beyond Phase 3:** automatic alias discovery/import, `ssh -G`
  presentation, and SSH config editing.
- [ ] **Deferred:** reconnect/automatic reconnect, sleep/wake, network monitoring,
  and remote-idle detection.
- [ ] **Deferred:** ProxyJump UI, direct `g207`/`g204`/`g209` tabs, tunnels, tmux,
  and shell integration.
- [ ] **Not applicable:** SFTP, remote files, editor sync, and terminal/SFTP
  authentication coordination were not added.

## Phase 3 saved Relay Host evidence

- [x] The seeded Relay Host profile retains exactly `/usr/bin/ssh`, followed by
  `-p`, `54426`, and `allen921103@140.109.226.155` as discrete ordered arguments.
- [x] Direct and alias profile launches add no shell wrapper, interpolated command,
  automatic second hop, host-key bypass, password, OTP, passphrase, or private-key
  contents.
- [x] A launched SSH tab retains source-profile provenance and an immutable copied
  specification. Editing or deleting the saved profile cannot alter or close it,
  and a local tab can coexist independently.
- [x] The packaged Phase 3 picker launched Relay Host into an SSH terminal; exact
  process, restart, persistence, stored-data, and log evidence is in
  [`session-manager-acceptance.md`](session-manager-acceptance.md) and
  [`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).
- [ ] **Still not claimed:** unencountered password/OTP/passphrase/Keychain/changed-
  host-key flows, ProxyJump UI, reconnect, sleep/wake, network monitoring, and
  automatic alias discovery.
- [ ] **Not introduced:** SFTP, Remote File Browser, transfers, and editor sync.
