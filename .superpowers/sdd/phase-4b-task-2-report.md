# Phase 4B Task 2 implementation report

## Result

DONE. Phase 4B.2 now has transport-neutral mutation/stream capability contracts,
deterministic in-memory mutation and transfer behavior, the allowlisted SFTP v3
mutation/stream codec surface, typed serialized client operations, production
OpenSSH provider conformance, and a lazy transfer-provider factory. No commit,
merge, push, tag, branch, dependency, shell protocol, or human `sftp` parser was
introduced.

Acceptance covered: `FILE-OPS-001`, `FILE-META-001`, `FILE-XFER-002`,
`FILE-XFER-004`, `SESS-004`, and `SESS-006`.

## TDD evidence

Initial RED used verifier-equivalent Testing framework flags:

```text
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter 'RemoteMutationTransferProviderContractTests|SFTPBinaryCodecTests|OpenSSHSFTPClientTests'
```

It failed on the intended missing symbols and behavior: capabilities,
mutation/stream protocols, attributes, exclusive staging writes, 64 KiB bounds, SFTP
OPEN/READ/WRITE/LSTAT/SETSTAT/REMOVE/MKDIR/RMDIR/RENAME/EXTENDED and DATA support,
extension detection, and typed client methods. An earlier direct `swift test`
attempt failed only because this machine requires the repository verifier's
Testing framework flags; it was not treated as the product RED.

A later focused RED reproduced the independently found handle-settlement defect:

```text
swift test ... --filter 'OpenSSHSFTPRemoteFileProviderTests.streamStatusFailureSettlesRemoteHandle'
```

The test failed because the expected CLOSE packet was absent after a valid
permission-denied STATUS. GREEN now settles that handle once on the same
connection generation, or invalidates the channel if safe CLOSE cannot be
proven.

Independent review then found two public-surface defects. A focused RED changed
the provider contract to an exclusive-only writer and added typed
`posix-rename@openssh.com` source/destination bound tests. It failed on the old
write-options signatures. GREEN removed every public truncate/append/open-existing
mode, removed the generic EXTENDED packet emitter, and retained only the typed,
path-validating POSIX rename encoder.

Final focused GREEN:

```text
swift test -q -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib --filter 'RemoteFileProviderContractTests|RemoteMutationTransferProviderContractTests|SFTPBinaryCodecTests|OpenSSHSFTPClientTests|OpenSSHSFTPRemoteFileProviderTests|OpenSSHSubsystemProcessTests'
```

Result: **64 tests / 6 suites passed**. This includes a disposable
`/usr/libexec/sftp-server` mutation/64 KiB streaming round trip through the
production process channel and codec.

Additional verification:

```text
swift build -Xswiftc -warnings-as-errors
```

Result: passed.

```text
./scripts/verify.sh
```

Final result: **512 tests / 61 suites passed** and
`XMterm verification: OK`.

`git diff --check` also passed during self-review.

## Production and contract behavior

- `RemoteFileCapabilities`, `RemoteFileAttributes`, mutation protocols, opaque
  readable/writable streams, the 64 KiB limit, and the provider factory are public
  transport-neutral values/protocols. The public writable stream contract can
  only create a new staging file exclusively; it cannot open, truncate, or append
  an existing remote file.
- In-memory state uses actor-isolated replacement of directory/file values,
  exclusive creation, exact `RemotePath` identity, directory subtree rebasing,
  typed collision/nonempty errors, permission changes, bounded streams,
  cancellation, close settlement, and path-free deterministic fault injection.
- The production codec encodes only the ADR 0008 request set and only the exact
  `posix-rename@openssh.com` EXTENDED operation. It separately caps DATA at
  64 KiB while retaining the 1 MiB packet limit.
- OPEN flag combinations and unknown bits are rejected. SETSTAT output permits
  mode only. All paths, handles, strings, counts, packets, DATA, IDs, and trailing
  payload/packet bytes are validated before publication or variable allocation.
- The client remains one actor with one outstanding request. IDs are monotonic and
  exact. Cancellation before send leaves the channel reusable; cancellation or
  uncertainty after send invalidates it. Bad-message/connection-lost statuses,
  malformed packets, mismatched IDs, unknown response types, timeout, EOF, and
  transport uncertainty are fatal to that channel.
- File-handle tokens carry the connection generation. A stale handle never opens
  a replacement connection. Close during an in-flight request settles the owned
  channel once. Provider cancel/close reaps idle handles, and later stream close
  is idempotent without reconnecting.
- Error values are bounded categories and never contain server status text,
  stderr, packet bytes, credentials, or raw paths.
- Atomic replace capability becomes true only after an exact version-1 OpenSSH
  advertisement observed on the current completed handshake. The replacement
  operation rechecks its own channel before use because a reconnect may negotiate
  different extensions. `replace: true` uses that extension or reports
  unsupported; non-atomic backup/finalize/rollback remains coordinator work as
  designed.

## File manifest

Created:

- `Sources/XMtermRemote/Operations/RemoteFileCapabilities.swift`
- `Sources/XMtermRemote/Operations/RemoteFileMutationProvider.swift`
- `Sources/XMtermRemote/Transfer/RemoteFileTransferProvider.swift`
- `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPTransferProviderFactory.swift`
- `Tests/XMtermRemoteTests/RemoteMutationTransferProviderContractTests.swift`
- `.superpowers/sdd/phase-4b-task-2-report.md`

Modified:

- `Sources/XMtermRemote/Domain/RemoteFileError.swift`
- `Sources/XMtermRemote/Providers/InMemoryRemoteFileProvider.swift`
- `Sources/XMtermRemote/Providers/UnavailableRemoteFileProvider.swift`
- `Sources/XMtermRemote/Providers/OpenSSH/SFTPProtocolTypes.swift`
- `Sources/XMtermRemote/Providers/OpenSSH/SFTPBinaryCodec.swift`
- `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPClient.swift`
- `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPFailure.swift`
- `Sources/XMtermRemote/Providers/OpenSSH/OpenSSHSFTPRemoteFileProvider.swift`
- `Tests/XMtermRemoteTests/RemoteFileProviderContractTests.swift`
- `Tests/XMtermRemoteTests/RemoteFileEntryTests.swift`
- `Tests/XMtermRemoteTests/OpenSSH/SFTPBinaryCodecTests.swift`
- `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSFTPClientTests.swift`
- `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSFTPRemoteFileProviderTests.swift`
- `Tests/XMtermRemoteTests/OpenSSH/OpenSSHSubsystemProcessTests.swift`

## Self-review and remaining concern

Self-review found no secret/path logging, human-output parsing, shell
interpolation, dependency change, whole-file production buffer, unbounded DATA,
or cross-runtime/shared ownership. Existing terminal/browsing isolation remains
unchanged.

Independent review findings are disposed as follows:

- **Important — public destructive writer modes:** fixed by removing the public
  write-options type and exposing only exclusive staging creation. Contract tests
  prove reopening an existing path returns `alreadyExists` without changing its
  content, and production tests prove exact SFTP flags: WRITE + CREAT + EXCL.
- **Important — generic EXTENDED request emitter:** fixed by deleting the generic
  name/payload encoder. The codec can emit only the typed POSIX rename request,
  and both source and destination raw-path bounds are tested.
- **Minor — capability snapshot semantics:** fixed by documenting that capability
  state reflects an observed completed handshake and by retaining the operation-
  time extension recheck on the channel actually used.

Known protocol limitation: SFTP v3's generic `SSH_FX_FAILURE` cannot honestly
distinguish every server-side rename collision or nonempty-directory failure.
The deterministic provider exposes precise categories; production maps the
ambiguous status to bounded `providerFailure`. Exclusive OPEN and the coordinator's
LSTAT/collision policy prevent silent overwrite, while races remain explicit
failures. No unresolved Critical, High, or Important issue is known after the
independent-review fixes.
