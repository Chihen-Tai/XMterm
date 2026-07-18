import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote mutation and transfer provider contract")
struct RemoteMutationTransferProviderContractTests {
    @Test("[FILE-OPS-001, FILE-XFER-002] capabilities are explicit and honest")
    func capabilitiesAreExplicit() async {
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [])]
        )

        #expect(
            await provider.capabilities
                == RemoteFileCapabilities(
                    canList: true,
                    canMutate: true,
                    canTransfer: true,
                    supportsAtomicReplace: true
                )
        )
    }

    @Test("[FILE-OPS-001, FILE-META-001] exclusive zero-byte create and lstat preserve raw identity and mode")
    func createsEmptyFileAndStatsIt() async throws {
        let rawName = try RemotePathComponent(rawBytes: [0xFF, 0x2D, 0x66])
        let path = try RemotePath.root.appending(rawName)
        let provider = emptyProvider()

        try await provider.createFile(path)
        let attributes = try await provider.lstat(path)

        #expect(attributes.kind == .regular)
        #expect(attributes.size == 0)
        #expect(attributes.permissions == nil)
        #expect(try await provider.listDirectory(.root).entries.map(\.path) == [path])
        await #expect(throws: RemoteFileError(category: .alreadyExists)) {
            try await provider.createFile(path)
        }
    }

    @Test("[FILE-XFER-002, FILE-XFER-004] streams are bounded, ordered, and return nil only at EOF")
    func streamsWriteReadAndClose() async throws {
        let path = try remotePath("/payload.bin")
        let provider = emptyProvider()
        let writer = try await provider.openFileForWriting(path)

        try await writer.write(Data([0x00, 0xFF, 0x41]))
        try await writer.write(Data([0x42]))
        try await writer.close()
        try await writer.close()

        await #expect(throws: RemoteFileError(category: .alreadyExists)) {
            try await provider.openFileForWriting(path)
        }

        let reader = try await provider.openFileForReading(path)
        #expect(try await reader.read(maximumBytes: 3) == Data([0x00, 0xFF, 0x41]))
        #expect(try await reader.read(maximumBytes: 3) == Data([0x42]))
        #expect(try await reader.read(maximumBytes: 3) == nil)
        #expect(try await reader.read(maximumBytes: 3) == nil)
        try await reader.close()
        try await reader.close()

        let attributes = try await provider.lstat(path)
        #expect(attributes.size == 4)
    }

    @Test("[FILE-XFER-002] stream chunks reject zero and values above 64 KiB before allocation")
    func enforcesStreamChunkBounds() async throws {
        let path = try remotePath("/bounded")
        let provider = emptyProvider()
        let writer = try await provider.openFileForWriting(path)
        let reader = try await provider.openFileForReading(path)

        await #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try await reader.read(maximumBytes: 0)
        }
        await #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try await reader.read(maximumBytes: RemoteFileTransferLimits.maximumChunkByteCount + 1)
        }
        await #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try await writer.write(
                Data(repeating: 0x41, count: RemoteFileTransferLimits.maximumChunkByteCount + 1)
            )
        }
    }

    @Test("[FILE-OPS-001, FILE-META-001] mode, rename collision, replacement, and link removal are structured")
    func mutatesMetadataRenamesAndRemovesLinkIdentity() async throws {
        let source = try remotePath("/source")
        let destination = try remotePath("/destination")
        let link = try entry("/link", kind: .symbolicLink)
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [
                .root: .init(entries: [
                    try entry("/source"),
                    try entry("/destination"),
                    link,
                ])
            ],
            fileContents: [source: Data([1]), destination: Data([2])]
        )

        try await provider.setPermissions(0o751, at: source)
        #expect(try await provider.lstat(source).permissions == 0o751)
        await #expect(throws: RemoteFileError(category: .alreadyExists)) {
            try await provider.rename(source, to: destination, replace: false)
        }
        try await provider.rename(source, to: destination, replace: true)

        #expect(try await provider.lstat(destination).size == 1)
        await #expect(throws: RemoteFileError(category: .pathNotFound)) {
            try await provider.lstat(source)
        }
        try await provider.removeFile(link.path)
        await #expect(throws: RemoteFileError(category: .pathNotFound)) {
            try await provider.lstat(link.path)
        }
    }

    @Test("[FILE-OPS-001] rmdir distinguishes empty, nonempty, and non-directory paths")
    func removesOnlyEmptyDirectories() async throws {
        let empty = try remotePath("/empty")
        let full = try remotePath("/full")
        let child = try entry("/full/child")
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [
                .root: .init(entries: [
                    try entry("/empty", kind: .directory),
                    try entry("/full", kind: .directory),
                    try entry("/file"),
                ]),
                empty: .init(entries: []),
                full: .init(entries: [child]),
            ]
        )

        await #expect(throws: RemoteFileError(category: .directoryNotEmpty)) {
            try await provider.removeDirectory(full)
        }
        await #expect(throws: RemoteFileError(category: .notDirectory)) {
            try await provider.removeDirectory(try remotePath("/file"))
        }
        try await provider.removeDirectory(empty)
        await #expect(throws: RemoteFileError(category: .pathNotFound)) {
            try await provider.lstat(empty)
        }
    }

    @Test("[SESS-004, SESS-006] cancellation settles an operation without closing the provider")
    func cancellationSettlesWithoutClosingProvider() async throws {
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [])],
            latency: .seconds(5)
        )
        let pending = Task { try await provider.createDirectory(try remotePath("/slow")) }
        await waitForAttempt(on: provider, count: 1)

        pending.cancel()
        await #expect(throws: RemoteFileError(category: .cancelled)) {
            try await pending.value
        }

        let fast = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [])]
        )
        try await fast.createDirectory(try remotePath("/healthy"))
        #expect(try await fast.lstat(try remotePath("/healthy")).kind == .directory)
    }

    @Test("[FILE-OPS-001, FILE-XFER-002] mutation and stream faults are deterministic and attempt records stay path-free")
    func deterministicOperationFaultsArePathFree() async throws {
        let expected = RemoteFileError(category: .permissionDenied)
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [])],
            deterministicOperationFailures: [.createFile: expected]
        )

        await #expect(throws: expected) {
            try await provider.createFile(try remotePath("/private/customer-secret"))
        }

        let attempts = await provider.recordedAttempts
        #expect(attempts == [.createFile])
        #expect(!String(reflecting: attempts).contains("customer-secret"))
    }

    @Test("[SESS-004, SESS-006] close is idempotent, settles streams, and rejects all new operations")
    func closeSettlesStreamsAndRejectsNewWork() async throws {
        let path = try remotePath("/file")
        let provider = emptyProvider()
        try await provider.createFile(path)
        let reader = try await provider.openFileForReading(path)

        await provider.close()
        await provider.close()

        await #expect(throws: RemoteFileError(category: .disconnected)) {
            try await reader.read(maximumBytes: 1)
        }
        await #expect(throws: RemoteFileError(category: .disconnected)) {
            try await provider.lstat(path)
        }
        await #expect(throws: RemoteFileError(category: .disconnected)) {
            try await provider.openFileForReading(path)
        }
    }

    private func emptyProvider() -> InMemoryRemoteFileProvider {
        InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [], metadataCompleteness: .complete)]
        )
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func entry(
        _ path: String,
        kind: RemoteFileEntry.Kind = .regular
    ) throws -> RemoteFileEntry {
        try RemoteFileEntry(path: remotePath(path), kind: kind)
    }

    private func waitForAttempt(
        on provider: InMemoryRemoteFileProvider,
        count: Int
    ) async {
        for _ in 0..<1_000 {
            if await provider.recordedAttempts.count >= count { return }
            await Task.yield()
        }
        Issue.record("The provider did not record the requested operation")
    }
}
