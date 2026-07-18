# Security Policy and Design Notes

## Authentication

XMterm must prefer the user's existing OpenSSH configuration and authentication chain. Private keys remain in their original locations. Passwords and OTP values are never persisted by XMterm.

## Secrets

Never commit or log:

- private keys;
- passphrases, passwords, or OTP seeds/codes;
- real hostnames, usernames, IP addresses, or internal filesystem paths from user environments;
- environment dumps containing credentials.

Use fixtures such as `example-host`, `developer`, and `/remote/project` in tests and documentation.

### Declared Phase 2 endpoint exception

Phase 2 is explicitly scoped to the public relay declaration
`allen921103@140.109.226.155:54426`, so that username, address, and port are allowed
only in the fixed production launch specification, its exact-contract tests, and
Phase 2 documentation. This narrow exception does not authorize committing any
internal-node hostname, private address, key path, credential, OTP, prompt content,
or unrelated user-environment identifier.

## Host verification

Host-key verification must not be bypassed silently. Any first-connect or changed-host-key prompt must be clear and must come from a trusted SSH flow.

## Local cache

- Store under the app's user-scoped Application Support or Caches directory.
- Use user-only permissions.
- Keep a mapping database separate from file content.
- Provide a clear-cache action.
- Never execute downloaded files automatically.

## Reporting a vulnerability

Until a private reporting channel exists, do not publish exploit details in a public issue. Contact the project owner privately.


## Terminal-originated actions

Remote output is untrusted. XMterm must not allow terminal escape sequences to open
URLs, execute local commands, read the clipboard, or write unlimited clipboard data
without an explicit user action or permission. OSC 52 reads are denied by default.

Phase 1 applies a bounded streaming filter before terminal-engine parsing. It drops
OSC, DCS, APC, PM, and SOS control strings, including OSC 52, and blocks CSI window
operations, pixel mouse mode 1016, terminal graphics, and known engine diagnostic
paths. Dynamic terminal titles, links, bells, graphics, and terminal-originated
clipboard operations are therefore intentionally unavailable rather than silently
trusted.

## Process and path safety

Launch `/usr/bin/ssh`, editors, and helpers with structured argument arrays. Never
build an interpolated shell command from a hostname, username, local path, or remote
path. `Open Terminal Here` and copied shell references must use tested shell quoting
and must not execute automatically.

## Transfer integrity

Editor auto-sync and Replace operations should upload to a temporary file and safely
finalize in the destination directory where supported. A file is not marked Synced
until the server confirms the final destination. Preserve executable permission bits
and do not replace symlinks accidentally.

## Diagnostics

Diagnostic exports exclude terminal contents, remote file contents, entered secrets,
and full internal identifiers by default. Debug logs are opt-in, size-bounded, and
locally rotated.

The Phase 1 terminal does not log PTY input or output. User-facing failures are
sanitized into typed launch, read, write, resize, and exit states; raw shell content
and environment dumps are not included.

## Phase 2 SSH implementation notes

- The relay launches through `execve` as `/usr/bin/ssh` plus three discrete,
  ordered arguments. No shell wrapper, interpolation, remote command, or automatic
  second hop exists.
- The inherited environment preserves normal OpenSSH agent/config behavior, but it
  is never logged or exported. XMterm adds no password, OTP, passphrase, or key
  field and stores none of those values.
- `StrictHostKeyChecking` and `UserKnownHostsFile` are not overridden. First-use,
  changed-key, authentication, and network diagnostics remain visible in the PTY.
- SSH output crosses the unchanged bounded Phase 1 security filter. OSC 52 and the
  other denied host-affecting sequences receive no SSH-specific bypass.
- Terminal input and prompt contents are not logged, parsed, persisted, sent to
  telemetry, or used to infer connection state.

## Phase 3 saved-session implementation notes

- The version-1 profile document is stored at the user-scoped Foundation-resolved
  `Application Support/XMterm/sessions.json` location. Its directory is created
  with mode `0700` and its primary and temporary files use mode `0600`.
- Stored fields are non-secret launch metadata: stable ID, display name, favorite,
  dates/order, local shell and working-directory references, or SSH mode, host,
  port, user, alias, and an optional identity-file **path reference**. The schema
  has no password, OTP, passphrase, private-key-content, terminal-content,
  clipboard, or environment field.
- Profile fields receive strict structural validation before persistence or
  launch. Host, user, and alias values cannot become option-shaped/interpolated
  shell input; launches continue to use executable paths plus discrete argument
  arrays. System OpenSSH retains host-key and authentication authority.
- Draft typing performs no existence or executable check. Potentially sensitive
  filesystem checks occur only at explicit save and launch boundaries, and error
  presentation identifies the affected field without logging its path value.
- Writes use a same-directory temporary file and atomic replacement. The store
  publishes a new immutable collection only after persistence succeeds, so a
  failed write leaves observable profile data unchanged. Corrupt and unsupported
  source bytes are preserved for explicit recovery instead of being silently
  overwritten.
- The JSON is plaintext connection metadata protected by user-only filesystem
  permissions, not encryption; another process running as the same macOS user can
  read it. Replacement is namespace-atomic, but no explicit file/directory `fsync`
  or symlink/TOCTOU hardening is claimed, so power-loss durability and a hostile
  same-user filesystem threat model remain outside the Phase 3 evidence.
- Preserved `sessions.corrupt-*` evidence files are intentionally retained and are
  not automatically aged or deleted; crash-left `sessions.tmp-*` siblings also
  have no startup scavenger. Both remain mode `0600`, but users do not yet have a
  cleanup control for this historical metadata.

The Phase 3 security review found no Critical, High, or Medium finding in the saved-profile,
launch-specification, or user-workflow change. That scoped result is not a
substitute for Developer ID/hardened-runtime/notarization assessment or future
SFTP and remote-path threat modeling. Exact source, packaged-app, stored-data, and
log-inspection evidence and known limitations are in
[`docs/audits/0005-phase-3-session-manager-evidence.md`](docs/audits/0005-phase-3-session-manager-evidence.md).

## Phase 4A remote-workspace implementation notes

- Remote filenames and attributes are treated as untrusted raw bytes. Identity is
  never derived from display text; invalid or control bytes are escaped for
  display only. Nothing evaluates a remote name, builds a shell command from it,
  or follows a symlink during listing.
- The shipping remote provider is `OpenSSHSFTPRemoteFileProvider`. System OpenSSH
  retains authentication, configuration, cryptography, and host-key authority;
  XMterm implements only bounded binary SFTP v3 framing for read-only listing.
  Human `sftp`/`ls` output is never parsed, no SSH dependency was added, and no
  `StrictHostKeyChecking` override exists anywhere in the source.
- Provider and presentation mode are bound by `RemoteProviderComposition`, whose
  raw pairing is private. Public clients can construct only the unavailable
  composition; package-only test providers carry the explicit `.packageTest`
  mode, and the simulated mode accepts only the typed in-memory developer
  provider. No arbitrary provider can claim production or simulated trust. ADR
  0007 introduces the only production constructor, which accepts the concrete
  reviewed OpenSSH provider.
- Copy actions write exactly one plain-text pasteboard item, append no Return,
  and are disabled when the raw path has no lossless text representation.
  Clipboard contents, terminal contents, provider streams, and remote paths are
  never logged; user-facing errors use bounded, escaped typed messages.
- Every provider request is owned by its runtime, bounded (32 directories,
  20,000 cached entries, 10,000 entries and 32 MiB per response, 32 KiB paths,
  4 KiB components, two concurrent requests), and cancelled on close. There is
  no polling, recursive enumeration, prefetch, or per-row task creation.
- The subsystem writer is readiness-driven and nonblocking, request and diagnostic
  data are bounded, request-ID mismatch/desynchronization is fatal, and runtime
  close uses bounded signal escalation plus retained process reaping.
- Real Relay acceptance authenticated through public-key authentication using a
  configured OpenSSH key. No agent identity or app-owned `ControlMaster` was in
  use, and normal known-host policy succeeded without a bypass. No Keychain use is
  claimed.
- The simulated developer fixture activates only on the exact
  `XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` environment value, contains only
  synthetic `/simulated` data, and labels every listing simulated. Unrecognized
  values fail closed. The environment gate is compile-time
  disabled in release builds; an actual packaged release launch with the value
  set retained the real production Relay listing and displayed no simulated badge.
