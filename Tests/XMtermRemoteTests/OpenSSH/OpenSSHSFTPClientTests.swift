import Foundation
import Testing
@testable import XMtermRemote

@Suite("Serialized SFTP client lifecycle")
struct OpenSSHSFTPClientTests {
    @Test("[FILE-XFER-004] handshake and requests serialize monotonically increasing IDs")
    func serializesHandshakeAndRequests() async throws {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(104, sftpU32(1), sftpU32(1), sftpName("/home/user")),
            sftpPacket(102, sftpU32(2), sftpString([0xAA])),
            sftpPacket(101, sftpU32(3), sftpU32(0), sftpString([]), sftpString([]))
        ])
        let factory = ScriptedSFTPChannelFactory(channels: [channel])
        let client = OpenSSHSFTPClient(factory: factory)

        #expect(try await client.realPath([0x2E]) == Array("/home/user".utf8))
        let handle = try await client.openDirectory(Array("/home/user".utf8))
        #expect(handle == [0xAA])
        try await client.closeHandle(handle)

        let writes = await channel.recordedWrites()
        #expect(writes.count == 4)
        #expect(writes[0] == SFTPBinaryCodec().encodeInitialization())
        #expect(Array(writes[1][5..<9]) == sftpU32(1))
        #expect(Array(writes[2][5..<9]) == sftpU32(2))
        #expect(Array(writes[3][5..<9]) == sftpU32(3))
        #expect(await factory.makeCount() == 1)
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] status responses map without desynchronizing a healthy stream")
    func mapsStatusResponses() async {
        let channel = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(101, sftpU32(1), sftpU32(3), sftpString([]), sftpString([])),
            sftpPacket(101, sftpU32(2), sftpU32(2), sftpString([]), sftpString([]))
        ])
        let factory = ScriptedSFTPChannelFactory(channels: [channel])
        let client = OpenSSHSFTPClient(factory: factory)

        await #expect(throws: OpenSSHSFTPFailure.permissionDenied) {
            try await client.realPath(Array("/denied".utf8))
        }
        await #expect(throws: OpenSSHSFTPFailure.pathNotFound) {
            try await client.realPath(Array("/missing".utf8))
        }
        #expect(await channel.invalidationCount() == 0)
        #expect(await factory.makeCount() == 1)
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] ID mismatch is fatal and the next operation reconnects lazily")
    func requestIDMismatchReconnects() async throws {
        let desynchronized = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(104, sftpU32(99), sftpU32(1), sftpName("/wrong"))
        ])
        let replacement = ScriptedSFTPChannel(responses: [
            sftpPacket(2, sftpU32(3)),
            sftpPacket(104, sftpU32(2), sftpU32(1), sftpName("/recovered"))
        ])
        let factory = ScriptedSFTPChannelFactory(channels: [desynchronized, replacement])
        let client = OpenSSHSFTPClient(factory: factory)

        await #expect(throws: OpenSSHSFTPFailure.malformedResponse) {
            try await client.realPath([0x2E])
        }
        #expect(await desynchronized.invalidationCount() == 1)
        #expect(await factory.makeCount() == 1)

        #expect(try await client.realPath([0x2E]) == Array("/recovered".utf8))
        #expect(await factory.makeCount() == 2)
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] failed handshake invalidates its process before reporting")
    func failedHandshakeInvalidates() async {
        let channel = ScriptedSFTPChannel(responses: [sftpPacket(2, sftpU32(4))])
        let client = OpenSSHSFTPClient(
            factory: ScriptedSFTPChannelFactory(channels: [channel])
        )

        await #expect(throws: OpenSSHSFTPFailure.unsupportedProtocol) {
            try await client.realPath([0x2E])
        }
        #expect(await channel.invalidationCount() == 1)
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] cancellation after send invalidates and close settles")
    func cancellationInvalidatesAndCloseSettles() async {
        let channel = ScriptedSFTPChannel(
            responses: [sftpPacket(2, sftpU32(3))],
            blockWhenResponsesExhausted: true
        )
        let factory = ScriptedSFTPChannelFactory(channels: [channel])
        let client = OpenSSHSFTPClient(factory: factory)
        let task = Task {
            try await client.realPath([0x2E])
        }

        await channel.waitForReadCount(2)
        task.cancel()
        await #expect(throws: OpenSSHSFTPFailure.cancelled) {
            try await task.value
        }
        #expect(await channel.invalidationCount() == 1)

        await client.close()
        await client.close()
        #expect(await channel.closeCount() == 0)
        await #expect(throws: OpenSSHSFTPFailure.transportUnavailable) {
            try await client.realPath([0x2E])
        }
    }
}

actor ScriptedSFTPChannelFactory: SFTPProcessChannelFactory {
    private var channels: [ScriptedSFTPChannel]
    private var count = 0

    init(channels: [ScriptedSFTPChannel]) {
        self.channels = channels
    }

    func makeChannel() throws -> any SFTPProcessChannel {
        guard !channels.isEmpty else { throw OpenSSHSFTPFailure.transportUnavailable }
        count += 1
        return channels.removeFirst()
    }

    func makeCount() -> Int { count }
}

actor ScriptedSFTPChannel: SFTPProcessChannel {
    private var responses: [[UInt8]]
    private let blockWhenResponsesExhausted: Bool
    private var writes: [[UInt8]] = []
    private var invalidations = 0
    private var closes = 0
    private var reads = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(responses: [[UInt8]], blockWhenResponsesExhausted: Bool = false) {
        self.responses = responses
        self.blockWhenResponsesExhausted = blockWhenResponsesExhausted
    }

    func start() async throws {}

    func write(_ bytes: [UInt8]) async throws {
        try Task.checkCancellation()
        writes.append(bytes)
    }

    func readPacket(maximumByteCount: Int) async throws -> [UInt8] {
        reads += 1
        let completedWaiters = readWaiters.filter { $0.0 <= reads }
        readWaiters.removeAll { $0.0 <= reads }
        for waiter in completedWaiters { waiter.1.resume() }

        if !responses.isEmpty {
            return responses.removeFirst()
        }
        guard blockWhenResponsesExhausted else {
            throw OpenSSHSFTPFailure.transportUnavailable
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        } onCancel: {
            Task { await self.releaseBlockedRead() }
        }
        throw CancellationError()
    }

    func invalidate() async {
        invalidations += 1
        releaseBlockedRead()
    }

    func close() async {
        closes += 1
        releaseBlockedRead()
    }

    func recordedWrites() -> [[UInt8]] { writes }
    func invalidationCount() -> Int { invalidations }
    func closeCount() -> Int { closes }

    func waitForReadCount(_ expected: Int) async {
        guard reads < expected else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append((expected, continuation))
        }
    }

    private func releaseBlockedRead() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

func sftpPacket(_ type: UInt8, _ parts: [UInt8]...) -> [UInt8] {
    let payload = [type] + parts.flatMap { $0 }
    return sftpU32(UInt32(payload.count)) + payload
}

func sftpU32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value)
    ]
}

func sftpU64(_ value: UInt64) -> [UInt8] {
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

func sftpString(_ value: [UInt8]) -> [UInt8] {
    sftpU32(UInt32(value.count)) + value
}

func sftpName(_ value: String) -> [UInt8] {
    sftpString(Array(value.utf8)) + sftpString([]) + sftpU32(0)
}
