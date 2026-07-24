import Darwin
import Foundation

public struct LocalTransferStagedDownload: Equatable, Sendable {
    public let id: UUID
    public let directoryURL: URL
    public let finalName: String
    public let stagingName: String

    public var finalURL: URL {
        directoryURL.appending(path: finalName)
    }

    public var stagingURL: URL {
        directoryURL.appending(path: stagingName)
    }
}

public struct LocalTransferOpenedSource: Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let observedSize: UInt64
    public let permissions: UInt32
}

public enum LocalTransferLocalNameCodec {
    public static func localName(forRemoteComponent component: RemotePathComponent) throws -> String {
        try localName(forRawBytes: component.rawBytes)
    }

    public static func localName(forRawBytes bytes: [UInt8]) throws -> String {
        guard !bytes.isEmpty,
              bytes.count <= RemotePathComponent.maximumRawByteCount,
              !bytes.contains(0x00),
              !bytes.contains(0x2F) else {
            throw RemoteFileError(category: .invalidOperation)
        }
        if let decoded = String(bytes: bytes, encoding: .utf8) {
            try validateInjectionSafety(decoded)
            return decoded.replacingOccurrences(of: "~", with: "~7E")
        }
        let escaped = bytes.map { byte in
            if isSafeUnescapedASCII(byte) {
                String(UnicodeScalar(byte))
            } else {
                String(format: "~%02X", byte)
            }
        }.joined()
        try validateInjectionSafety(escaped)
        return escaped
    }

    private static func validateInjectionSafety(_ value: String) throws {
        guard value != ".",
              value != "..",
              !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("/"),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private static func isSafeUnescapedASCII(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7D && byte != 0x2F
    }
}

public protocol LocalTransferStaging: Sendable {
    func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalName: RemotePathComponent,
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload

    func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalNameRawBytes: [UInt8],
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload

    func write(_ data: Data, to staged: LocalTransferStagedDownload) async throws
    func publish(
        _ staged: LocalTransferStagedDownload,
        expectedByteCount: UInt64,
        mode: mode_t
    ) async throws
    func cleanup(_ staged: LocalTransferStagedDownload) async throws
    func openValidatedSource(
        _ identity: RemoteTransferLocalFileIdentity
    ) async throws -> LocalTransferOpenedSource
    func read(_ source: LocalTransferOpenedSource, maximumBytes: Int) async throws -> Data?
    func closeSource(_ source: LocalTransferOpenedSource) async throws
}

public actor DarwinLocalTransferStaging: LocalTransferStaging {
    private struct StagedRecord {
        var directoryFD: Int32?
        var fileFD: Int32?
        let directoryURL: URL
        let finalName: String
        let stagingName: String
        var didRename: Bool
    }

    private var stagedRecords: [UUID: StagedRecord] = [:]
    private var openedSources: [UUID: Int32] = [:]
    private let syscalls: any LocalTransferStagingSyscalls

    public init() {
        self.syscalls = DarwinLocalTransferStagingSyscalls()
    }

    init(syscalls: any LocalTransferStagingSyscalls) {
        self.syscalls = syscalls
    }

    public func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalName: RemotePathComponent,
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        let name = try LocalTransferLocalNameCodec.localName(forRemoteComponent: finalName)
        return try await createDownloadStaging(
            in: directoryIdentity,
            finalNameString: name,
            attemptID: attemptID,
            itemID: itemID
        )
    }

    public func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalNameRawBytes: [UInt8],
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        let name = try LocalTransferLocalNameCodec.localName(forRawBytes: finalNameRawBytes)
        return try await createDownloadStaging(
            in: directoryIdentity,
            finalNameString: name,
            attemptID: attemptID,
            itemID: itemID
        )
    }

    public func write(
        _ data: Data,
        to staged: LocalTransferStagedDownload
    ) async throws {
        guard data.count <= RemoteFileTransferLimits.maximumChunkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard let record = stagedRecords[staged.id] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard let fileFD = record.fileFD else {
            throw RemoteFileError(category: .invalidOperation)
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = try syscalls.write(
                    fileFD,
                    data: UnsafeRawBufferPointer(
                        start: baseAddress.advanced(by: written),
                        count: buffer.count - written
                    )
                )
                guard count > 0 else {
                    throw RemoteFileError(category: .providerFailure)
                }
                written += count
            }
        }
    }

    public func publish(
        _ staged: LocalTransferStagedDownload,
        expectedByteCount: UInt64,
        mode: mode_t
    ) async throws {
        guard var record = stagedRecords[staged.id] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        do {
            guard let fileFD = record.fileFD else {
                throw RemoteFileError(category: .invalidOperation)
            }
            let metadata = try syscalls.fstat(fileFD)
            guard UInt64(metadata.st_size) == expectedByteCount else {
                throw RemoteFileError(category: .invalidOperation)
            }
            try syscalls.fchmod(fileFD, mode: mode & 0o777)
            try syscalls.fsync(fileFD)
            try closeFile(in: &record)
            if destinationExists(record) {
                throw RemoteFileError(category: .alreadyExists)
            }
            try rename(record: &record)
            try fsyncDirectoryAfterRename(record: &record)
            try closeDirectory(in: &record)
            stagedRecords.removeValue(forKey: staged.id)
        } catch {
            try handlePublicationFailure(error, record: &record, stagedID: staged.id)
            throw error
        }
    }

    public func cleanup(_ staged: LocalTransferStagedDownload) async throws {
        guard var record = stagedRecords[staged.id] else {
            return
        }
        do {
            try cleanupRecord(&record)
            stagedRecords.removeValue(forKey: staged.id)
        } catch {
            stagedRecords[staged.id] = record
            throw error
        }
    }

    public func openValidatedSource(
        _ identity: RemoteTransferLocalFileIdentity
    ) async throws -> LocalTransferOpenedSource {
        guard identity.kind == .regularFile else {
            throw RemoteFileError(category: .unsupportedEntry)
        }
        let pathMetadata = try syscalls.lstat(identity.url.path(percentEncoded: false))
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw RemoteFileError(category: .unsupportedEntry)
        }
        try LocalTransferIdentityValidation.validate(metadata: pathMetadata, against: identity)
        let descriptor = try openNoFollow(
            identity.url,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC
        )
        do {
            let metadata = try syscalls.fstat(descriptor)
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw RemoteFileError(category: .unsupportedEntry)
            }
            try LocalTransferIdentityValidation.validate(metadata: metadata, against: identity)
            let source = LocalTransferOpenedSource(
                id: UUID(),
                url: identity.url,
                observedSize: UInt64(metadata.st_size),
                permissions: UInt32(metadata.st_mode & 0o777)
            )
            openedSources[source.id] = descriptor
            return source
        } catch {
            try syscalls.close(descriptor)
            throw error
        }
    }

    public func closeSource(_ source: LocalTransferOpenedSource) async throws {
        guard let descriptor = openedSources.removeValue(forKey: source.id) else {
            return
        }
        try syscalls.close(descriptor)
    }

    public func read(
        _ source: LocalTransferOpenedSource,
        maximumBytes: Int
    ) async throws -> Data? {
        guard maximumBytes >= 0,
              maximumBytes <= RemoteFileTransferLimits.maximumChunkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard let descriptor = openedSources[source.id] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard maximumBytes > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        let count = try buffer.withUnsafeMutableBytes {
            try syscalls.read(descriptor, into: $0)
        }
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    private func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalNameString: String,
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        let directoryFD = try openValidatedDirectory(directoryIdentity)
        do {
            let stagingName = ".xmterm-partial-\(attemptID.uuidString)-\(itemID.rawValue.uuidString)"
            let fileFD = try syscalls.openAt(
                directoryFD: directoryFD,
                name: stagingName,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode: 0o600
            )
            let id = UUID()
            stagedRecords[id] = StagedRecord(
                directoryFD: directoryFD,
                fileFD: fileFD,
                directoryURL: directoryIdentity.url,
                finalName: finalNameString,
                stagingName: stagingName,
                didRename: false
            )
            return LocalTransferStagedDownload(
                id: id,
                directoryURL: directoryIdentity.url,
                finalName: finalNameString,
                stagingName: stagingName
            )
        } catch {
            try syscalls.close(directoryFD)
            throw error
        }
    }

    private func openValidatedDirectory(
        _ identity: RemoteTransferLocalFileIdentity
    ) throws -> Int32 {
        guard identity.kind == .directory else {
            throw RemoteFileError(category: .notDirectory)
        }
        let descriptor = try openNoFollow(
            identity.url,
            flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        do {
            let metadata = try syscalls.fstat(descriptor)
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw RemoteFileError(category: .notDirectory)
            }
            try LocalTransferIdentityValidation.validate(metadata: metadata, against: identity)
            return descriptor
        } catch {
            try syscalls.close(descriptor)
            throw error
        }
    }

    private func openNoFollow(_ url: URL, flags: Int32) throws -> Int32 {
        try syscalls.openPath(url.path(percentEncoded: false), flags: flags | O_NOFOLLOW)
    }

    private func destinationExists(_ record: StagedRecord) -> Bool {
        guard let directoryFD = record.directoryFD else { return false }
        return syscalls.fstatAtExists(directoryFD: directoryFD, name: record.finalName)
    }

    private func handlePublicationFailure(
        _ error: Error,
        record: inout StagedRecord,
        stagedID: UUID
    ) throws {
        guard !record.didRename else {
            stagedRecords.removeValue(forKey: stagedID)
            try closeDirectory(in: &record)
            return
        }
        do {
            try cleanupRecord(&record)
            stagedRecords.removeValue(forKey: stagedID)
        } catch {
            stagedRecords[stagedID] = record
        }
    }

    private func cleanupRecord(_ record: inout StagedRecord) throws {
        if !record.didRename, let directoryFD = record.directoryFD {
            try syscalls.unlinkAt(directoryFD: directoryFD, name: record.stagingName)
        }
        try closeFile(in: &record)
        try closeDirectory(in: &record)
    }

    private func rename(record: inout StagedRecord) throws {
        guard let directoryFD = record.directoryFD else {
            throw RemoteFileError(category: .invalidOperation)
        }
        try syscalls.renameExclusive(
            directoryFD: directoryFD,
            stagingName: record.stagingName,
            finalName: record.finalName
        )
        record.didRename = true
    }

    private func fsyncDirectoryAfterRename(record: inout StagedRecord) throws {
        guard let directoryFD = record.directoryFD else {
            throw RemoteFileError(category: .invalidOperation)
        }
        try syscalls.fsync(directoryFD)
    }

    private func closeFile(in record: inout StagedRecord) throws {
        guard let fileFD = record.fileFD else { return }
        record.fileFD = nil
        try syscalls.close(fileFD)
    }

    private func closeDirectory(in record: inout StagedRecord) throws {
        guard let directoryFD = record.directoryFD else { return }
        record.directoryFD = nil
        try syscalls.close(directoryFD)
    }
}

protocol LocalTransferStagingSyscalls: Sendable {
    func openPath(_ path: String, flags: Int32) throws -> Int32
    func openAt(directoryFD: Int32, name: String, flags: Int32, mode: mode_t) throws -> Int32
    func write(_ descriptor: Int32, data: UnsafeRawBufferPointer) throws -> Int
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func fstat(_ descriptor: Int32) throws -> stat
    func lstat(_ path: String) throws -> stat
    func fchmod(_ descriptor: Int32, mode: mode_t) throws
    func fsync(_ descriptor: Int32) throws
    func close(_ descriptor: Int32) throws
    func fstatAtExists(directoryFD: Int32, name: String) -> Bool
    func renameExclusive(directoryFD: Int32, stagingName: String, finalName: String) throws
    func unlinkAt(directoryFD: Int32, name: String) throws
}

struct DarwinLocalTransferStagingSyscalls: LocalTransferStagingSyscalls {
    func openPath(_ path: String, flags: Int32) throws -> Int32 {
        try path.withCString { pointer in
            let descriptor = Darwin.open(pointer, flags)
            guard descriptor >= 0 else { throw Self.errorFromErrno() }
            return descriptor
        }
    }

    func openAt(directoryFD: Int32, name: String, flags: Int32, mode: mode_t) throws -> Int32 {
        try name.withCString { pointer in
            let descriptor = Darwin.openat(directoryFD, pointer, flags, mode)
            guard descriptor >= 0 else { throw Self.errorFromErrno() }
            return descriptor
        }
    }

    func write(_ descriptor: Int32, data: UnsafeRawBufferPointer) throws -> Int {
        guard let baseAddress = data.baseAddress else { return 0 }
        let count = Darwin.write(descriptor, baseAddress, data.count)
        guard count >= 0 else { throw Self.errorFromErrno() }
        return count
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        guard count >= 0 else { throw Self.errorFromErrno() }
        return count
    }

    func fstat(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw Self.errorFromErrno()
        }
        return metadata
    }

    func lstat(_ path: String) throws -> stat {
        var metadata = stat()
        let status = path.withCString { Darwin.lstat($0, &metadata) }
        guard status == 0 else { throw Self.errorFromErrno() }
        return metadata
    }

    func fchmod(_ descriptor: Int32, mode: mode_t) throws {
        guard Darwin.fchmod(descriptor, mode) == 0 else { throw Self.errorFromErrno() }
    }

    func fsync(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else { throw Self.errorFromErrno() }
    }

    func close(_ descriptor: Int32) throws {
        guard Darwin.close(descriptor) == 0 else { throw Self.errorFromErrno() }
    }

    func fstatAtExists(directoryFD: Int32, name: String) -> Bool {
        var metadata = stat()
        return name.withCString {
            Darwin.fstatat(directoryFD, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        } == 0
    }

    func renameExclusive(directoryFD: Int32, stagingName: String, finalName: String) throws {
        let status = stagingName.withCString { stagingPointer in
            finalName.withCString { finalPointer in
                Darwin.renameatx_np(
                    directoryFD,
                    stagingPointer,
                    directoryFD,
                    finalPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else { throw Self.errorFromErrno() }
    }

    func unlinkAt(directoryFD: Int32, name: String) throws {
        let status = name.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
        if status != 0, errno != ENOENT {
            throw Self.errorFromErrno()
        }
    }

    private static func errorFromErrno() -> RemoteFileError {
        switch errno {
        case EACCES, EPERM:
            RemoteFileError(category: .permissionDenied)
        case ENOENT:
            RemoteFileError(category: .pathNotFound)
        case EEXIST:
            RemoteFileError(category: .alreadyExists)
        case ENOTDIR:
            RemoteFileError(category: .notDirectory)
        case ELOOP, ENXIO, EOPNOTSUPP:
            RemoteFileError(category: .unsupportedEntry)
        default:
            RemoteFileError(category: .providerFailure)
        }
    }
}

private enum LocalTransferIdentityValidation {
    static func validate(
        metadata: stat,
        against identity: RemoteTransferLocalFileIdentity
    ) throws {
        let identifier = identifierData(device: metadata.st_dev, inode: metadata.st_ino)
        let volume = identifierData(device: metadata.st_dev, inode: 0)
        guard identifier == identity.fileResourceIdentifier,
              identity.volumeIdentifier == nil || identity.volumeIdentifier == volume else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard identity.kind == .regularFile else { return }
        if let observedSize = identity.observedSize,
           observedSize != UInt64(metadata.st_size) {
            throw RemoteFileError(category: .invalidOperation)
        }
        if let observedModificationNanoseconds = identity.observedModificationNanoseconds {
            let actual = Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(metadata.st_mtimespec.tv_nsec)
            guard actual == observedModificationNanoseconds else {
                throw RemoteFileError(category: .invalidOperation)
            }
        }
    }

    private static func identifierData(device: dev_t, inode: ino_t) -> Data {
        var deviceValue = UInt64(device)
        var inodeValue = UInt64(inode)
        var data = Data()
        withUnsafeBytes(of: &deviceValue) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &inodeValue) { data.append(contentsOf: $0) }
        return data
    }
}
