import Foundation
import Testing
@testable import XMtermRemote

@Suite("Production read-only SFTP provider")
struct OpenSSHSFTPRemoteFileProviderTests {
    @Test("[FILE-WORKSPACE-001, FILE-LIST-001] resolves and lists raw immediate children only")
    func resolvesAndListsRawChildren() async throws {
        let rawName: [UInt8] = [0xFF, 0x0A, 0x27, 0x2D]
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(104, sftpU32(1), sftpU32(1), sftpName("/home/user")),
            sftpPacket(102, sftpU32(2), sftpString([0x11])),
            sftpPacket(
                104,
                sftpU32(3),
                sftpU32(4),
                providerNameRecord(Array(".".utf8), permissions: 0o040755),
                providerNameRecord(Array("..".utf8), permissions: 0o040755),
                providerNameRecord(Array("folder".utf8), permissions: 0o040750),
                providerNameRecord(rawName, size: 9, permissions: 0o100640, mtime: 1_700_000_000)
            ),
            sftpPacket(101, sftpU32(4), sftpU32(1), sftpString([]), sftpString([])),
            sftpPacket(101, sftpU32(5), sftpU32(0), sftpString([]), sftpString([]))
        ])
        let client = OpenSSHSFTPClient(factory: ScriptedSFTPChannelFactory(channels: [channel]))
        let provider = OpenSSHSFTPRemoteFileProvider(client: client)

        let initial = try await provider.resolveInitialDirectory()
        #expect(initial.rawBytes == Array("/home/user".utf8))
        let listing = try await provider.listDirectory(initial)

        #expect(listing.entries.count == 2)
        #expect(listing.entries[0].name.rawBytes == Array("folder".utf8))
        #expect(listing.entries[0].kind == .directory)
        #expect(listing.entries[0].permissions == 0o750)
        #expect(listing.entries[1].name.rawBytes == rawName)
        #expect(listing.entries[1].kind == .regular)
        #expect(listing.entries[1].size == 9)
        #expect(listing.entries[1].permissions == 0o640)
        #expect(listing.entries[1].modificationDate == Date(timeIntervalSince1970: 1_700_000_000))

        let writes = await channel.recordedWrites()
        #expect(writes.map { $0[4] } == [1, 16, 11, 12, 12, 4])
    }

    @Test("[FILE-META-001] symlink kind and partial metadata remain honest")
    func mapsSymlinkAndPartialMetadata() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([1])),
            sftpPacket(
                104,
                sftpU32(2),
                sftpU32(2),
                providerNameRecord(Array("link".utf8), permissions: 0o120777),
                providerNameRecord(Array("unknown".utf8))
            ),
            sftpPacket(101, sftpU32(3), sftpU32(1), sftpString([]), sftpString([])),
            sftpPacket(101, sftpU32(4), sftpU32(0), sftpString([]), sftpString([]))
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(factory: ScriptedSFTPChannelFactory(channels: [channel]))
        )
        let listing = try await provider.listDirectory(try RemotePath(rawBytes: Array("/tmp".utf8)))

        #expect(listing.entries[0].kind == .symbolicLink)
        #expect(listing.entries[0].symbolicLinkTarget == nil)
        #expect(listing.entries[0].metadataCompleteness == .partial)
        #expect(listing.entries[1].kind == .other)
        #expect(listing.metadataCompleteness == .partial)
    }

    @Test("[FILE-LIST-001, FILE-STATE-001] cumulative payload and entry limits fail explicitly")
    func enforcesCumulativeBounds() async {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([1])),
            sftpPacket(104, sftpU32(2), sftpU32(1), providerNameRecord(Array("large".utf8)))
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(factory: ScriptedSFTPChannelFactory(channels: [channel])),
            limits: .init(maximumCumulativeListingPayloadByteCount: 8)
        )

        await #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try await provider.listDirectory(try RemotePath(rawBytes: Array("/tmp".utf8)))
        }
        #expect(await channel.invalidationCount() == 1)
    }

    @Test("[FILE-STATE-001] provider close is idempotent and rejects later work")
    func closeIsIdempotent() async {
        let channel = ScriptedSFTPChannel(responses: [sftpPacket(2, sftpU32(3))])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(factory: ScriptedSFTPChannelFactory(channels: [channel]))
        )
        await provider.close()
        await provider.close()
        await #expect(throws: RemoteFileError(category: .transportUnavailable)) {
            try await provider.resolveInitialDirectory()
        }
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] a structured READDIR error closes its healthy handle")
    func readDirectoryStatusClosesHandle() async {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([0x44])),
            sftpPacket(101, sftpU32(2), sftpU32(3), sftpString([]), sftpString([])),
            sftpPacket(101, sftpU32(3), sftpU32(0), sftpString([]), sftpString([]))
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )

        await #expect(throws: RemoteFileError(category: .permissionDenied)) {
            try await provider.listDirectory(try RemotePath(rawBytes: Array("/denied".utf8)))
        }
        #expect(await channel.recordedWrites().map { $0[4] } == [1, 11, 12, 4])
        #expect(await channel.invalidationCount() == 0)
    }

    @Test(
        "[FILE-LIST-001, FILE-STATE-001] malformed child names invalidate the channel",
        arguments: [
            Array("a/b".utf8),
            [0x00],
            []
        ]
    )
    func malformedChildNameInvalidatesChannel(rawName: [UInt8]) async {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([0x44])),
            sftpPacket(
                104,
                sftpU32(2),
                sftpU32(1),
                providerNameRecord(rawName)
            )
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )

        await #expect(throws: RemoteFileError(category: .malformedResponse)) {
            try await provider.listDirectory(try RemotePath(rawBytes: Array("/tmp".utf8)))
        }
        #expect(await channel.invalidationCount() == 1)
        #expect(await channel.recordedWrites().map { $0[4] } == [1, 11, 12])
    }

    @Test("[FILE-XFER-002, FILE-XFER-004] production streams preserve short reads, EOF, exact flags, and double close")
    func productionStreamsAndExclusiveOpen() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(
                2,
                sftpU32(3),
                sftpString(Array("posix-rename@openssh.com".utf8)),
                sftpString(Array("1".utf8))
            ),
            sftpPacket(102, sftpU32(1), sftpString([0x10])),
            sftpPacket(103, sftpU32(2), sftpString([1, 2])),
            sftpPacket(101, sftpU32(3), sftpU32(1), sftpString([]), sftpString([])),
            providerOK(4),
            sftpPacket(102, sftpU32(5), sftpString([0x20])),
            providerOK(6),
            providerOK(7)
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )
        let path = try RemotePath(rawBytes: Array("/raw-file".utf8))

        let reader = try await provider.openFileForReading(path)
        #expect((await provider.capabilities).supportsAtomicReplace)
        #expect(try await reader.read(maximumBytes: 65_536) == Data([1, 2]))
        #expect(try await reader.read(maximumBytes: 65_536) == nil)
        try await reader.close()
        try await reader.close()

        let writer = try await provider.openFileForWriting(path)
        try await writer.write(Data([3]))
        try await writer.close()
        try await writer.close()

        let writes = await channel.recordedWrites()
        let expectedReadOpen = try SFTPBinaryCodec().encodeOpenRequest(
            id: 1,
            rawPath: path.rawBytes,
            flags: [.read]
        )
        let expectedExclusiveOpen = try SFTPBinaryCodec().encodeOpenRequest(
            id: 5,
            rawPath: path.rawBytes,
            flags: [.write, .create, .exclusive]
        )
        #expect(writes.map { $0[4] } == [1, 3, 5, 5, 4, 3, 6, 4])
        #expect(writes[1] == expectedReadOpen)
        #expect(writes[5] == expectedExclusiveOpen)
    }

    @Test("[FILE-XFER-004] replace uses advertised OpenSSH posix-rename instead of base rename")
    func replaceUsesAdvertisedPosixRename() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(
                2,
                sftpU32(3),
                sftpString(Array("posix-rename@openssh.com".utf8)),
                sftpString(Array("1".utf8))
            ),
            providerOK(1)
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )
        let source = try RemotePath(rawBytes: Array("/source".utf8))
        let destination = try RemotePath(rawBytes: Array("/destination".utf8))

        try await provider.rename(source, to: destination, replace: true)

        let writes = await channel.recordedWrites()
        let expectedReplace = try SFTPBinaryCodec().encodePosixRenameRequest(
            id: 1,
            source: source.rawBytes,
            destination: destination.rawBytes
        )
        #expect(writes.map { $0[4] } == [1, 200])
        #expect(writes[1] == expectedReplace)
        #expect(await channel.invalidationCount() == 0)
    }

    @Test("[FILE-XFER-004] unsupported replace fails exactly without sending base rename")
    func unsupportedReplaceFailsWithoutBaseRename() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3))
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )
        let source = try RemotePath(rawBytes: Array("/source".utf8))
        let destination = try RemotePath(rawBytes: Array("/destination".utf8))

        await #expect(throws: RemoteFileError(category: .unsupportedProtocol)) {
            try await provider.rename(source, to: destination, replace: true)
        }

        #expect(await channel.recordedWrites().map { $0[4] } == [1])
        #expect(await channel.invalidationCount() == 0)
    }

    @Test("[SESS-004, SESS-006] provider close invalidates outstanding file-handle identity without reconnecting")
    func closeInvalidatesOutstandingFileHandle() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([0x10]))
        ])
        let factory = ScriptedSFTPChannelFactory(channels: [channel])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(factory: factory)
        )
        let reader = try await provider.openFileForReading(
            try RemotePath(rawBytes: Array("/file".utf8))
        )

        await provider.close()

        await #expect(throws: RemoteFileError(category: .transportUnavailable)) {
            try await reader.read(maximumBytes: 1)
        }
        try await reader.close()
        #expect(await factory.makeCount() == 1)
        #expect(await channel.closeCount() == 1)
    }

    @Test("[SESS-004, FILE-XFER-002] cancelling a provider reaps an idle stream handle and later close does not reconnect")
    func cancelAllSettlesIdleStreamHandle() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([0x10]))
        ])
        let factory = ScriptedSFTPChannelFactory(channels: [channel])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(factory: factory)
        )
        let reader = try await provider.openFileForReading(
            try RemotePath(rawBytes: Array("/file".utf8))
        )

        await provider.cancelAll()
        try await reader.close()
        try await reader.close()

        #expect(await factory.makeCount() == 1)
        #expect(await channel.invalidationCount() == 1)
    }

    @Test("[SESS-004, FILE-XFER-002] a stream status failure settles its still-valid remote handle exactly once")
    func streamStatusFailureSettlesRemoteHandle() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([0x10])),
            sftpPacket(101, sftpU32(2), sftpU32(3), sftpString([]), sftpString([])),
            providerOK(3)
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )
        let reader = try await provider.openFileForReading(
            try RemotePath(rawBytes: Array("/file".utf8))
        )

        await #expect(throws: RemoteFileError(category: .permissionDenied)) {
            try await reader.read(maximumBytes: 1)
        }
        try await reader.close()
        try await reader.close()

        #expect(await channel.recordedWrites().map { $0[4] } == [1, 3, 5, 4])
        #expect(await channel.invalidationCount() == 0)
    }

    @Test("[SESS-004, FILE-XFER-002] a writable stream status failure settles its still-valid remote handle exactly once")
    func writableStreamStatusFailureSettlesRemoteHandle() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(102, sftpU32(1), sftpString([0x20])),
            sftpPacket(101, sftpU32(2), sftpU32(3), sftpString([]), sftpString([])),
            providerOK(3)
        ])
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(
                factory: ScriptedSFTPChannelFactory(channels: [channel])
            )
        )
        let writer = try await provider.openFileForWriting(
            try RemotePath(rawBytes: Array("/file".utf8))
        )

        await #expect(throws: RemoteFileError(category: .permissionDenied)) {
            try await writer.write(Data([0x01]))
        }
        try await writer.close()
        try await writer.close()

        #expect(await channel.recordedWrites().map { $0[4] } == [1, 3, 6, 4])
        #expect(await channel.invalidationCount() == 0)
    }
}

private func providerNameRecord(
    _ filename: [UInt8],
    size: UInt64? = nil,
    permissions: UInt32? = nil,
    mtime: UInt32? = nil
) -> [UInt8] {
    var flags: UInt32 = 0
    if size != nil { flags |= 0x01 }
    if permissions != nil { flags |= 0x04 }
    if mtime != nil { flags |= 0x08 }
    var values = sftpString(filename) + sftpString([]) + sftpU32(flags)
    if let size { values += sftpU64(size) }
    if let permissions { values += sftpU32(permissions) }
    if let mtime { values += sftpU32(mtime) + sftpU32(mtime) }
    return values
}

private func providerOK(_ id: UInt32) -> [UInt8] {
    sftpPacket(101, sftpU32(id), sftpU32(0), sftpString([]), sftpString([]))
}
