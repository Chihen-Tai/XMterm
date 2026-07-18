enum SFTPDirectoryReadResult: Equatable, Sendable {
    case names([SFTPName], packetByteCount: Int)
    case endOfDirectory(packetByteCount: Int)
}

actor OpenSSHSFTPClient {
    private let factory: any SFTPProcessChannelFactory
    private let codec: SFTPBinaryCodec
    private var channel: (any SFTPProcessChannel)?
    private var nextRequestID: UInt32 = 1
    private var isClosed = false

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
            throw mapStatus(code)
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
            throw mapStatus(code)
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
            throw mapStatus(code)
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
            throw mapStatus(code)
        default:
            await invalidateCurrentChannel()
            throw OpenSSHSFTPFailure.malformedResponse
        }
    }

    func invalidate() async {
        await invalidateCurrentChannel()
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let current = channel
        channel = nil
        await current?.close()
    }

    private func request(
        encodedBy encodeRequest: (UInt32) throws -> [UInt8]
    ) async throws -> (value: SFTPResponse, packetByteCount: Int) {
        guard !isClosed else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw OpenSSHSFTPFailure.cancelled
        }

        let activeChannel = try await connectedChannel()
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
            try await activeChannel.write(packet)
            let responseBytes = try await activeChannel.readPacket(
                maximumByteCount: codec.limits.maximumPacketByteCount
            )
            let response = try codec.decodeFramedResponse(
                responseBytes,
                expectedRequestID: requestID
            )
            return (response, responseBytes.count)
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
            _ = try codec.decodeFramedResponse(versionBytes, expectedRequestID: nil)
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
        channel = candidate
        return candidate
    }

    private func invalidateCurrentChannel() async {
        let current = channel
        channel = nil
        await current?.invalidate()
    }

    private func mapStatus(_ code: SFTPStatusCode) -> OpenSSHSFTPFailure {
        switch code {
        case .noSuchFile: .pathNotFound
        case .permissionDenied: .permissionDenied
        case .badMessage: .malformedResponse
        case .noConnection, .connectionLost: .transportUnavailable
        case .operationUnsupported: .unsupportedProtocol
        case .ok, .endOfFile, .failure, .unknown: .unknown
        }
    }

    private func mapProtocolError(_ error: SFTPProtocolError) -> OpenSSHSFTPFailure {
        switch error {
        case .packetTooLarge, .stringTooLong, .pathTooLong, .handleTooLong,
             .tooManyNames, .tooManyExtensions:
            .limitExceeded
        case .unsupportedVersion:
            .unsupportedProtocol
        default:
            .malformedResponse
        }
    }
}
