# SSH Connection and Authentication Lifecycle

- **Status:** Draft
- **Owner:** Project owner
- **Scope:** OpenSSH configuration, authentication, connection state, network loss,
  sleep/wake, reconnect, and terminal/SFTP coordination
- **Canonical requirements:** `SESS-001` through `SESS-006`, `TERM-STATE-001`

**Implementation note (Phases 2–3):** the terminal lifecycle deliberately
implements only `idle`, `starting`, local `processRunning`, `closing`, `exited`, and
`failed`. Phase 3 adds saved direct and manually entered alias launch profiles,
exact argument-safe `/usr/bin/ssh` construction, immutable launched-tab snapshots,
and non-secret versioned persistence. It does not claim the richer
resolving/connecting/authenticating/connected states described as the future
contract below. OpenSSH owns all prompts inside the PTY. Automatic config-alias
discovery/import, `ssh -G` presentation, reconnect, sleep/wake, network monitoring,
ProxyJump UI, SFTP, and authentication coordination remain deferred.

## Goal

XMterm should feel as direct and stable as a conventional SSH client while reusing
the user's trusted OpenSSH setup. It must not create a second, incompatible account
or credential system.

## SSH configuration resolution

XMterm distinguishes between **alias discovery** and **effective configuration**.

### Alias discovery

Phase 3 does not discover aliases. A future session picker may discover explicit
`Host` aliases from the user's OpenSSH configuration for presentation. Discovery
must:

- follow readable `Include` files where practical;
- ignore wildcard-only entries as direct launch items unless the user pins one;
- preserve the original alias spelling;
- tolerate unsupported directives without rejecting the entire file;
- never rewrite `~/.ssh/config` automatically.

### Effective connection settings

XMterm delegates actual SSH semantics to system OpenSSH. When it needs to inspect
resolved values, it uses:

```bash
/usr/bin/ssh -G -- alias
```

or an equivalent argument-safe invocation. It must not reconstruct ProxyJump,
Match, token expansion, canonicalization, identity selection, or host-key policy in
application code.

All process launches use argument arrays, never an interpolated shell command.

## Authentication

XMterm supports the authentication methods accepted by system OpenSSH, including:

- identities referenced by SSH config;
- `ssh-agent`;
- macOS Keychain integration provided through the user's OpenSSH configuration;
- private-key passphrase prompts;
- password authentication;
- keyboard-interactive prompts such as OTP;
- host-key first-use and changed-key handling.

Passwords, passphrases, and OTP values are never written to preferences, logs,
analytics, crash reports, or cache mappings.

XMterm must not claim that possession of a key bypasses a server policy that still
requires another factor.

## Prompt presentation

Authentication and host-verification prompts must remain visibly attached to the
connection that requested them. The user must be able to tell:

- which profile/host is asking;
- whether it is a host-key, key-passphrase, password, or keyboard-interactive prompt;
- whether typed text is hidden;
- whether cancelling will cancel only that connection.

The prompt flow must not be faked by parsing arbitrary terminal output for words
such as “password.” Prefer a PTY/trusted OpenSSH prompt path.

## Connection state model

Each terminal connection uses explicit states:

```text
idle
→ resolving
→ connecting
→ authenticating
→ connected
→ disconnecting
→ exited

connected → interrupted → reconnecting → connected
connected → failed
connecting/authenticating → cancelled
```

The UI may combine states visually, but the underlying model preserves enough
information to explain failures and allow safe retry.

## Terminal and SFTP coordination

The file browser is associated with a logical session profile, not with terminal
screen contents. Terminal and SFTP remain independently recoverable.

Desired behavior:

- opening the file browser should not require a second prompt when the selected
  backend can reuse an already authenticated SSH transport or trusted OpenSSH
  multiplexed connection;
- if reuse is unavailable, XMterm clearly shows that SFTP is opening a separate
  connection and may prompt again;
- a failed SFTP channel does not close terminal tabs;
- closing one terminal tab does not disconnect the file browser or other tabs;
- closing the last consumer may close an app-managed shared transport after a short,
  configurable idle period.

The exact multiplexing implementation requires an ADR because native shared SSH
channels and system OpenSSH processes have different security and maintenance
tradeoffs.

## Keepalive and OpenSSH options

XMterm respects `ServerAliveInterval`, `ServerAliveCountMax`, `TCPKeepAlive`,
`ConnectTimeout`, ProxyJump, ControlMaster, and related options from SSH config. It
does not silently override them.

A per-profile UI may expose convenience controls later, but any override must show
that it changes OpenSSH behavior and must be passed as a discrete argument.

## Network loss, sleep, and wake

- A sleeping Mac may cause SSH to stall or disconnect; XMterm does not falsely show
  “Connected” after process exit or confirmed transport failure.
- On wake or network-path change, XMterm observes existing processes before deciding
  that they failed.
- Automatic reconnect is opt-in for interactive terminals because reconnect creates
  a new shell and may be misleading.
- Manual Reconnect is always available for disconnected tabs.
- Reconnect keeps the old scrollback but starts a fresh process.
- Transfers interrupted by network loss enter a retryable state; they do not report
  success based on local write completion alone.

## Host-key handling

- First-use prompts show the host alias and the host/key information provided by
  OpenSSH.
- Changed-host-key failures are treated as high severity and are never converted to
  a generic reconnect loop.
- XMterm never passes options that disable strict host-key checking by default.
- The app may offer “Open known_hosts location” guidance but does not silently remove
  entries.

## Initial remote path

A profile may remember an initial remote path for the file browser. The terminal's
working directory is separate.

`Open Terminal Here` must use an argument-safe implementation and correctly quote
arbitrary remote paths. It must not construct an unescaped shell string. If a safe
startup-directory method is unavailable for the selected shell/server, XMterm opens
an ordinary terminal and offers a shell-quoted `cd` command for explicit user
execution rather than risking command injection.

## Logging and diagnostics

Diagnostics may include:

- connection state transitions;
- process exit code;
- elapsed timings;
- sanitized OpenSSH stderr;
- selected profile ID.

Diagnostics must redact:

- entered secrets;
- private-key paths when privacy mode is enabled;
- full internal hostnames and usernames in exported support bundles unless the user
  explicitly includes them;
- environment variables and command lines containing secrets.

The Phase 3 profile document is not a diagnostic record. It may contain explicit
direct host/user metadata and an optional identity-file path reference because
those are user-authored launch settings, but it has no credential-value field and
is never emitted wholesale to logs. Path checks occur only on save or launch and
field-specific errors do not include the checked path. Exact Phase 3 stored-data
and log-inspection evidence is in
[`../audits/0005-phase-3-session-manager-evidence.md`](../audits/0005-phase-3-session-manager-evidence.md).

## Minimum manual verification

- key-only login;
- encrypted key with passphrase;
- password login;
- keyboard-interactive OTP;
- first-use host key;
- changed host key;
- ProxyJump alias;
- `Include` and wildcard SSH config behavior;
- cancel during authentication;
- network drop, sleep/wake, and reconnect;
- terminal remains usable during SFTP reconnect;
- SFTP does not re-prompt when trusted connection reuse is available.
