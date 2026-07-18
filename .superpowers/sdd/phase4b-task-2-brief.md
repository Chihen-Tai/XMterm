## Task 2 — Phase 4B.2 transfer and mutation capability contracts plus codec

**Acceptance:** `FILE-OPS-001`, `FILE-META-001`, `FILE-XFER-002`,
`FILE-XFER-004`, `SESS-004`, `SESS-006`.

**Interfaces produced:**

```swift
public struct RemoteFileCapabilities: Equatable, Sendable {
    public let canList: Bool
    public let canMutate: Bool
    public let canTransfer: Bool
    public let supportsAtomicReplace: Bool
}

public protocol RemoteFileMutationProvider: Sendable {
    func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes
    func createFile(_ path: RemotePath) async throws
    func createDirectory(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath, replace: Bool) async throws
    func removeFile(_ path: RemotePath) async throws
    func removeDirectory(_ path: RemotePath) async throws
    func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws
}

public protocol RemoteReadableFile: Sendable {
    func read(maximumBytes: Int) async throws -> Data?
    func close() async throws
}

public protocol RemoteWritableFile: Sendable {
    func write(_ data: Data) async throws
    func close() async throws
}
```

- [ ] Write provider-contract tests for capabilities, zero-byte create, open/read
  EOF, write/close, lstat, mode, rename collision, remove file/link, empty/nonempty
  rmdir, cancellation, and close.
- [ ] Write codec RED tests for every ADR 0008 request/response, exact IDs, 64 KiB
  chunks, malformed/trailing/oversized data, status mapping, short packet, and
  advertised `posix-rename@openssh.com` detection.
- [ ] Run the focused provider/codec suites and capture missing-symbol RED.
- [ ] Add the protocol/domain values and deterministic in-memory implementation.
- [ ] Extend SFTP protocol types/codec minimally: `OPEN`, `READ`, `WRITE`, `LSTAT`,
  `SETSTAT`, `REMOVE`, `MKDIR`, `RMDIR`, `RENAME`, one allowlisted `EXTENDED`,
  `DATA`, `ATTRS`, and required open flags/attributes.
- [ ] Ensure all lengths/counts are checked before allocation; reject unknown flags,
  responses, extensions, IDs, and trailing bytes.
- [ ] Extend `OpenSSHSFTPClient` typed methods while preserving one outstanding
  request and fatal desynchronization policy.
- [ ] Run focused GREEN, disposable `sftp-server` codec integration, all existing
  production transport suites, and `./scripts/verify.sh`.
- [ ] Perform an independent protocol/security review before this slice closes.

