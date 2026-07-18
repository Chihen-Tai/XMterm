enum SFTPDirectoryReadResult: Equatable, Sendable {
    case names([SFTPName], packetByteCount: Int)
    case endOfDirectory(packetByteCount: Int)
}

struct SFTPFileHandle: Equatable, Sendable {
    let bytes: [UInt8]
    let connectionGeneration: UInt64
}

actor OpenSSHSFTPClient {
    private let factory: any SFTPProcessChannelFactory
    private let codec: SFTPBinaryCodec
    private var channel: (any SFTPProcessChannel)?
    private var nextRequestID: UInt32 = 1
    private var connectionGeneration: UInt64 = 0
    private var advertisedPosixRename = false
    private var isClosed = false

    var supportsPosixRename: Bool {
        advertisedPosixRename
    }

    init(
        factory: any SFTPProcessChannelFactory,
        codec: SFTPBinaryCodec = SFTPBinaryCodec()
    ) {
        self.factory = factory
        self.codec = codec
    }

    func realPath(_ rawPath: [UInt8]) async throws -> [UInt8] {
        let response = try await request { id in
            try codec.encodePathRequest(type: .realPath, id: id, rawPath: rawPath)
        }
        switch response.value {
        case .names(_, let values):
            guard values.count == 1 else {
                await invalidateCurrentChannel()
                throw OpenSSHSFTPFailure.malformedResponse
            }
            return values[0].rawFilename
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func openDirectory(_ rawPath: [UInt8]) async throws -> [UInt8] {
        let response = try await request { id in
            try codec.encodePathRequest(type: .openDirectory, id: id, rawPath: rawPath)
        }
        switch response.value {
        case .handle(_, let value):
            return value
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func readDirectory(_ handle: [UInt8]) async throws -> SFTPDirectoryReadResult {
        let response = try await request { id in
            try codec.encodeHandleRequest(type: .readDirectory, id: id, handle: handle)
        }
        switch response.value {
        case .names(_, let values):
            return .names(values, packetByteCount: response.packetByteCount)
        case .status(_, .endOfFile, _, _):
            return .endOfDirectory(packetByteCount: response.packetByteCount)
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func closeHandle(_ handle: [UInt8]) async throws {
        let response = try await request { id in
            try codec.encodeHandleRequest(type: .close, id: id, handle: handle)
        }
        switch response.value {
        case .status(_, .ok, _, _):
            return
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func openFile(_ rawPath: [UInt8], flags: SFTPOpenFlags) async throws -> SFTPFileHandle {
        let response = try await request { id in
            try codec.encodeOpenRequest(id: id, rawPath: rawPath, flags: flags)
        }
        switch response.value {
        case .handle(_, let value):
            return SFTPFileHandle(
                bytes: value,
                connectionGeneration: response.connectionGeneration
            )
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func readFile(
        _ handle: SFTPFileHandle,
        offset: UInt64,
        length: Int
    ) async throws -> [UInt8]? {
        let response = try await request(requiredGeneration: handle.connectionGeneration) { id in
            try codec.encodeReadRequest(
                id: id,
                handle: handle.bytes,
                offset: offset,
                length: length
            )
        }
        switch response.value {
        case .data(_, let value):
            guard !value.isEmpty else {
                await invalidateCurrentChannel()
                throw OpenSSHSFTPFailure.malformedResponse
            }
            return value
        case .status(_, .endOfFile, _, _):
            return nil
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func writeFile(
        _ handle: SFTPFileHandle,
        offset: UInt64,
        data: [UInt8]
    ) async throws {
        guard !data.isEmpty else { return }
        let response = try await request(requiredGeneration: handle.connectionGeneration) { id in
            try codec.encodeWriteRequest(
                id: id,
                handle: handle.bytes,
                offset: offset,
                data: data
            )
        }
        try await acceptOK(response.value)
    }

    func closeFile(_ handle: SFTPFileHandle) async throws {
        let response = try await request(requiredGeneration: handle.connectionGeneration) { id in
            try codec.encodeHandleRequest(type: .close, id: id, handle: handle.bytes)
        }
        try await acceptOK(response.value)
    }

    /// Settles a handle after a stream operation has already failed. A handle
    /// from the current synchronized channel receives one structured CLOSE;
    /// otherwise no new channel is opened. Any uncertainty while closing is
    /// fatal to the current channel.
    func settleFileHandleAfterFailure(_ handle: SFTPFileHandle) async {
        guard !isClosed,
              channel != nil,
              handle.connectionGeneration == connectionGeneration else {
            return
        }
        do {
            try await closeFile(handle)
        } catch {
            await invalidateCurrentChannel()
        }
    }

    func lstat(_ rawPath: [UInt8]) async throws -> SFTPAttributes {
        let response = try await request { id in
            try codec.encodePathRequest(type: .lstat, id: id, rawPath: rawPath)
        }
        switch response.value {
        case .attributes(_, let value):
            return value
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func setStat(_ rawPath: [UInt8], attributes: SFTPAttributes) async throws {
        let response = try await request { id in
            try codec.encodeSetStatRequest(id: id, rawPath: rawPath, attributes: attributes)
        }
        try await acceptOK(response.value)
    }

    func removeFile(_ rawPath: [UInt8]) async throws {
        let response = try await request { id in
            try codec.encodePathRequest(type: .remove, id: id, rawPath: rawPath)
        }
        try await acceptOK(response.value)
    }

    func createDirectory(_ rawPath: [UInt8]) async throws {
        let response = try await request { id in
            try codec.encodeMakeDirectoryRequest(id: id, rawPath: rawPath)
        }
        try await acceptOK(response.value)
    }

    func removeDirectory(_ rawPath: [UInt8]) async throws {
        let response = try await request { id in
            try codec.encodePathRequest(type: .removeDirectory, id: id, rawPath: rawPath)
        }
        try await acceptOK(response.value)
    }

    func rename(_ source: [UInt8], to destination: [UInt8]) async throws {
        let response = try await request { id in
            try codec.encodeRenameRequest(id: id, source: source, destination: destination)
        }
        try await acceptOK(response.value)
    }

    func posixRename(_ source: [UInt8], to destination: [UInt8]) async throws {
        guard try await serverSupportsPosixRename() else {
            throw OpenSSHSFTPFailure.unsupportedProtocol
        }
        let response = try await request { id in
            try codec.encodePosixRenameRequest(id: id, source: source, destination: destination)
        }
        try await acceptOK(response.value)
    }

    func serverSupportsPosixRename() async throws -> Bool {
        _ = try await connectedChannel()
        return advertisedPosixRename
    }

    func invalidate() async {
        await invalidateCurrentChannel()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let current = channel
        channel = nil
        advertisedPosixRename = false
        connectionGeneration &+= 1
        await current?.close()
    }

    private func request(
        requiredGeneration: UInt64? = nil,
        encodedBy encodeRequest: (UInt32) throws -> [UInt8]
    ) async throws -> (
        value: SFTPResponse,
        packetByteCount: Int,
        connectionGeneration: UInt64
    ) {
        guard !isClosed else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw OpenSSHSFTPFailure.cancelled
        }

        let activeChannel: any SFTPProcessChannel
        if let requiredGeneration {
            guard channel != nil, requiredGeneration == connectionGeneration else {
                throw OpenSSHSFTPFailure.transportUnavailable
            }
            activeChannel = try await connectedChannel()
        } else {
            activeChannel = try await connectedChannel()
        }
        let requestGeneration = connectionGeneration
        let requestID = nextRequestID
        nextRequestID = requestID == UInt32.max ? 1 : requestID + 1
        let packet: [UInt8]
        do {
            packet = try encodeRequest(requestID)
        } catch let error as SFTPProtocolError {
            throw mapProtocolError(error)
        } catch {
            throw OpenSSHSFTPFailure.unknown
        }

        do {
            try Task.checkCancellation()
        } catch {
            throw OpenSSHSFTPFailure.cancelled
        }

        do {
            try await activeChannel.write(packet)
            let responseBytes = try await activeChannel.readPacket(
                maximumByteCount: codec.limits.maximumPacketByteCount
            )
            let response = try codec.decodeFramedResponse(
                responseBytes,
                expectedRequestID: requestID
            )
            guard !isClosed, requestGeneration == connectionGeneration else {
                throw OpenSSHSFTPFailure.transportUnavailable
            }
            return (response, responseBytes.count, requestGeneration)
        } catch is CancellationError {
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.cancelled
        } catch let failure as OpenSSHSFTPFailure {
            await invalidateCurrentChannel()
            throw failure
        } catch let error as SFTPProtocolError {
            await invalidateCurrentChannel()
            throw mapProtocolError(error)
        } catch {
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.unknown
        }
    }

    private func connectedChannel() async throws -> any SFTPProcessChannel {
        if let channel { return channel }
        guard !isClosed else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }

        let candidate: any SFTPProcessChannel
        do {
            candidate = try await factory.makeChannel()
        } catch is CancellationError {
            throw OpenSSHSFTPFailure.cancelled
        } catch let failure as OpenSSHSFTPFailure {
            throw failure
        } catch {
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        do {
            try await candidate.start()
            try await candidate.write(codec.encodeInitialization())
            let versionBytes = try await candidate.readPacket(
                maximumByteCount: codec.limits.maximumPacketByteCount
            )
            let version = try codec.decodeFramedResponse(versionBytes, expectedRequestID: nil)
            advertisedPosixRename = version.advertisesPosixRename
        } catch is CancellationError {
            await candidate.invalidate()
            throw OpenSSHSFTPFailure.cancelled
        } catch let failure as OpenSSHSFTPFailure {
            await candidate.invalidate()
            throw failure
        } catch let error as SFTPProtocolError {
            await candidate.invalidate()
            if case .unsupportedVersion = error {
                throw OpenSSHSFTPFailure.unsupportedProtocol
            }
            throw OpenSSHSFTPFailure.malformedResponse
        } catch {
            await candidate.invalidate()
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        connectionGeneration &+= 1
        channel = candidate
        return candidate
    }

    private func invalidateCurrentChannel() async {
        let current = channel
        channel = nil
        advertisedPosixRename = false
        connectionGeneration &+= 1
        await current?.invalidate()
    }

    private func acceptOK(_ response: SFTPResponse) async throws {
        switch response {
        case .status(_, .ok, _, _):
            return
        case .status(_, let code, _, _):
            throw await mappedStatusFailure(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    private func mapStatus(_ code: SFTPStatusCode) -> OpenSSHSFTPFailure {
        switch code {
        case .noSuchFile: .pathNotFound
        case .permissionDenied: .permissionDenied
        case .badMessage: .malformedResponse
        case .noConnection, .connectionLost: .transportUnavailable
        case .operationUnsupported: .unsupportedProtocol
        case .failure, .unknown: .providerFailure
        case .ok, .endOfFile: .unknown
        }
    }

    private func mappedStatusFailure(_ code: SFTPStatusCode) async -> OpenSSHSFTPFailure {
        switch code {
        case .badMessage, .noConnection, .connectionLost:
            await invalidateCurrentChannel()
        default:
            break
        }
        return mapStatus(code)
    }

    private func mapProtocolError(_ error: SFTPProtocolError) -> OpenSSHSFTPFailure {
        switch error {
        case .packetTooLarge, .stringTooLong, .pathTooLong, .handleTooLong,
             .tooManyNames, .tooManyExtensions, .invalidChunkByteCount:
            .limitExceeded
        case .unsupportedVersion:
            .unsupportedProtocol
        default:
            .malformedResponse
        }
    }
}
