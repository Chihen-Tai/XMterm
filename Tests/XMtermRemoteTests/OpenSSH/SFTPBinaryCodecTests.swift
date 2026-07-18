import Foundation
import Testing
@testable import XMtermRemote

@Suite("Bounded SFTP v3 binary codec")
struct SFTPBinaryCodecTests {
    private let codec = SFTPBinaryCodec()

    @Test("[FILE-XFER-004] INIT and read-only requests use exact v3 framing")
    func encodesReadOnlyRequests() throws {
        #expect(codec.encodeInitialization() == bytes(1, u32(3)))
        #expect(
            try codec.encodePathRequest(type: .realPath, id: 41, rawPath: [0x2E])
                == bytes(16, u32(41), string([0x2E]))
        )
        #expect(
            try codec.encodePathRequest(type: .openDirectory, id: 42, rawPath: [0x2F, 0x74])
                == bytes(11, u32(42), string([0x2F, 0x74]))
        )
        #expect(
            try codec.encodeHandleRequest(type: .readDirectory, id: 43, handle: [0xAA, 0xBB])
                == bytes(12, u32(43), string([0xAA, 0xBB]))
        )
        #expect(
            try codec.encodeHandleRequest(type: .close, id: 44, handle: [0x01])
                == bytes(4, u32(44), string([0x01]))
        )
    }

    @Test("[FILE-XFER-004] VERSION accepts only v3 and consumes bounded extensions")
    func parsesVersionAndExtensions() throws {
        let version = bytes(
            2,
            u32(3),
            string(Array("posix-rename@openssh.com".utf8)),
            string(Array("1".utf8))
        )
        #expect(
            try codec.decodeFramedResponse(version, expectedRequestID: nil)
                == .version(
                    3,
                    extensions: [
                        SFTPExtension(
                            name: Array("posix-rename@openssh.com".utf8),
                            data: Array("1".utf8)
                        )
                    ]
                )
        )

        #expect(throws: SFTPProtocolError.unsupportedVersion(4)) {
            try codec.decodeFramedResponse(bytes(2, u32(4)), expectedRequestID: nil)
        }
    }

    @Test("[FILE-XFER-004] framing rejects underflow, truncation, oversize, and trailing bytes")
    func rejectsInvalidFraming() {
        #expect(throws: SFTPProtocolError.truncatedLengthPrefix(actual: 3)) {
            try codec.decodeFramedResponse([0, 0, 0], expectedRequestID: nil)
        }
        #expect(throws: SFTPProtocolError.invalidPacketLength(0)) {
            try codec.decodeFramedResponse([0, 0, 0, 0], expectedRequestID: nil)
        }
        #expect(throws: SFTPProtocolError.truncatedPacket(expected: 9, actual: 6)) {
            try codec.decodeFramedResponse([0, 0, 0, 5, 2, 0], expectedRequestID: nil)
        }
        #expect(throws: SFTPProtocolError.trailingPacketBytes(1)) {
            try codec.decodeFramedResponse(bytes(2, u32(3)) + [0], expectedRequestID: nil)
        }

        let oversizedCodec = SFTPBinaryCodec(limits: .init(maximumPacketByteCount: 8))
        #expect(throws: SFTPProtocolError.packetTooLarge(maximum: 8, actual: 13)) {
            try oversizedCodec.decodeFramedResponse(bytes(2, u32(3), [0, 0, 0, 0]), expectedRequestID: nil)
        }
    }

    @Test("[FILE-XFER-004] response type and request ID must match the serialized request")
    func validatesResponseTypeAndRequestID() throws {
        #expect(throws: SFTPProtocolError.unexpectedPacketType(103)) {
            try codec.decodeFramedResponse(bytes(103, u32(9)), expectedRequestID: 9)
        }
        #expect(throws: SFTPProtocolError.requestIDMismatch(expected: 9, actual: 10)) {
            try codec.decodeFramedResponse(
                bytes(101, u32(10), u32(0), string([]), string([])),
                expectedRequestID: 9
            )
        }
        #expect(throws: SFTPProtocolError.requestIDForbiddenForVersion) {
            try codec.decodeFramedResponse(bytes(2, u32(3)), expectedRequestID: 9)
        }
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] STATUS and opaque HANDLE are structured and bounded")
    func parsesStatusAndHandle() throws {
        #expect(
            try codec.decodeFramedResponse(
                bytes(101, u32(7), u32(3), string(Array("denied".utf8)), string(Array("en".utf8))),
                expectedRequestID: 7
            ) == .status(
                id: 7,
                code: .permissionDenied,
                message: Array("denied".utf8),
                language: Array("en".utf8)
            )
        )
        #expect(
            try codec.decodeFramedResponse(
                bytes(102, u32(8), string([0, 1, 0xFF])),
                expectedRequestID: 8
            ) == .handle(id: 8, value: [0, 1, 0xFF])
        )

        let handle = Array(repeating: UInt8(0x61), count: 257)
        #expect(throws: SFTPProtocolError.handleTooLong(maximum: 256, actual: 257)) {
            try codec.decodeFramedResponse(
                bytes(102, u32(8), string(handle)),
                expectedRequestID: 8
            )
        }
    }

    @Test("[FILE-META-001, FILE-XFER-004] NAME preserves raw names, ignores longname, and parses partial attrs")
    func parsesNamesAndAttributes() throws {
        let records = [
            nameRecord(
                [0x66, 0x69, 0x6C, 0x65],
                longname: Array("human output must be ignored".utf8),
                attrs: attrs(flags: 0x0D, size: 12, permissions: 0o100755, atime: 4, mtime: 5)
            ),
            nameRecord(
                [0xE7, 0xA0, 0x94, 0xE7, 0xA9, 0xB6, 0x20, 0x27, 0x2D],
                longname: [],
                attrs: attrs(flags: 0)
            ),
            nameRecord([0xFF, 0x0A], longname: [0xFF], attrs: attrs(flags: 0x04, permissions: 0o120777))
        ]
        let response = try codec.decodeFramedResponse(
            bytes(104, u32(12), u32(3), records.flatMap { $0 }),
            expectedRequestID: 12
        )

        #expect(
            response == .names(
                id: 12,
                values: [
                    SFTPName(
                        rawFilename: Array("file".utf8),
                        attributes: .init(
                            size: 12,
                            userID: nil,
                            groupID: nil,
                            permissions: 0o100755,
                            accessTime: 4,
                            modificationTime: 5
                        )
                    ),
                    SFTPName(
                        rawFilename: [0xE7, 0xA0, 0x94, 0xE7, 0xA9, 0xB6, 0x20, 0x27, 0x2D],
                        attributes: .empty
                    ),
                    SFTPName(
                        rawFilename: [0xFF, 0x0A],
                        attributes: .init(
                            size: nil,
                            userID: nil,
                            groupID: nil,
                            permissions: 0o120777,
                            accessTime: nil,
                            modificationTime: nil
                        )
                    )
                ]
            )
        )
    }

    @Test("[FILE-LIST-001, FILE-XFER-004] NAME supports zero entries and rejects excessive counts")
    func boundsNameCount() throws {
        #expect(
            try codec.decodeFramedResponse(bytes(104, u32(1), u32(0)), expectedRequestID: 1)
                == .names(id: 1, values: [])
        )

        let limited = SFTPBinaryCodec(limits: .init(maximumNameCount: 2))
        #expect(throws: SFTPProtocolError.tooManyNames(maximum: 2, actual: 3)) {
            try limited.decodeFramedResponse(bytes(104, u32(1), u32(3)), expectedRequestID: 1)
        }
    }

    @Test("[FILE-META-001, FILE-XFER-004] standalone ATTRS parses every v3 field without guessing")
    func parsesStandaloneAttributes() throws {
        let response = try codec.decodeFramedResponse(
            bytes(
                105,
                u32(21),
                attrs(
                    flags: 0x0F,
                    size: 99,
                    userID: 501,
                    groupID: 20,
                    permissions: 0o100600,
                    atime: 10,
                    mtime: 11
                )
            ),
            expectedRequestID: 21
        )

        #expect(
            response == .attributes(
                id: 21,
                value: .init(
                    size: 99,
                    userID: 501,
                    groupID: 20,
                    permissions: 0o100600,
                    accessTime: 10,
                    modificationTime: 11
                )
            )
        )
    }

    @Test("[FILE-XFER-004] malformed strings, attrs, flags, and trailing payload fail closed")
    func rejectsMalformedPayloads() {
        #expect(throws: SFTPProtocolError.truncatedValue(expected: 5, remaining: 1)) {
            try codec.decodeFramedResponse(
                bytes(102, u32(1), u32(5), [0xAA]),
                expectedRequestID: 1
            )
        }
        #expect(throws: SFTPProtocolError.unsupportedAttributeFlags(0x10)) {
            try codec.decodeFramedResponse(
                bytes(104, u32(1), u32(1), nameRecord([0x61], longname: [], attrs: attrs(flags: 0x10))),
                expectedRequestID: 1
            )
        }
        #expect(throws: SFTPProtocolError.trailingPayloadBytes(1)) {
            try codec.decodeFramedResponse(
                bytes(104, u32(1), u32(0), [0]),
                expectedRequestID: 1
            )
        }
        #expect(throws: SFTPProtocolError.truncatedValue(expected: 8, remaining: 4)) {
            try codec.decodeFramedResponse(
                bytes(105, u32(1), u32(1), u32(9)),
                expectedRequestID: 1
            )
        }
    }

    @Test("[FILE-XFER-004] outbound paths, handles, and packet sizes enforce configured limits")
    func boundsOutboundValues() {
        let limited = SFTPBinaryCodec(
            limits: .init(
                maximumPacketByteCount: 20,
                maximumPathByteCount: 4,
                maximumHandleByteCount: 2
            )
        )
        #expect(throws: SFTPProtocolError.pathTooLong(maximum: 4, actual: 5)) {
            try limited.encodePathRequest(type: .realPath, id: 1, rawPath: [1, 2, 3, 4, 5])
        }
        #expect(throws: SFTPProtocolError.handleTooLong(maximum: 2, actual: 3)) {
            try limited.encodeHandleRequest(type: .close, id: 1, handle: [1, 2, 3])
        }
        #expect(throws: SFTPProtocolError.invalidRequestType(16)) {
            try limited.encodeHandleRequest(type: .realPath, id: 1, handle: [1])
        }
    }
}

private func bytes(_ type: UInt8, _ parts: [UInt8]...) -> [UInt8] {
    let payload = [type] + parts.flatMap { $0 }
    return u32(UInt32(payload.count)) + payload
}

private func u32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value)
    ]
}

private func u64(_ value: UInt64) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 56),
        UInt8(truncatingIfNeeded: value >> 48),
        UInt8(truncatingIfNeeded: value >> 40),
        UInt8(truncatingIfNeeded: value >> 32),
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value)
    ]
}

private func string(_ value: [UInt8]) -> [UInt8] {
    u32(UInt32(value.count)) + value
}

private func nameRecord(
    _ filename: [UInt8],
    longname: [UInt8],
    attrs: [UInt8]
) -> [UInt8] {
    string(filename) + string(longname) + attrs
}

private func attrs(
    flags: UInt32,
    size: UInt64? = nil,
    userID: UInt32? = nil,
    groupID: UInt32? = nil,
    permissions: UInt32? = nil,
    atime: UInt32? = nil,
    mtime: UInt32? = nil
) -> [UInt8] {
    var result = u32(flags)
    if flags & 0x01 != 0 { result += u64(size!) }
    if flags & 0x02 != 0 { result += u32(userID!) + u32(groupID!) }
    if flags & 0x04 != 0 { result += u32(permissions!) }
    if flags & 0x08 != 0 { result += u32(atime!) + u32(mtime!) }
    return result
}
