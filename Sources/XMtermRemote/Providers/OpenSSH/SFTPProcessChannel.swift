protocol SFTPProcessChannel: Sendable {
    func start() async throws
    func write(_ bytes: [UInt8]) async throws
    func readPacket(maximumByteCount: Int) async throws -> [UInt8]
    func invalidate() async
    func close() async
}

protocol SFTPProcessChannelFactory: Sendable {
    func makeChannel() async throws -> any SFTPProcessChannel
}
