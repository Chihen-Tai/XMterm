import Darwin
import Foundation
import Testing
@testable import XMtermRemote

@Suite("Local transfer staging")
struct LocalTransferStagingTests {
    @Test("Download staging exclusively creates a 0600 same-directory partial file")
    func createsExclusiveUserOnlySameDirectoryStaging() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let attemptID = UUID()
        let itemID = RemoteTransferAttemptItemID()

        let staged = try await staging.createDownloadStaging(
            in: directoryIdentity,
            finalName: try RemotePathComponent(rawBytes: Array("download.txt".utf8)),
            attemptID: attemptID,
            itemID: itemID
        )

        #expect(
            standardizedPath(staged.stagingURL.deletingLastPathComponent())
                == standardizedPath(fixture.root)
        )
        #expect(fixture.mode(of: staged.stagingURL) & 0o777 == 0o600)
        await #expect(throws: RemoteFileError(category: .alreadyExists)) {
            _ = try await staging.createDownloadStaging(
                in: directoryIdentity,
                finalName: try RemotePathComponent(rawBytes: Array("download.txt".utf8)),
                attemptID: attemptID,
                itemID: itemID
            )
        }
    }

    @Test("Download staging rejects unsafe local injection names")
    func rejectsUnsafeLocalInjectionNames() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let unsafeNames: [[UInt8]] = [
            Array(".".utf8),
            Array("..".utf8),
            Array("/absolute".utf8),
            Array("nested/name".utf8)
        ]

        for rawName in unsafeNames {
            await #expect(throws: RemoteFileError(category: .invalidOperation)) {
                _ = try await staging.createDownloadStaging(
                    in: directoryIdentity,
                    finalNameRawBytes: rawName,
                    attemptID: UUID(),
                    itemID: RemoteTransferAttemptItemID()
                )
            }
        }
        await #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try await staging.createDownloadStaging(
                in: directoryIdentity,
                finalNameRawBytes: [0x00],
                attemptID: UUID(),
                itemID: RemoteTransferAttemptItemID()
            )
        }
    }

    @Test("Remote components map to deterministic bijective local names")
    func mapsRemoteComponentsToEscapedLocalNames() throws {
        #expect(
            try LocalTransferLocalNameCodec.localName(
                forRawBytes: Array("測試.txt".utf8)
            ) == "測試.txt"
        )
        #expect(
            try LocalTransferLocalNameCodec.localName(
                forRawBytes: Array("report~1.txt".utf8)
            ) == "report~7E1.txt"
        )
        #expect(
            try LocalTransferLocalNameCodec.localName(
                forRawBytes: [0x66, 0x80, 0x6F]
            ) == "f~80o"
        )
    }

    @Test("Invalid-byte remote component stages under its escaped local name")
    func stagesInvalidByteRemoteNameUnderEscapedLocalName() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)

        let staged = try await staging.createDownloadStaging(
            in: directoryIdentity,
            finalNameRawBytes: [0x66, 0x80, 0x6F],
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        #expect(staged.finalName == "f~80o")
        try await staging.cleanup(staged)
    }

    @Test("Publication is atomic for a new destination and preserves mode")
    func publishesNewDestinationAtomically() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let finalURL = fixture.root.appending(path: "published.sh")
        let staged = try await staging.createDownloadStaging(
            in: directoryIdentity,
            finalName: try RemotePathComponent(rawBytes: Array("published.sh".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        try await staging.write(Data("echo staged\n".utf8), to: staged)
        #expect(!fixture.existsNoFollow(finalURL))
        try await staging.publish(staged, expectedByteCount: 12, mode: 0o755)

        #expect(try String(contentsOf: finalURL, encoding: .utf8) == "echo staged\n")
        #expect(fixture.mode(of: finalURL) & 0o777 == 0o755)
        #expect(!fixture.existsNoFollow(staged.stagingURL))
    }

    @Test("Existing destination and symlink destination are preserved")
    func preservesExistingDestinations() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let existing = fixture.root.appending(path: "existing.txt")
        let symlink = fixture.root.appending(path: "link.txt")
        let target = fixture.root.appending(path: "target.txt")
        try "original".write(to: existing, atomically: false, encoding: .utf8)
        try "target".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: target
        )

        for name in ["existing.txt", "link.txt"] {
            let staged = try await staging.createDownloadStaging(
                in: directoryIdentity,
                finalName: try RemotePathComponent(rawBytes: Array(name.utf8)),
                attemptID: UUID(),
                itemID: RemoteTransferAttemptItemID()
            )
            try await staging.write(Data("replacement".utf8), to: staged)
            await #expect(throws: RemoteFileError(category: .alreadyExists)) {
                try await staging.publish(staged, expectedByteCount: 11, mode: 0o600)
            }
            try await staging.cleanup(staged)
        }

        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
        #expect(try String(contentsOf: target, encoding: .utf8) == "target")
        #expect(fixture.isSymlink(symlink))
    }

    @Test("Collision between staging and publication preserves the raced destination")
    func preservesDestinationCreatedDuringRace() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let finalURL = fixture.root.appending(path: "race.txt")
        let staged = try await staging.createDownloadStaging(
            in: directoryIdentity,
            finalName: try RemotePathComponent(rawBytes: Array("race.txt".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        try await staging.write(Data("staged".utf8), to: staged)
        try "winner".write(to: finalURL, atomically: false, encoding: .utf8)
        await #expect(throws: RemoteFileError(category: .alreadyExists)) {
            try await staging.publish(staged, expectedByteCount: 6, mode: 0o600)
        }

        #expect(try String(contentsOf: finalURL, encoding: .utf8) == "winner")
        try await staging.cleanup(staged)
    }

    @Test("Staging writes reject chunks larger than the transfer bound")
    func rejectsOversizedWriteChunks() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let staged = try await staging.createDownloadStaging(
            in: directoryIdentity,
            finalName: try RemotePathComponent(rawBytes: Array("bounded.bin".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        try await staging.write(
            Data(repeating: 0x41, count: RemoteFileTransferLimits.maximumChunkByteCount),
            to: staged
        )
        await #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try await staging.write(
                Data(repeating: 0x42, count: RemoteFileTransferLimits.maximumChunkByteCount + 1),
                to: staged
            )
        }
        try await staging.cleanup(staged)
    }

    @Test("Staging write fails closed when syscall reports zero progress")
    func rejectsZeroProgressWriteForNonemptyData() async throws {
        let syscalls = ScriptedLocalTransferSyscalls(zeroProgressWrite: true)
        let staging = DarwinLocalTransferStaging(syscalls: syscalls)
        let staged = try await staging.createDownloadStaging(
            in: fixtureIdentity(kind: .directory),
            finalName: try RemotePathComponent(rawBytes: Array("zero-write.bin".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        await #expect(throws: RemoteFileError(category: .providerFailure)) {
            try await staging.write(Data([0x41]), to: staged)
        }
        try await staging.cleanup(staged)
    }

    @Test("Cancel and failure cleanup remove only attempt-owned staging")
    func cleanupRemovesOnlyOwnedStaging() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let directoryIdentity = try fixture.identity(for: fixture.root, kind: .directory)
        let unrelated = fixture.root.appending(path: ".xmterm-partial-unrelated")
        try "keep".write(to: unrelated, atomically: false, encoding: .utf8)
        let staged = try await staging.createDownloadStaging(
            in: directoryIdentity,
            finalName: try RemotePathComponent(rawBytes: Array("cancelled.txt".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        try await staging.write(Data("partial".utf8), to: staged)
        try await staging.cleanup(staged)

        #expect(!fixture.existsNoFollow(staged.stagingURL))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
    }

    @Test("Local source validation rejects identity, symlink, package, unreadable, and nonregular changes")
    func revalidatesLocalSourceIdentityAndKind() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let source = fixture.root.appending(path: "source.txt")
        try "source".write(to: source, atomically: false, encoding: .utf8)
        let originalIdentity = try fixture.identity(for: source, kind: .regularFile)

        let valid = try await staging.openValidatedSource(originalIdentity)
        #expect(valid.observedSize == 6)
        #expect(valid.permissions == 0o644)
        try await staging.closeSource(valid)

        try FileManager.default.removeItem(at: source)
        try "replacement".write(to: source, atomically: false, encoding: .utf8)
        await #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try await staging.openValidatedSource(originalIdentity)
        }

        let symlink = fixture.root.appending(path: "symlink-source.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        await #expect(throws: RemoteFileError(category: .unsupportedEntry)) {
            _ = try await staging.openValidatedSource(
                try fixture.identity(for: symlink, kind: .regularFile)
            )
        }

        let package = fixture.root.appending(path: "Package.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        await #expect(throws: RemoteFileError(category: .unsupportedEntry)) {
            _ = try await staging.openValidatedSource(
                try fixture.identity(for: package, kind: .directory)
            )
        }

        let unreadable = fixture.root.appending(path: "unreadable.txt")
        try "locked".write(to: unreadable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: unreadable.path(percentEncoded: false)
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadable.path(percentEncoded: false)
            )
        }
        await #expect(throws: RemoteFileError(category: .permissionDenied)) {
            _ = try await staging.openValidatedSource(
                try fixture.identity(for: unreadable, kind: .regularFile)
            )
        }

        let fifo = fixture.root.appending(path: "fifo")
        #expect(Darwin.mkfifo(fifo.path(percentEncoded: false), 0o600) == 0)
        await #expect(throws: RemoteFileError(category: .unsupportedEntry)) {
            _ = try await staging.openValidatedSource(
                try fixture.identity(for: fifo, kind: .regularFile)
            )
        }
    }

    @Test("Validated source reads are bounded and report EOF only after positive reads")
    func readsValidatedSourceWithBoundedChunks() async throws {
        let fixture = try LocalTransferStagingFixture()
        defer { fixture.remove() }
        let staging = DarwinLocalTransferStaging()
        let source = fixture.root.appending(path: "chunks.bin")
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let opened = try await staging.openValidatedSource(
            try fixture.identity(for: source, kind: .regularFile)
        )

        #expect(try await staging.read(opened, maximumBytes: 0) == Data())
        #expect(try await staging.read(opened, maximumBytes: 5) == Data(payload.prefix(5)))
        #expect(
            try await staging.read(
                opened,
                maximumBytes: RemoteFileTransferLimits.maximumChunkByteCount
            ) == Data(payload.dropFirst(5).prefix(RemoteFileTransferLimits.maximumChunkByteCount))
        )
        #expect(
            try await staging.read(
                opened,
                maximumBytes: RemoteFileTransferLimits.maximumChunkByteCount
            ) == Data(payload.dropFirst(5 + RemoteFileTransferLimits.maximumChunkByteCount))
        )
        #expect(try await staging.read(opened, maximumBytes: 1) == nil)
        await #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try await staging.read(
                opened,
                maximumBytes: RemoteFileTransferLimits.maximumChunkByteCount + 1
            )
        }
        try await staging.closeSource(opened)
    }

    @Test("Collision after file close does not close a reused descriptor twice")
    func collisionAfterFileCloseDoesNotCloseReusedDescriptorTwice() async throws {
        let syscalls = ScriptedLocalTransferSyscalls(destinationExistsAfterFileClose: true)
        let staging = DarwinLocalTransferStaging(syscalls: syscalls)
        let staged = try await staging.createDownloadStaging(
            in: fixtureIdentity(kind: .directory),
            finalName: try RemotePathComponent(rawBytes: Array("collision.txt".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        await #expect(throws: RemoteFileError(category: .alreadyExists)) {
            try await staging.publish(staged, expectedByteCount: 6, mode: 0o600)
        }

        #expect(syscalls.closeCount(for: 20) == 1)
        #expect(syscalls.closeCount(for: 10) == 1)
        #expect(syscalls.unrelatedDescriptorSurvived)
    }

    @Test("Pre-publication cleanup failure retains the staging record for retry")
    func prePublicationCleanupFailureRetainsRecordForRetry() async throws {
        let syscalls = ScriptedLocalTransferSyscalls(
            fstatSize: 5,
            firstUnlinkError: EACCES
        )
        let staging = DarwinLocalTransferStaging(syscalls: syscalls)
        let staged = try await staging.createDownloadStaging(
            in: fixtureIdentity(kind: .directory),
            finalName: try RemotePathComponent(rawBytes: Array("cleanup.txt".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        await #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try await staging.publish(staged, expectedByteCount: 6, mode: 0o600)
        }
        try await staging.cleanup(staged)

        #expect(syscalls.unlinkCount == 2)
        #expect(syscalls.closeCount(for: 20) == 1)
        #expect(syscalls.closeCount(for: 10) == 1)
    }

    @Test("Directory fsync failure after rename is reported without unlinking published final")
    func directoryFsyncFailureReportsPublishedStateWithoutUnlink() async throws {
        let syscalls = ScriptedLocalTransferSyscalls(directoryFsyncError: EIO)
        let staging = DarwinLocalTransferStaging(syscalls: syscalls)
        let staged = try await staging.createDownloadStaging(
            in: fixtureIdentity(kind: .directory),
            finalName: try RemotePathComponent(rawBytes: Array("published.txt".utf8)),
            attemptID: UUID(),
            itemID: RemoteTransferAttemptItemID()
        )

        await #expect(throws: RemoteFileError(category: .providerFailure)) {
            try await staging.publish(staged, expectedByteCount: 6, mode: 0o600)
        }

        #expect(syscalls.didRename)
        #expect(syscalls.publishedFinalNames == ["published.txt"])
        #expect(syscalls.unlinkCount == 0)
        #expect(syscalls.closeCount(for: 20) == 1)
        #expect(syscalls.closeCount(for: 10) == 1)
        try await staging.cleanup(staged)
        #expect(syscalls.unlinkCount == 0)
        #expect(syscalls.publishedFinalNames == ["published.txt"])
    }
}

private struct LocalTransferStagingFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "xmterm-local-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func identity(
        for url: URL,
        kind: RemoteTransferLocalItemKind
    ) throws -> RemoteTransferLocalFileIdentity {
        var metadata = stat()
        let status = url.path(percentEncoded: false).withCString {
            Darwin.lstat($0, &metadata)
        }
        guard status == 0 else {
            throw RemoteFileError(category: .pathNotFound)
        }
        return try RemoteTransferLocalFileIdentity(
            url: url,
            fileResourceIdentifier: identifierData(device: metadata.st_dev, inode: metadata.st_ino),
            volumeIdentifier: identifierData(device: metadata.st_dev, inode: 0),
            kind: kind,
            observedSize: UInt64(metadata.st_size),
            observedModificationNanoseconds: Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(metadata.st_mtimespec.tv_nsec),
            securityScopedBookmark: nil
        )
    }

    func existsNoFollow(_ url: URL) -> Bool {
        var metadata = stat()
        return url.path(percentEncoded: false).withCString {
            Darwin.lstat($0, &metadata)
        } == 0
    }

    func isSymlink(_ url: URL) -> Bool {
        var metadata = stat()
        let status = url.path(percentEncoded: false).withCString {
            Darwin.lstat($0, &metadata)
        }
        return status == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    func mode(of url: URL) -> mode_t {
        var metadata = stat()
        let status = url.path(percentEncoded: false).withCString {
            Darwin.lstat($0, &metadata)
        }
        #expect(status == 0)
        return metadata.st_mode
    }

    private func identifierData(device: dev_t, inode: ino_t) -> Data {
        var deviceValue = UInt64(device)
        var inodeValue = UInt64(inode)
        var data = Data()
        withUnsafeBytes(of: &deviceValue) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &inodeValue) { data.append(contentsOf: $0) }
        return data
    }
}

private func standardizedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    guard path.hasSuffix("/") else { return path }
    return String(path.dropLast())
}

private func fixtureIdentity(kind: RemoteTransferLocalItemKind) throws
    -> RemoteTransferLocalFileIdentity
{
    try RemoteTransferLocalFileIdentity(
        url: URL(fileURLWithPath: "/tmp/xmterm-scripted"),
        fileResourceIdentifier: ScriptedLocalTransferSyscalls.identifierData(device: 1, inode: 100),
        volumeIdentifier: ScriptedLocalTransferSyscalls.identifierData(device: 1, inode: 0),
        kind: kind,
        observedSize: nil,
        observedModificationNanoseconds: nil,
        securityScopedBookmark: nil
    )
}

private final class ScriptedLocalTransferSyscalls:
    LocalTransferStagingSyscalls,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var opened: Set<Int32> = []
    private var closeCounts: [Int32: Int] = [:]
    private var firstUnlinkError: Int32?
    private let destinationExistsAfterFileClose: Bool
    private let directoryFsyncError: Int32?
    private let fstatSize: off_t
    private let zeroProgressWrite: Bool
    private(set) var unlinkCount = 0
    private(set) var didRename = false
    private(set) var publishedFinalNames: [String] = []
    private(set) var unrelatedDescriptorSurvived = true

    init(
        destinationExistsAfterFileClose: Bool = false,
        fstatSize: off_t = 6,
        firstUnlinkError: Int32? = nil,
        directoryFsyncError: Int32? = nil,
        zeroProgressWrite: Bool = false
    ) {
        self.destinationExistsAfterFileClose = destinationExistsAfterFileClose
        self.fstatSize = fstatSize
        self.firstUnlinkError = firstUnlinkError
        self.directoryFsyncError = directoryFsyncError
        self.zeroProgressWrite = zeroProgressWrite
    }

    func closeCount(for descriptor: Int32) -> Int {
        lock.withLock { closeCounts[descriptor, default: 0] }
    }

    func openPath(_ path: String, flags: Int32) throws -> Int32 {
        _ = lock.withLock { opened.insert(10) }
        return 10
    }

    func openAt(directoryFD: Int32, name: String, flags: Int32, mode: mode_t) throws -> Int32 {
        _ = lock.withLock { opened.insert(20) }
        return 20
    }

    func write(_ descriptor: Int32, data: UnsafeRawBufferPointer) throws -> Int {
        if zeroProgressWrite { return 0 }
        return data.count
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        0
    }

    func fstat(_ descriptor: Int32) throws -> stat {
        makeStat(
            mode: descriptor == 10 ? S_IFDIR | 0o700 : S_IFREG | 0o644,
            inode: descriptor == 10 ? 100 : 200,
            size: descriptor == 10 ? 0 : fstatSize
        )
    }

    func lstat(_ path: String) throws -> stat {
        makeStat(mode: S_IFDIR | 0o700, inode: 100, size: 0)
    }

    func fchmod(_ descriptor: Int32, mode: mode_t) throws {}

    func fsync(_ descriptor: Int32) throws {
        if descriptor == 10, let directoryFsyncError {
            throw mappedError(directoryFsyncError)
        }
    }

    func close(_ descriptor: Int32) throws {
        lock.withLock {
            closeCounts[descriptor, default: 0] += 1
            if descriptor == 20, closeCounts[descriptor, default: 0] > 1 {
                unrelatedDescriptorSurvived = false
            }
            opened.remove(descriptor)
        }
    }

    func fstatAtExists(directoryFD: Int32, name: String) -> Bool {
        destinationExistsAfterFileClose && closeCount(for: 20) > 0
    }

    func renameExclusive(
        directoryFD: Int32,
        stagingName: String,
        finalName: String
    ) throws {
        didRename = true
        publishedFinalNames.append(finalName)
    }

    func unlinkAt(directoryFD: Int32, name: String) throws {
        unlinkCount += 1
        if let error = firstUnlinkError {
            firstUnlinkError = nil
            throw mappedError(error)
        }
    }

    private func makeStat(mode: mode_t, inode: ino_t, size: off_t) -> stat {
        var metadata = stat()
        metadata.st_dev = 1
        metadata.st_ino = inode
        metadata.st_mode = mode
        metadata.st_size = size
        return metadata
    }

    static func identifierData(device: dev_t, inode: ino_t) -> Data {
        var deviceValue = UInt64(device)
        var inodeValue = UInt64(inode)
        var data = Data()
        withUnsafeBytes(of: &deviceValue) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &inodeValue) { data.append(contentsOf: $0) }
        return data
    }

    private func mappedError(_ errnoValue: Int32) -> RemoteFileError {
        switch errnoValue {
        case EACCES, EPERM:
            RemoteFileError(category: .permissionDenied)
        default:
            RemoteFileError(category: .providerFailure)
        }
    }
}
