import Foundation
import Testing
import Darwin
@testable import XMtermRemote

@Suite("Foundation SFTP subsystem process")
struct OpenSSHSubsystemProcessTests {
    @Test("[FILE-STATE-001, FILE-XFER-004] stderr diagnostics are bounded and conservatively classified")
    func boundsAndClassifiesDiagnostics() {
        let hostKey = BoundedOpenSSHDiagnostic(maximumByteCount: 64)
        hostKey.append(Array("Host key verification failed.\nsecret-trailing-data".utf8))
        #expect(hostKey.byteCount <= 64)
        #expect(hostKey.classifiedFailure() == .hostKeyVerificationFailed)

        let authentication = BoundedOpenSSHDiagnostic(maximumByteCount: 64)
        authentication.append(Array("Permission denied (publickey).".utf8))
        #expect(authentication.classifiedFailure() == .authenticationRequired)

        let interactive = BoundedOpenSSHDiagnostic(maximumByteCount: 64)
        interactive.append(Array("keyboard-interactive authentication is required".utf8))
        #expect(interactive.classifiedFailure() == .interactiveAuthenticationUnsupported)

        let batchModeInteractive = BoundedOpenSSHDiagnostic(maximumByteCount: 128)
        batchModeInteractive.append(
            Array("Permission denied (publickey,keyboard-interactive).".utf8)
        )
        #expect(
            batchModeInteractive.classifiedFailure() == .interactiveAuthenticationUnsupported
        )

        let localKeyPermission = BoundedOpenSSHDiagnostic(maximumByteCount: 128)
        localKeyPermission.append(
            Array("Load key \"/private/key\": Permission denied".utf8)
        )
        #expect(localKeyPermission.classifiedFailure() == nil)

        let unknown = BoundedOpenSSHDiagnostic(maximumByteCount: 8)
        unknown.append(Array(repeating: 0x61, count: 100_000))
        #expect(unknown.byteCount == 8)
        #expect(unknown.classifiedFailure() == nil)
    }

    @Test("[FILE-XFER-004] local sftp-server runs through production framing and is reaped on close")
    func localServerRoundTripAndReaping() async throws {
        let serverPath = "/usr/libexec/sftp-server"
        guard FileManager.default.isExecutableFile(atPath: serverPath) else { return }

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmterm-sftp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("hello".utf8).write(to: fixture.appendingPathComponent("ordinary file.txt"))
        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.appendingPathComponent("link"),
            withDestinationURL: fixture.appendingPathComponent("ordinary file.txt")
        )
        try Data().write(to: fixture.appendingPathComponent("-line\nname"))
        let createdNonUTF8Name = try createRawNamedFile(
            directory: fixture,
            name: [0xFF, 0x0A, 0x2D]
        )

        let channel = FoundationSFTPProcessChannel(
            launch: .init(
                executablePath: serverPath,
                arguments: [],
                currentDirectoryURL: fixture
            ),
            timeouts: .init(request: .seconds(5), settlement: .seconds(2))
        )
        let provider = OpenSSHSFTPRemoteFileProvider(
            client: OpenSSHSFTPClient(factory: StaticSFTPProcessChannelFactory(channel: channel))
        )

        let initial = try await provider.resolveInitialDirectory()
        #expect(initial.rawBytes.first == 0x2F)
        #expect(initial.components.last?.rawBytes == Array(fixture.lastPathComponent.utf8))
        let listing = try await provider.listDirectory(initial)
        let rawNames = listing.entries.map(\.name.rawBytes)
        #expect(rawNames.contains(Array("ordinary file.txt".utf8)))
        #expect(rawNames.contains(Array("folder".utf8)))
        #expect(rawNames.contains(Array("link".utf8)))
        #expect(rawNames.contains(Array("-line\nname".utf8)))
        if createdNonUTF8Name {
            #expect(rawNames.contains([0xFF, 0x0A, 0x2D]))
        }
        #expect(listing.entries.first { $0.name.rawBytes == Array("folder".utf8) }?.kind == .directory)
        #expect(listing.entries.first { $0.name.rawBytes == Array("link".utf8) }?.kind == .symbolicLink)
        #expect(await channel.isRunningForTesting)

        await provider.close()
        #expect(!(await channel.isRunningForTesting))
        #expect(await channel.processIdentifierForTesting == nil)
    }

    @Test("[FILE-STATE-001] cancelled local read tears down and reaps the process")
    func cancellationReapsProcess() async throws {
        let serverPath = "/usr/libexec/sftp-server"
        guard FileManager.default.isExecutableFile(atPath: serverPath) else { return }

        let channel = FoundationSFTPProcessChannel(
            launch: .init(executablePath: serverPath, arguments: []),
            timeouts: .init(request: .seconds(30), settlement: .seconds(2))
        )
        try await channel.start()
        let readTask = Task {
            try await channel.readPacket(maximumByteCount: 1_024 * 1_024)
        }
        try await Task.sleep(for: .milliseconds(20))
        readTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await readTask.value
        }
        await channel.invalidate()
        #expect(!(await channel.isRunningForTesting))
    }

    @Test("[FILE-STATE-001] stalled local read times out and can be settled")
    func timeoutSettlesProcess() async throws {
        let serverPath = "/usr/libexec/sftp-server"
        guard FileManager.default.isExecutableFile(atPath: serverPath) else { return }

        let channel = FoundationSFTPProcessChannel(
            launch: .init(executablePath: serverPath, arguments: []),
            timeouts: .init(request: .milliseconds(20), settlement: .seconds(2))
        )
        try await channel.start()
        await #expect(throws: OpenSSHSFTPFailure.timeout) {
            try await channel.readPacket(maximumByteCount: 1_024 * 1_024)
        }
        await channel.invalidate()
        #expect(!(await channel.isRunningForTesting))
    }

    @Test("[FILE-STATE-001, FILE-XFER-004] stalled stdin write times out without wedging teardown")
    func stalledWriteTimesOutAndReapsProcess() async throws {
        let sleepPath = "/bin/sleep"
        guard FileManager.default.isExecutableFile(atPath: sleepPath) else { return }

        let channel = FoundationSFTPProcessChannel(
            launch: .init(executablePath: sleepPath, arguments: ["1"]),
            timeouts: .init(request: .milliseconds(20), settlement: .seconds(2))
        )
        try await channel.start()
        let processIdentifier = try #require(await channel.processIdentifierForTesting)

        await #expect(throws: OpenSSHSFTPFailure.timeout) {
            try await channel.write(Array(repeating: 0x41, count: 1_024 * 1_024))
        }
        await channel.invalidate()

        #expect(!(await channel.isRunningForTesting))
        #expect(Darwin.kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }
}

private actor StaticSFTPProcessChannelFactory: SFTPProcessChannelFactory {
    let channel: FoundationSFTPProcessChannel

    init(channel: FoundationSFTPProcessChannel) {
        self.channel = channel
    }

    func makeChannel() -> any SFTPProcessChannel { channel }
}

private func createRawNamedFile(directory: URL, name: [UInt8]) throws -> Bool {
    let pathBytes = Array(directory.path.utf8) + [0x2F] + name + [0]
    let descriptor = pathBytes.withUnsafeBytes { rawBuffer -> Int32 in
        let pointer = rawBuffer.bindMemory(to: CChar.self).baseAddress!
        return Darwin.open(pointer, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { return false }
    guard Darwin.close(descriptor) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    return true
}
