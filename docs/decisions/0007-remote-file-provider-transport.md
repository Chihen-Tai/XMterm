# ADR 0007: Use System OpenSSH with a Bounded Read-Only SFTP v3 Codec

- **Status:** Accepted and implemented for Phase 4A
- **Date:** 2026-07-16
- **Revised:** 2026-07-18

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
4. Implement a narrowly scoped read-only SFTP v3 packet codec in XMterm.

## Decision

Reject option 1 and any broad option-4 implementation. Human listing output is not
a protocol. XMterm will not implement SSH, cryptography, host-key verification,
an SFTP client command surface, mutation, transfer, or protocol extensions.

Do not adopt option 2 in this increment. The reviewed candidates establish their
own SSH/authentication stack and do not preserve the required OpenSSH behavior for
config aliases, `Include`/`Match`, ProxyJump, `ssh-agent`, macOS Keychain, and
known-host prompts. Adding one also requires dependency, license, packaging,
signing, and security review.

Select a constrained form of options 3 and 4: system OpenSSH supplies the secure
subsystem stream, while XMterm supplies a small bounded SFTP v3 codec limited to
the existing read-only provider contract. This architecture has explicit project-
owner approval for Task 9 implementation and adds no dependency. It must use these
structured argument forms, derived from the immutable launch specification:

```text
/usr/bin/ssh -T -o BatchMode=yes [-i identity] -s -p port user@host sftp
/usr/bin/ssh -T -o BatchMode=yes -s alias sftp
```

Arguments are separate values passed directly to `Process`; no shell participates.
XMterm must not add `StrictHostKeyChecking=no`, an app-owned `ControlMaster`, a
remote filename argument, or a logged environment. OpenSSH may reuse a control
connection configured by the user.

`BatchMode=yes` is mandatory. Stdin/stdout remain exclusively binary and cannot
become an authentication conversation. Password, passphrase, OTP, and first-time
host-key confirmation therefore fail honestly; host-key policy is never weakened.

The binary stream adapter must use structured SFTP operations: version handshake,
`REALPATH`, `OPENDIR`, sequential bounded `READDIR`, `CLOSE`, and structured status
packets. It ignores the human `longname` field. Authentication prompts require a
separate controlling-terminal channel; Task 9 does not add such a bridge. The
provider supports only noninteractive key/agent/configured-multiplexing behavior
already supplied by the user's OpenSSH setup.

The approved codec sends only `INIT`, `REALPATH`, `OPENDIR`, `READDIR`, and `CLOSE`
and parses only the required `VERSION`, `STATUS`, `HANDLE`, `NAME`, and structured
attribute shapes. It targets version 3, preserves filename bytes, validates the
single outstanding request ID, bounds all lengths before allocation, and treats
desynchronization as fatal. The implementation contract is detailed in
[`../design-docs/production-sftp-transport.md`](../design-docs/production-sftp-transport.md).

## Required lifecycle and bounds

The production provider is one actor per SSH runtime, created from the immutable
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

Cancellation stops new reads. If request bytes may have entered the stream, the
connection is torn down and reaped because discarding one response cannot prove
future stream synchronization. A stalled request also closes the provider
connection to unblock; the next operation reconnects lazily. Success is inferred only from SFTP handshake/status packets,
never from prompt text, a shell character, hostname, terminal title, or process
longevity.

## Acceptance evidence

The accepted adapter and noninteractive prompt policy passed:

1. codec scope, source, security, and no-new-dependency review;
2. system OpenSSH config/agent/Keychain/known-host behavior evidence;
3. malformed/oversized packet, cancellation, timeout, process-reaping, raw-name,
   metadata, symlink, and disposable-server integration tests;
4. packaged-app dependency/license/signing inspection;
5. successful packaged debug and signed release Relay initial-directory/listing,
   navigation, copy, two-runtime isolation, nested-terminal SSH boundary, and
   close/quit reaping evidence without credentials in logs or fixtures.

The exact Relay authentication mechanism was public-key authentication using a
configured OpenSSH key. No agent identity or app-owned `ControlMaster` was active;
normal known-host policy succeeded with no bypass. Local integration used
`/usr/libexec/sftp-server`; focused production tests passed 22 tests in 6 suites,
the pre-closeout full verifier passed 471 tests in 59 suites, and debug/release
warnings-as-errors builds passed. Independent code and security re-review found no
remaining Critical, High, or Medium finding.

## Consequences

- Phase 4A uses the stable provider protocol and concrete production composition.
- Supported SSH sessions ship real read-only listings; local sessions own no
  transport, and release builds ignore simulated fixture injection.
- The narrow custom codec is explicit, reviewed, read-only, and dependency-free.
- Real Relay acceptance passed and Phase 4A is complete.
- Phase 4B mutation and transfer work remains a separate subsequent phase.
