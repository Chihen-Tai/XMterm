# Production SFTP Transport Design

- **Status:** Accepted, implemented, and production verified
- **Date:** 2026-07-18
- **Owner:** Project owner
- **Decision scope:** Phase 4A read-only production `RemoteFileProvider`, system
  OpenSSH subsystem process, narrow SFTP v3 codec, lifecycle, and Relay acceptance
- **Canonical requirements:** `SESS-004`, `SESS-006`, `SESS-011`, `APP-007`,
  `APP-008`, `FILE-WORKSPACE-001`, `FILE-NAV-002`, `FILE-CACHE-001`,
  `FILE-STATE-001`, `FILE-COPY-001`, `FILE-LIST-001`, `FILE-META-001`,
  `FILE-PERF-001`, and the read-only portion of `FILE-XFER-004`

## Goal

Replace the shipping unavailable workspace provider for supported SSH sessions
with a production read-only provider while preserving system OpenSSH security,
exact remote path identity, session isolation, bounded resource use, and the
existing terminal path.

The terminal continues to own its existing interactive PTY-backed
`/usr/bin/ssh` process. The workspace owns a physically independent,
noninteractive OpenSSH subsystem process. Terminal input, prompt text, hostname,
title, and manually entered nested SSH commands never retarget the workspace.

## Selected architecture

One production provider actor per SSH `RuntimeSession` lazily owns:

```text
RemoteWorkspace
  -> OpenSSHSFTPRemoteFileProvider actor
     -> OpenSSHSFTPTransport
        -> Foundation Process: /usr/bin/ssh ... sftp
        -> bounded Swift SFTP v3 codec
```

System OpenSSH owns SSH transport, configuration, proxying, key and agent use,
Keychain integration where configured, host-key verification, and cryptography.
XMterm implements only the minimum SFTP v3 binary adapter required by the
existing read-only provider contract. It adds no third-party dependency.

Direct targets use separated arguments in this order:

```text
/usr/bin/ssh -T -o BatchMode=yes [-i IDENTITY] -s -p PORT USER@HOST sftp
```

Config aliases use:

```text
/usr/bin/ssh -T -o BatchMode=yes -s ALIAS sftp
```

No shell, remote command string, human `sftp` client output, `ls` output, or
terminal output participates. Existing user-configured OpenSSH connection sharing
may be used naturally; XMterm does not own a `ControlMaster` lifecycle.

## Authentication and host-key boundary

`BatchMode=yes` is mandatory because stdin/stdout are the SFTP binary channel.
Supported authentication is limited to noninteractive mechanisms already usable
by system OpenSSH, such as an agent, an already-unlocked configured key, supported
Keychain-backed key use, or existing configured connection sharing. Password,
passphrase, keyboard-interactive OTP, and first-time interactive host-key
confirmation fail honestly.

XMterm never adds `StrictHostKeyChecking=no`, changes `UserKnownHostsFile`, accepts
unknown host keys, stores credentials, or logs process arguments, paths, stderr,
terminal data, or environment values. Stderr is a separate bounded diagnostic
channel. Conservative typed classification may recognize safely identifiable
OpenSSH categories, but raw or unbounded diagnostics never reach UI or logs.

## Codec scope

The codec sends only:

- `SSH_FXP_INIT` for version 3;
- `SSH_FXP_REALPATH`;
- `SSH_FXP_OPENDIR`;
- sequential `SSH_FXP_READDIR`;
- `SSH_FXP_CLOSE`.

It accepts only the corresponding `SSH_FXP_VERSION`, `SSH_FXP_STATUS`,
`SSH_FXP_HANDLE`, `SSH_FXP_NAME`, and, where a response permits it,
`SSH_FXP_ATTRS` packet shapes. It parses structured `ATTRS`, preserves raw
`filename` bytes, and consumes but ignores the unspecified human `longname`.
Unknown packet types, unsupported attribute flags, invalid lengths, trailing data,
unexpected responses, and mismatched request IDs are protocol errors.

Only SFTP version 3 is accepted. Extension name/data pairs are bounded, consumed,
and ignored. Requests are serialized, so exactly one request ID is outstanding.
IDs advance monotonically modulo `UInt32` without using zero for ordinary
requests. A response must carry the exact outstanding ID.

`REALPATH(".")` must return one absolute raw path. `READDIR` names are immediate
raw components; `.` and `..` are omitted. Slashes, NUL, empty components, and
components above the bound are rejected. Child paths are constructed from the
trusted parent plus the raw returned component, never from `longname`.

SFTP attributes remain optional. Size and modification time are published only
when present. POSIX permission bits identify directory, regular-file, and symlink
kinds; unsupported/unknown kinds remain `.other`. SFTP v3 directory entries do
not provide a symlink target, so target metadata remains absent.

## Bounds

All validation occurs before allocation or publication:

| Resource | Limit |
|---|---:|
| Individual SFTP packet | 1 MiB |
| Entries in one directory | 10,000 |
| Cumulative encoded listing payload | 32 MiB |
| Absolute raw path | 32 KiB |
| Raw filename component | 4 KiB |
| Opaque handle | 256 bytes |
| Raw symlink target, if later received within approved scope | 32 KiB |
| Bounded diagnostic buffer | 64 KiB |

Counts and byte arithmetic use checked conversions. Limit excess is an explicit
typed failure, never silent truncation. Handshake, request, and close operations
have finite timeouts. The implementation performs no recursive crawl, polling,
per-row process, or per-row metadata request.

## Concurrency, cancellation, and lifecycle

The provider actor serializes protocol work. Workspace-level task limits remain in
force, while the transport permits one outstanding SFTP request at a time. A
single process may serve successive resolve/list calls for its owning runtime and
reconnects lazily only after a prior connection has become unusable.

Cancellation before a request is sent returns cancellation without affecting a
healthy connection. Cancellation, timeout, stream EOF, process exit, write/read
failure, malformed response, unexpected response, or request-ID mismatch after
bytes may be in flight makes stream synchronization unknowable. The transport is
then fatal: close stdin and handles where possible, terminate and reap the process
with bounded escalation, discard buffered protocol state, and reconnect lazily on
the next operation. No later request reuses a possibly desynchronized stream.

Provider `close()` is idempotent, rejects new work, cancels outstanding work,
settles the process, and never signals or closes the sibling terminal process.
Closing one runtime cannot affect another provider or terminal.

## Error mapping

The provider exposes bounded, stable categories for authentication required,
host-key verification failure when safely identifiable, unsupported interactive
authentication, permission denied, not found, unsupported server/protocol,
cancelled, malformed response, transport unavailable, timeout, limit exceeded,
and unknown transport failure. Remote status messages and OpenSSH stderr are
diagnostic input only; they are never copied verbatim into user-visible errors.

## Runtime composition

The application constructs a production provider only from a validated immutable
SSH `SessionLaunchSpecification`. Local launch specifications receive no
workspace. The trusted composition boundary must make `.production` constructible
only with the concrete production provider, while simulated mode remains debug-
only and release remains fail-closed even when the fixture environment variable is
set.

The workspace target is the launched direct target or config alias snapshot. If
the user later enters `ssh g207` inside the terminal, only the terminal process is
affected; the independent provider remains attached to that immutable launch
target.

## Verification and acceptance

Implementation is test-first: codec primitives/framing, handshake, IDs,
structured responses/attrs, malformed input and bounds, raw names, exact argv,
process lifecycle, cancellation/desynchronization, local `sftp-server`
integration, provider/composition/runtime integration, and existing regressions.

The local integration runs the same codec against `/usr/libexec/sftp-server`
without SSH. Completion additionally requires warnings-as-errors debug/release
builds, the full verifier, packaged debug/release checks, security review, and real
Relay acceptance at `allen921103@140.109.226.155:54426` using an existing
noninteractive authentication mechanism. The exact successful mechanism must be
recorded. Failure of secure noninteractive Relay authentication leaves Phase 4A
Partial; security is not weakened.

## Explicit deferrals

- every mutation, transfer, multi/range selection, remote-object clipboard,
  drag/drop, collision, upload, and download surface (Phase 4B);
- terminal cwd/host tracking, OSC 7, shell integration, automatic ProxyJump or
  second-hop retargeting (Phase 5);
- external-editor launch, file watching, save upload, and editor sync (Phase 6);
- interactive authentication bridging, reconnect UI, and app-owned multiplexing.

## Acceptance criteria

- Shipping supported SSH sessions use the real read-only provider; local sessions
  own no workspace transport and release cannot enable simulated data.
- System OpenSSH retains SSH/security authority and uses separated noninteractive
  subsystem arguments with normal host-key verification.
- The bounded codec negotiates v3, preserves raw identity, validates request IDs,
  lists with `REALPATH`/`OPENDIR`/`READDIR`/`CLOSE`, and rejects malformed input.
- Cancellation, timeout, desynchronization, close, and runtime isolation settle
  without an orphan process or impact on the terminal sibling.
- Local server, packaged app, and real Relay evidence pass; the authentication
  mechanism and manual nested-SSH boundary are recorded.
- ADR 0007 is Accepted only after all production gates pass. Phase 4A remains
  Partial otherwise.

## Acceptance result

All gates passed on 2026-07-18. Packaged debug and signed release builds listed the
real Relay, release ignored simulated injection, two runtime-owned SFTP processes
remained independent, manual `ssh g207` inside the terminal did not retarget the
workspace, and close/quit reaped provider processes. Authentication was public key
through a configured OpenSSH key; no agent identity, app-owned `ControlMaster`,
host-key bypass, or Keychain claim applies. No implementation questions remain.
