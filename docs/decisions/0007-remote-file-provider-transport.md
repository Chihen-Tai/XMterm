# ADR 0007: Require Structured SFTP Data and Block Human-Listing Parsing

- **Status:** Proposed; Phase 4A production transport blocked
- **Date:** 2026-07-16

## Context

Phase 4A requires a production remote-file provider that preserves exact remote
path identity, treats names as untrusted bytes, reuses normal system OpenSSH
configuration/authentication behavior, remains cancellable, and can list the real
Relay Host. The repository currently depends only on SwiftTerm and contains no
SFTP client.

System inspection on macOS found OpenSSH 10.2p1. `/usr/bin/sftp` batch mode accepts
machine-supplied commands, but its `ls` command emits human-formatted records. It
has no structured, JSON, or NUL-delimited listing mode. Local
`sftp -D /usr/libexec/sftp-server` probes demonstrated prompt text, presentation
columns, locale-shaped dates, and raw newline/control-bearing names. Exit status
also does not consistently distinguish a failed directory read from an empty
listing.

Parsing that output cannot meet the Phase 4A correctness or security contract and
is explicitly prohibited.

## Options considered

1. Parse `/usr/bin/sftp` `ls` output with strict quoting and locale settings.
2. Adopt a SwiftNIO/libssh2 SFTP client as XMterm's SSH implementation.
3. Use a mature SFTP packet adapter over binary pipes from a system OpenSSH
   subsystem process.
4. Implement the SFTP packet protocol in XMterm.

## Decision

Reject options 1 and 4. Human listing output is not a protocol, and XMterm will not
write an SFTP implementation from scratch.

Do not adopt option 2 in this increment. The reviewed candidates establish their
own SSH/authentication stack and do not preserve the required OpenSSH behavior for
config aliases, `Include`/`Match`, ProxyJump, `ssh-agent`, macOS Keychain, and
known-host prompts. Adding one also requires dependency, license, packaging,
signing, and security review.

Option 3 is the preferred production direction. It must use these structured
argument forms, derived from the immutable launch specification:

```text
/usr/bin/ssh -T -s [-i identity] -p port user@host sftp
/usr/bin/ssh -T -s alias sftp
```

Arguments are separate values passed directly to `Process`; no shell participates.
XMterm must not add `StrictHostKeyChecking=no`, an app-owned `ControlMaster`, a
remote filename argument, or a logged environment. OpenSSH may reuse a control
connection configured by the user.

The binary stream adapter must use structured SFTP operations: version handshake,
`REALPATH`, `OPENDIR`, sequential bounded `READDIR`, `CLOSE`, and structured status
packets. It ignores the human `longname` field. Authentication prompts require a
separate controlling-terminal channel; prompt bytes must never share the protocol
stream. If that bridge is not included, the provider must state that only
noninteractive key/agent/configured-multiplexing authentication is supported.

No reviewed packet adapter satisfying this boundary is present. Phase 4A will
therefore ship an honest unavailable provider plus a fully functional in-memory
provider, state model, and UI. It will not display a fake Relay listing and will
not be called complete.

## Required lifecycle and bounds

The eventual provider is one actor per SSH runtime, created from the immutable
launch snapshot and started lazily. It owns the process, binary streams, handles,
requests, and cancellation. It permits at most two workspace requests and at most
one `READDIR` request per directory. Closing the runtime rejects new work, cancels
requests, closes open handles/stdin, uses bounded HUP/TERM/KILL escalation, and
reaps the provider process without touching the terminal process.

The production adapter must enforce before allocation/publication:

- 1 MiB maximum individual packet;
- 10,000 entries per directory, with explicit limit error rather than truncation;
- 32 MiB cumulative listing payload;
- 32 KiB absolute raw path;
- 4 KiB raw filename component;
- 32 KiB raw symlink target;
- 64 KiB bounded/redacted diagnostic buffer;
- finite handshake/request/close timeouts.

Cancellation stops new reads, discards the one outstanding response, closes the
directory handle, and returns cancellation. A stalled request closes the provider
connection to unblock. Success is inferred only from SFTP handshake/status packets,
never from prompt text, a shell character, hostname, terminal title, or process
longevity.

## Acceptance gate

This ADR can become Accepted only after a chosen adapter and prompt policy have:

1. source, maintenance, security, license, and transitive-dependency review;
2. system OpenSSH config/agent/Keychain/known-host behavior evidence;
3. malformed/oversized packet, cancellation, timeout, process-reaping, raw-name,
   metadata, symlink, and disposable-server integration tests;
4. packaged-app dependency/license/signing inspection;
5. successful manual Relay Host initial-directory and listing evidence without
   credentials in logs or fixtures.

## Consequences

- Phase 4A foundation work can proceed behind a stable provider protocol.
- The shipping app reports the transport limitation rather than an empty or fake
  directory.
- No new dependency or custom protocol implementation is introduced silently.
- Real Relay acceptance and Phase 4A completion remain blocked.
- Phase 4B mutation and transfer work must not begin while this gate is unresolved.
