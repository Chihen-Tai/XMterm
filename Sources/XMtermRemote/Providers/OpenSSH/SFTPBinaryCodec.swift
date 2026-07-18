import Foundation

struct SFTPBinaryCodec: Sendable {
    private enum PacketType: UInt8 {
        case version = 2
        case status = 101
        case handle = 102
        case name = 104
        case attributes = 105
    }

    private enum AttributeFlag {
        static let size: UInt32 = 0x0000_0001
        static let userAndGroup: UInt32 = 0x0000_0002
        static let permissions: UInt32 = 0x0000_0004
        static let accessAndModificationTime: UInt32 = 0x0000_0008
        static let extended: UInt32 = 0x8000_0000
        static let supported = size | userAndGroup | permissions
            | accessAndModificationTime | extended
    }

    let limits: SFTPCodecLimits

    init(limits: SFTPCodecLimits = .production) {
        self.limits = limits
    }

    func encodeInitialization() -> [UInt8] {
        framed(type: 1, body: encode(UInt32(3)))
    }

    func encodePathRequest(
        type: SFTPRequestType,
        id: UInt32,
        rawPath: [UInt8]
    ) throws -> [UInt8] {
        guard type == .realPath || type == .openDirectory else {
            throw SFTPProtocolError.invalidRequestType(type.rawValue)
        }
        guard rawPath.count <= limits.maximumPathByteCount else {
            throw SFTPProtocolError.pathTooLong(
                maximum: limits.maximumPathByteCount,
                actual: rawPath.count
            )
        }
        return try boundedFrame(
            type: type.rawValue,
            body: encode(id) + encodeString(rawPath)
        )
    }

    func encodeHandleRequest(
        type: SFTPRequestType,
        id: UInt32,
        handle: [UInt8]
    ) throws -> [UInt8] {
        guard type == .readDirectory || type == .close else {
            throw SFTPProtocolError.invalidRequestType(type.rawValue)
        }
        guard handle.count <= limits.maximumHandleByteCount else {
            throw SFTPProtocolError.handleTooLong(
                maximum: limits.maximumHandleByteCount,
                actual: handle.count
            )
        }
        return try boundedFrame(
            type: type.rawValue,
            body: encode(id) + encodeString(handle)
        )
    }

    func decodeFramedResponse(
        _ bytes: [UInt8],
        expectedRequestID: UInt32?
    ) throws -> SFTPResponse {
        guard bytes.count >= 4 else {
            throw SFTPProtocolError.truncatedLengthPrefix(actual: bytes.count)
        }
        let length = Self.decodeUInt32(bytes[0..<4])
        guard length >= 1 else {
            throw SFTPProtocolError.invalidPacketLength(length)
        }
        guard let payloadLength = Int(exactly: length),
              payloadLength <= Int.max - 4 else {
            throw SFTPProtocolError.invalidIntegerConversion
        }
        let packetByteCount = payloadLength + 4
        guard packetByteCount <= limits.maximumPacketByteCount else {
            throw SFTPProtocolError.packetTooLarge(
                maximum: limits.maximumPacketByteCount,
                actual: packetByteCount
            )
        }
        guard bytes.count >= packetByteCount else {
            throw SFTPProtocolError.truncatedPacket(
                expected: packetByteCount,
                actual: bytes.count
            )
        }
        guard bytes.count == packetByteCount else {
            throw SFTPProtocolError.trailingPacketBytes(bytes.count - packetByteCount)
        }

        let typeByte = bytes[4]
        let reader = SFTPByteReader(bytes: bytes, offset: 5, endOffset: packetByteCount)
        guard let type = PacketType(rawValue: typeByte) else {
            throw SFTPProtocolError.unexpectedPacketType(typeByte)
        }

        let result: (response: SFTPResponse, reader: SFTPByteReader)
        switch type {
        case .version:
            guard expectedRequestID == nil else {
                throw SFTPProtocolError.requestIDForbiddenForVersion
            }
            result = try decodeVersion(from: reader)
        case .status:
            result = try decodeStatus(from: reader, expectedRequestID: expectedRequestID)
        case .handle:
            result = try decodeHandle(from: reader, expectedRequestID: expectedRequestID)
        case .name:
            result = try decodeNames(from: reader, expectedRequestID: expectedRequestID)
        case .attributes:
            result = try decodeAttributesResponse(
                from: reader,
                expectedRequestID: expectedRequestID
            )
        }
        guard result.reader.remainingCount == 0 else {
            throw SFTPProtocolError.trailingPayloadBytes(result.reader.remainingCount)
        }
        return result.response
    }

    private func decodeVersion(
        from reader: SFTPByteReader
    ) throws -> (SFTPResponse, SFTPByteReader) {
        let versionResult = try reader.readUInt32()
        guard versionResult.value == 3 else {
            throw SFTPProtocolError.unsupportedVersion(versionResult.value)
        }
        let extensionsResult = try decodeExtensions(from: versionResult.reader)
        return (
            .version(versionResult.value, extensions: extensionsResult.values),
            extensionsResult.reader
        )
    }

    private func decodeExtensions(
        from initialReader: SFTPByteReader
    ) throws -> (values: [SFTPExtension], reader: SFTPByteReader) {
        var values: [SFTPExtension] = []
        var reader = initialReader
        while reader.remainingCount > 0 {
            guard values.count < limits.maximumExtensionCount else {
                throw SFTPProtocolError.tooManyExtensions(
                    maximum: limits.maximumExtensionCount,
                    actual: values.count + 1
                )
            }
            let nameResult = try reader.readString(maximumByteCount: limits.maximumPacketByteCount)
            let dataResult = try nameResult.reader.readString(
                maximumByteCount: limits.maximumPacketByteCount
            )
            values.append(SFTPExtension(name: nameResult.value, data: dataResult.value))
            reader = dataResult.reader
        }
        return (values, reader)
    }

    private func decodeStatus(
        from reader: SFTPByteReader,
        expectedRequestID: UInt32?
    ) throws -> (SFTPResponse, SFTPByteReader) {
        let idResult = try readAndValidateID(from: reader, expected: expectedRequestID)
        let codeResult = try idResult.reader.readUInt32()
        let messageResult = try codeResult.reader.readString(
            maximumByteCount: limits.maximumPacketByteCount
        )
        let languageResult = try messageResult.reader.readString(
            maximumByteCount: limits.maximumPacketByteCount
        )
        return (
            .status(
                id: idResult.id,
                code: SFTPStatusCode(rawValue: codeResult.value),
                message: messageResult.value,
                language: languageResult.value
            ),
            languageResult.reader
        )
    }

    private func decodeHandle(
        from reader: SFTPByteReader,
        expectedRequestID: UInt32?
    ) throws -> (SFTPResponse, SFTPByteReader) {
        let idResult = try readAndValidateID(from: reader, expected: expectedRequestID)
        let handleResult = try idResult.reader.readString(
            maximumByteCount: limits.maximumHandleByteCount,
            tooLong: { actual in
                .handleTooLong(maximum: limits.maximumHandleByteCount, actual: actual)
            }
        )
        return (.handle(id: idResult.id, value: handleResult.value), handleResult.reader)
    }

    private func decodeNames(
        from reader: SFTPByteReader,
        expectedRequestID: UInt32?
    ) throws -> (SFTPResponse, SFTPByteReader) {
        let idResult = try readAndValidateID(from: reader, expected: expectedRequestID)
        let countResult = try idResult.reader.readUInt32()
        guard let count = Int(exactly: countResult.value) else {
            throw SFTPProtocolError.invalidIntegerConversion
        }
        guard count <= limits.maximumNameCount else {
            throw SFTPProtocolError.tooManyNames(
                maximum: limits.maximumNameCount,
                actual: count
            )
        }

        var values: [SFTPName] = []
        values.reserveCapacity(count)
        var nextReader = countResult.reader
        for _ in 0..<count {
            let filenameResult = try nextReader.readString(
                maximumByteCount: limits.maximumFilenameByteCount
            )
            let longnameResult = try filenameResult.reader.readString(
                maximumByteCount: limits.maximumPacketByteCount
            )
            let attributesResult = try decodeAttributes(from: longnameResult.reader)
            values.append(
                SFTPName(
                    rawFilename: filenameResult.value,
                    attributes: attributesResult.value
                )
            )
            nextReader = attributesResult.reader
        }
        return (.names(id: idResult.id, values: values), nextReader)
    }

    private func decodeAttributesResponse(
        from reader: SFTPByteReader,
        expectedRequestID: UInt32?
    ) throws -> (SFTPResponse, SFTPByteReader) {
        let idResult = try readAndValidateID(from: reader, expected: expectedRequestID)
        let attributesResult = try decodeAttributes(from: idResult.reader)
        return (
            .attributes(id: idResult.id, value: attributesResult.value),
            attributesResult.reader
        )
    }

    private func readAndValidateID(
        from reader: SFTPByteReader,
        expected: UInt32?
    ) throws -> (id: UInt32, reader: SFTPByteReader) {
        guard let expected else {
            throw SFTPProtocolError.missingExpectedRequestID
        }
        let result = try reader.readUInt32()
        guard result.value == expected else {
            throw SFTPProtocolError.requestIDMismatch(expected: expected, actual: result.value)
        }
        return (result.value, result.reader)
    }

    private func decodeAttributes(
        from reader: SFTPByteReader
    ) throws -> (value: SFTPAttributes, reader: SFTPByteReader) {
        let flagResult = try reader.readUInt32()
        let flags = flagResult.value
        let unsupported = flags & ~AttributeFlag.supported
        guard unsupported == 0 else {
            throw SFTPProtocolError.unsupportedAttributeFlags(unsupported)
        }

        var nextReader = flagResult.reader
        let size: UInt64?
        if flags & AttributeFlag.size != 0 {
            let result = try nextReader.readUInt64()
            size = result.value
            nextReader = result.reader
        } else {
            size = nil
        }

        let userID: UInt32?
        let groupID: UInt32?
        if flags & AttributeFlag.userAndGroup != 0 {
            let userResult = try nextReader.readUInt32()
            let groupResult = try userResult.reader.readUInt32()
            userID = userResult.value
            groupID = groupResult.value
            nextReader = groupResult.reader
        } else {
            userID = nil
            groupID = nil
        }

        let permissions: UInt32?
        if flags & AttributeFlag.permissions != 0 {
            let result = try nextReader.readUInt32()
            permissions = result.value
            nextReader = result.reader
        } else {
            permissions = nil
        }

        let accessTime: UInt32?
        let modificationTime: UInt32?
        if flags & AttributeFlag.accessAndModificationTime != 0 {
            let accessResult = try nextReader.readUInt32()
            let modificationResult = try accessResult.reader.readUInt32()
            accessTime = accessResult.value
            modificationTime = modificationResult.value
            nextReader = modificationResult.reader
        } else {
            accessTime = nil
            modificationTime = nil
        }

        if flags & AttributeFlag.extended != 0 {
            nextReader = try consumeExtendedAttributes(from: nextReader)
        }

        return (
            SFTPAttributes(
                size: size,
                userID: userID,
                groupID: groupID,
                permissions: permissions,
                accessTime: accessTime,
                modificationTime: modificationTime
            ),
            nextReader
        )
    }

    private func consumeExtendedAttributes(
        from reader: SFTPByteReader
    ) throws -> SFTPByteReader {
        let countResult = try reader.readUInt32()
        guard let count = Int(exactly: countResult.value) else {
            throw SFTPProtocolError.invalidIntegerConversion
        }
        guard count <= limits.maximumExtensionCount else {
            throw SFTPProtocolError.tooManyExtensions(
                maximum: limits.maximumExtensionCount,
                actual: count
            )
        }
        var nextReader = countResult.reader
        for _ in 0..<count {
            let typeResult = try nextReader.readString(
                maximumByteCount: limits.maximumPacketByteCount
            )
            let dataResult = try typeResult.reader.readString(
                maximumByteCount: limits.maximumPacketByteCount
            )
            nextReader = dataResult.reader
        }
        return nextReader
    }

    private func boundedFrame(type: UInt8, body: [UInt8]) throws -> [UInt8] {
        let result = framed(type: type, body: body)
        guard result.count <= limits.maximumPacketByteCount else {
            throw SFTPProtocolError.packetTooLarge(
                maximum: limits.maximumPacketByteCount,
                actual: result.count
            )
        }
        return result
    }

    private func framed(type: UInt8, body: [UInt8]) -> [UInt8] {
        let payload = [type] + body
        return encode(UInt32(payload.count)) + payload
    }

    private func encodeString(_ value: [UInt8]) -> [UInt8] {
        encode(UInt32(value.count)) + value
    }

    private func encode(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }

    private static func decodeUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

private struct SFTPByteReader: Sendable {
    let bytes: [UInt8]
    let offset: Int
    let endOffset: Int

    var remainingCount: Int {
        endOffset - offset
    }

    func readUInt32() throws -> (value: UInt32, reader: Self) {
        let result = try read(count: 4)
        return (
            result.value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) },
            result.reader
        )
    }

    func readUInt64() throws -> (value: UInt64, reader: Self) {
        let result = try read(count: 8)
        return (
            result.value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) },
            result.reader
        )
    }

    func readString(
        maximumByteCount: Int,
        tooLong: ((Int) -> SFTPProtocolError)? = nil
    ) throws -> (value: [UInt8], reader: Self) {
        let lengthResult = try readUInt32()
        guard let count = Int(exactly: lengthResult.value) else {
            throw SFTPProtocolError.invalidIntegerConversion
        }
        guard count <= maximumByteCount else {
            throw tooLong?(count) ?? .stringTooLong(maximum: maximumByteCount, actual: count)
        }
        return try lengthResult.reader.read(count: count)
    }

    private func read(count: Int) throws -> (value: [UInt8], reader: Self) {
        guard count <= remainingCount else {
            throw SFTPProtocolError.truncatedValue(
                expected: count,
                remaining: remainingCount
            )
        }
        let nextOffset = offset + count
        return (
            Array(bytes[offset..<nextOffset]),
            Self(bytes: bytes, offset: nextOffset, endOffset: endOffset)
        )
    }
}
