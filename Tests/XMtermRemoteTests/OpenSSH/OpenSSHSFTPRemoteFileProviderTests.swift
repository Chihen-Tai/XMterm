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
