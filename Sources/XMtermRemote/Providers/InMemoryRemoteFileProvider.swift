import Foundation

public actor InMemoryRemoteFileProvider: RemoteFileProvider, RemoteTransferEndpointProvider {
    public static let maximumEstimatedListingPayloadByteCount = 32 * 1_024 * 1_024

    public struct Directory: Equatable, Sendable {
        public let entries: [RemoteFileEntry]
        public let metadataCompleteness: RemoteMetadataCompleteness
        public let providerCapabilityNotes: String?

        public init(
            entries: [RemoteFileEntry],
            metadataCompleteness: RemoteMetadataCompleteness = .partial,
            providerCapabilityNotes: String? = nil
        ) {
            self.entries = entries
            self.metadataCompleteness = metadataCompleteness
            self.providerCapabilityNotes = providerCapabilityNotes
        }
    }

    public enum Response<Value: Sendable>: Sendable {
        case success(Value)
        case failure(RemoteFileError)
    }

    public struct DeterministicResponses: Sendable {
        public let initialDirectory: Response<RemotePath>?
        public let listings: [RemotePath: Response<Directory>]

        public init(
            initialDirectory: Response<RemotePath>? = nil,
            listings: [RemotePath: Response<Directory>] = [:]
        ) {
            self.initialDirectory = initialDirectory
            self.listings = listings
        }
    }

    public enum AttemptKind: Equatable, Hashable, Sendable {
        case resolveInitialDirectory
        case listDirectory
        case lstat
        case createFile
        case createDirectory
        case rename
        case removeFile
        case removeDirectory
        case setPermissions
        case openFileForReading
        case openFileForWriting
        case readFile
        case writeFile
        case closeFile
    }

    public var recordedAttempts: [AttemptKind] {
        storedAttempts
    }

    private let initialDirectory: RemotePath
    private var directoryGraph: [RemotePath: Directory]
    private var fileContents: [RemotePath: Data]
    private let deterministicResponses: DeterministicResponses
    private let deterministicOperationFailures: [AttemptKind: RemoteFileError]
    private let latency: Duration

    private var storedAttempts: [AttemptKind] = []
    private var requestTasks: [UInt64: Task<Void, Error>] = [:]
    private var nextRequestIdentifier: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isClosed = false
    private var nextStreamIdentifier: UInt64 = 1
    private var readableStreams: [UInt64: ReadableStreamState] = [:]
    private var writableStreams: [UInt64: WritableStreamState] = [:]

    public var capabilities: RemoteFileCapabilities {
        RemoteFileCapabilities(
            canList: true,
            canMutate: true,
            canTransfer: true,
            supportsAtomicReplace: true
        )
    }

    public init(
        initialDirectory: RemotePath,
        directoryGraph: [RemotePath: Directory],
        deterministicResponses: DeterministicResponses = .init(),
        latency: Duration = .zero,
        fileContents: [RemotePath: Data] = [:],
        deterministicOperationFailures: [AttemptKind: RemoteFileError] = [:]
    ) {
        self.initialDirectory = initialDirectory
        self.directoryGraph = directoryGraph
        self.fileContents = fileContents
        self.deterministicResponses = deterministicResponses
        self.deterministicOperationFailures = deterministicOperationFailures
        self.latency = latency > .zero ? latency : .zero
    }

    public func resolveInitialDirectory() async throws -> RemotePath {
        storedAttempts.append(.resolveInitialDirectory)
        try rejectClosedProvider()
        try await waitForConfiguredLatency()

        switch deterministicResponses.initialDirectory {
        case let .success(path):
            return path
        case let .failure(error):
            throw error
        case nil:
            return initialDirectory
        }
    }

    public func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        storedAttempts.append(.listDirectory)
        try rejectClosedProvider()
        try await waitForConfiguredLatency()

        let directory: Directory
        if let response = deterministicResponses.listings[path] {
            switch response {
            case let .success(value):
                directory = value
            case let .failure(error):
                throw error
            }
        } else if let value = directoryGraph[path] {
            directory = value
        } else {
            throw RemoteFileError(category: .pathNotFound)
        }

        return try validatedListing(directory, for: path)
    }

    public func cancelAll() async {
        cancelActiveRequests()
    }

    public func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes {
        try await prepareOperation(.lstat)
        return try attributes(at: path)
    }

    public func createFile(_ path: RemotePath) async throws {
        try await prepareOperation(.createFile)
        try createRegularFile(path)
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try await prepareOperation(.createDirectory)
        guard path != .root else { throw alreadyExistsError() }
        guard try entry(at: path) == nil else { throw alreadyExistsError() }
        guard let parent = path.parent,
              directoryGraph[parent] != nil else {
            throw RemoteFileError(category: .pathNotFound)
        }
        let entry = try RemoteFileEntry(path: path, kind: .directory)
        try insert(entry, into: parent)
        directoryGraph[path] = Directory(entries: [], metadataCompleteness: .complete)
    }

    public func rename(
        _ source: RemotePath,
        to destination: RemotePath,
        replace: Bool
    ) async throws {
        try await prepareOperation(.rename)
        try renameEntry(source, to: destination, replace: replace)
    }

    public func removeFile(_ path: RemotePath) async throws {
        try await prepareOperation(.removeFile)
        guard let entry = try entry(at: path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        guard entry.kind != .directory else {
            throw RemoteFileError(category: .invalidOperation)
        }
        try removeEntryFromParent(path)
        fileContents[path] = nil
    }

    public func removeDirectory(_ path: RemotePath) async throws {
        try await prepareOperation(.removeDirectory)
        guard path != .root else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard let entry = try entry(at: path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        guard entry.kind == .directory else {
            throw RemoteFileError(category: .notDirectory)
        }
        guard let directory = directoryGraph[path] else {
            throw RemoteFileError(category: .malformedResponse)
        }
        guard directory.entries.isEmpty else {
            throw RemoteFileError(category: .directoryNotEmpty)
        }
        directoryGraph[path] = nil
        try removeEntryFromParent(path)
    }

    public func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws {
        try await prepareOperation(.setPermissions)
        guard permissions <= UInt32(RemoteFileEntry.maximumPermissionBits) else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard let oldEntry = try entry(at: path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        let replacement = try RemoteFileEntry(
            path: oldEntry.path,
            kind: oldEntry.kind,
            size: currentSize(for: oldEntry),
            modificationDate: oldEntry.modificationDate,
            permissions: UInt16(permissions),
            symbolicLinkTarget: oldEntry.symbolicLinkTarget,
            metadataCompleteness: oldEntry.metadataCompleteness
        )
        try replaceEntry(replacement)
    }

    public func openFileForReading(
        _ path: RemotePath
    ) async throws -> any RemoteReadableFile {
        try await prepareOperation(.openFileForReading)
        let entry = try requireRegularFile(at: path)
        let data = try fixtureData(for: entry)
        let identifier = allocateStreamIdentifier()
        readableStreams[identifier] = ReadableStreamState(data: data, offset: 0)
        return InMemoryRemoteReadableFile(provider: self, identifier: identifier)
    }

    public func openFileForWriting(
        _ path: RemotePath
    ) async throws -> any RemoteWritableFile {
        try await prepareOperation(.openFileForWriting)
        try createRegularFile(path)

        let identifier = allocateStreamIdentifier()
        writableStreams[identifier] = WritableStreamState(
            path: path,
            data: Data(),
            offset: 0
        )
        return InMemoryRemoteWritableFile(provider: self, identifier: identifier)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        cancelActiveRequests()
        readableStreams.removeAll()
        writableStreams.removeAll()
    }

    private func rejectClosedProvider() throws {
        guard !isClosed else {
            throw RemoteFileError(category: .disconnected)
        }
    }

    private func waitForConfiguredLatency() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw cancellationError()
        }
        guard latency > .zero else { return }

        let requestIdentifier = nextRequestIdentifier
        nextRequestIdentifier &+= 1
        let requestGeneration = cancellationGeneration
        let delay = latency
        let requestTask = Task<Void, Error> {
            try await Task.sleep(for: delay)
        }
        requestTasks[requestIdentifier] = requestTask
        defer {
            requestTasks[requestIdentifier] = nil
        }

        do {
            try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: {
                requestTask.cancel()
            }
        } catch {
            throw cancellationError()
        }

        guard !Task.isCancelled,
              requestGeneration == cancellationGeneration,
              !isClosed else {
            throw cancellationError()
        }
    }

    private func cancelActiveRequests() {
        cancellationGeneration &+= 1
        for requestTask in requestTasks.values {
            requestTask.cancel()
        }
    }

    private func validatedListing(
        _ directory: Directory,
        for path: RemotePath
    ) throws -> RemoteDirectoryListing {
        guard directory.entries.count <= RemoteDirectoryListing.maximumEntryCount else {
            throw limitExceededError()
        }
        guard estimatedPayloadByteCount(for: directory, at: path)
                <= Self.maximumEstimatedListingPayloadByteCount else {
            throw limitExceededError()
        }

        do {
            return try RemoteDirectoryListing(
                directory: path,
                entries: directory.entries,
                metadataCompleteness: directory.metadataCompleteness,
                providerCapabilityNotes: directory.providerCapabilityNotes
            )
        } catch let error as RemoteDirectoryListingValidationError {
            switch error {
            case .tooManyEntries, .capabilityNotesTooLong:
                throw limitExceededError()
            case .entryOutsideDirectory, .duplicateEntry:
                throw RemoteFileError(
                    category: .malformedResponse,
                    userFacingMessage: "The provider returned an invalid directory listing."
                )
            }
        } catch {
            throw RemoteFileError(category: .providerFailure)
        }
    }

    private func estimatedPayloadByteCount(
        for directory: Directory,
        at path: RemotePath
    ) -> Int {
        var total = path.rawBytes.count
        if let notes = directory.providerCapabilityNotes {
            total = adding(notes.utf8.count, to: total)
        }

        for entry in directory.entries {
            total = adding(entry.path.rawBytes.count, to: total)
            total = adding(entry.name.rawBytes.count, to: total)
            total = adding(estimatedMetadataByteCount(for: entry), to: total)
            if let target = entry.symbolicLinkTarget {
                total = adding(target.rawBytes.count, to: total)
            }
            if total > Self.maximumEstimatedListingPayloadByteCount {
                return total
            }
        }
        return total
    }

    private func estimatedMetadataByteCount(for entry: RemoteFileEntry) -> Int {
        1
            + (entry.size == nil ? 0 : MemoryLayout<UInt64>.size)
            + (entry.modificationDate == nil ? 0 : MemoryLayout<Double>.size)
            + (entry.permissions == nil ? 0 : MemoryLayout<UInt16>.size)
    }

    private func adding(_ value: Int, to total: Int) -> Int {
        let (result, overflow) = total.addingReportingOverflow(value)
        return overflow ? Int.max : result
    }

    private func limitExceededError() -> RemoteFileError {
        RemoteFileError(
            category: .limitExceeded,
            userFacingMessage: "The directory listing exceeded a provider safety limit."
        )
    }

    private func cancellationError() -> RemoteFileError {
        RemoteFileError(category: .cancelled)
    }

    fileprivate func readStream(
        identifier: UInt64,
        maximumBytes: Int
    ) async throws -> Data? {
        try await prepareOperation(.readFile)
        guard maximumBytes > 0,
              maximumBytes <= RemoteFileTransferLimits.maximumChunkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard var stream = readableStreams[identifier] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard stream.offset < stream.data.count else { return nil }
        let end = min(stream.data.count, stream.offset + maximumBytes)
        let value = stream.data[stream.offset..<end]
        stream.offset = end
        readableStreams[identifier] = stream
        return Data(value)
    }

    fileprivate func writeStream(identifier: UInt64, data: Data) async throws {
        try await prepareOperation(.writeFile)
        guard data.count <= RemoteFileTransferLimits.maximumChunkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard var stream = writableStreams[identifier] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard !data.isEmpty else { return }

        let end = stream.offset.addingReportingOverflow(data.count)
        guard !end.overflow else {
            throw RemoteFileError(category: .limitExceeded)
        }
        if stream.offset < stream.data.count {
            let replaceEnd = min(end.partialValue, stream.data.count)
            stream.data.replaceSubrange(stream.offset..<replaceEnd, with: data)
        } else {
            stream.data.append(data)
        }
        stream.offset = end.partialValue
        writableStreams[identifier] = stream
        fileContents[stream.path] = stream.data
        try updateFileSize(at: stream.path, size: UInt64(stream.data.count))
    }

    fileprivate func closeReadableStream(identifier: UInt64) async throws {
        try rejectClosedProvider()
        storedAttempts.append(.closeFile)
        readableStreams[identifier] = nil
    }

    fileprivate func closeWritableStream(identifier: UInt64) async throws {
        try rejectClosedProvider()
        storedAttempts.append(.closeFile)
        writableStreams[identifier] = nil
    }

    private func prepareOperation(_ kind: AttemptKind) async throws {
        storedAttempts.append(kind)
        try rejectClosedProvider()
        try await waitForConfiguredLatency()
        if let failure = deterministicOperationFailures[kind] {
            throw failure
        }
    }

    private func attributes(at path: RemotePath) throws -> RemoteFileAttributes {
        if path == .root {
            guard directoryGraph[.root] != nil else {
                throw RemoteFileError(category: .pathNotFound)
            }
            return RemoteFileAttributes(kind: .directory)
        }
        guard let entry = try entry(at: path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        return RemoteFileAttributes(
            kind: entry.kind,
            size: currentSize(for: entry),
            permissions: entry.permissions.map(UInt32.init),
            modificationDate: entry.modificationDate
        )
    }

    private func entry(at path: RemotePath) throws -> RemoteFileEntry? {
        guard path != .root, let parent = path.parent else { return nil }
        guard let parentDirectory = directoryGraph[parent] else { return nil }
        return parentDirectory.entries.first { $0.path == path }
    }

    private func requireRegularFile(at path: RemotePath) throws -> RemoteFileEntry {
        guard let entry = try entry(at: path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        guard entry.kind == .regular else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return entry
    }

    private func createRegularFile(_ path: RemotePath) throws {
        guard path != .root else { throw alreadyExistsError() }
        guard try entry(at: path) == nil else { throw alreadyExistsError() }
        guard let parent = path.parent, directoryGraph[parent] != nil else {
            throw RemoteFileError(category: .pathNotFound)
        }
        let entry = try RemoteFileEntry(
            path: path,
            kind: .regular,
            size: 0,
            metadataCompleteness: .partial
        )
        try insert(entry, into: parent)
        fileContents[path] = Data()
    }

    private func insert(_ entry: RemoteFileEntry, into parent: RemotePath) throws {
        guard let directory = directoryGraph[parent] else {
            throw RemoteFileError(category: .pathNotFound)
        }
        directoryGraph[parent] = Directory(
            entries: directory.entries + [entry],
            metadataCompleteness: directory.metadataCompleteness,
            providerCapabilityNotes: directory.providerCapabilityNotes
        )
    }

    private func replaceEntry(_ entry: RemoteFileEntry) throws {
        guard let parent = entry.path.parent,
              let directory = directoryGraph[parent],
              let index = directory.entries.firstIndex(where: { $0.path == entry.path }) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        var entries = directory.entries
        entries[index] = entry
        directoryGraph[parent] = Directory(
            entries: entries,
            metadataCompleteness: directory.metadataCompleteness,
            providerCapabilityNotes: directory.providerCapabilityNotes
        )
    }

    private func removeEntryFromParent(_ path: RemotePath) throws {
        guard let parent = path.parent,
              let directory = directoryGraph[parent],
              directory.entries.contains(where: { $0.path == path }) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        directoryGraph[parent] = Directory(
            entries: directory.entries.filter { $0.path != path },
            metadataCompleteness: directory.metadataCompleteness,
            providerCapabilityNotes: directory.providerCapabilityNotes
        )
    }

    private func updateFileSize(at path: RemotePath, size: UInt64) throws {
        guard let entry = try entry(at: path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        let replacement = try RemoteFileEntry(
            path: entry.path,
            kind: entry.kind,
            size: size,
            modificationDate: entry.modificationDate,
            permissions: entry.permissions,
            symbolicLinkTarget: entry.symbolicLinkTarget,
            metadataCompleteness: entry.metadataCompleteness
        )
        try replaceEntry(replacement)
    }

    private func renameEntry(
        _ source: RemotePath,
        to destination: RemotePath,
        replace: Bool
    ) throws {
        guard source != .root, destination != .root else {
            throw RemoteFileError(category: .invalidOperation)
        }
        guard let sourceEntry = try entry(at: source) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        guard let destinationParent = destination.parent,
              directoryGraph[destinationParent] != nil else {
            throw RemoteFileError(category: .pathNotFound)
        }
        if source == destination { return }
        if sourceEntry.kind == .directory, source.isAncestor(of: destination) {
            throw RemoteFileError(category: .invalidOperation)
        }
        if let existing = try entry(at: destination) {
            guard replace else { throw alreadyExistsError() }
            if existing.kind == .directory {
                guard sourceEntry.kind == .directory else {
                    throw RemoteFileError(category: .invalidOperation)
                }
                guard directoryGraph[destination]?.entries.isEmpty == true else {
                    throw RemoteFileError(category: .directoryNotEmpty)
                }
                directoryGraph[destination] = nil
            } else if sourceEntry.kind == .directory {
                throw RemoteFileError(category: .invalidOperation)
            }
            try removeEntryFromParent(destination)
            fileContents[destination] = nil
        }

        try removeEntryFromParent(source)
        let rebasedEntry = try copyEntry(sourceEntry, to: destination)
        try insert(rebasedEntry, into: destinationParent)

        if sourceEntry.kind == .directory {
            try rebaseDirectoryTree(from: source, to: destination)
        } else if let contents = fileContents.removeValue(forKey: source) {
            fileContents[destination] = contents
        }
    }

    private func rebaseDirectoryTree(from source: RemotePath, to destination: RemotePath) throws {
        let affectedDirectories = directoryGraph.keys
            .filter { $0 == source || source.isAncestor(of: $0) }
            .sorted { $0.components.count < $1.components.count }
        var replacements: [RemotePath: Directory] = [:]
        for oldDirectoryPath in affectedDirectories {
            guard let directory = directoryGraph[oldDirectoryPath] else { continue }
            let newDirectoryPath = try rebasedPath(
                oldDirectoryPath,
                from: source,
                to: destination
            )
            let entries = try directory.entries.map { entry in
                try copyEntry(
                    entry,
                    to: rebasedPath(entry.path, from: source, to: destination)
                )
            }
            replacements[newDirectoryPath] = Directory(
                entries: entries,
                metadataCompleteness: directory.metadataCompleteness,
                providerCapabilityNotes: directory.providerCapabilityNotes
            )
        }
        for path in affectedDirectories { directoryGraph[path] = nil }
        for (path, directory) in replacements { directoryGraph[path] = directory }

        let affectedFiles = fileContents.keys.filter { source.isAncestor(of: $0) }
        for oldPath in affectedFiles {
            let data = fileContents.removeValue(forKey: oldPath)
            let newPath = try rebasedPath(oldPath, from: source, to: destination)
            fileContents[newPath] = data
        }
    }

    private func rebasedPath(
        _ path: RemotePath,
        from source: RemotePath,
        to destination: RemotePath
    ) throws -> RemotePath {
        let suffix = path.components.dropFirst(source.components.count)
        return try RemotePath(components: destination.components + suffix)
    }

    private func copyEntry(_ entry: RemoteFileEntry, to path: RemotePath) throws -> RemoteFileEntry {
        try RemoteFileEntry(
            path: path,
            kind: entry.kind,
            size: currentSize(for: entry),
            modificationDate: entry.modificationDate,
            permissions: entry.permissions,
            symbolicLinkTarget: entry.symbolicLinkTarget,
            metadataCompleteness: entry.metadataCompleteness
        )
    }

    private func currentSize(for entry: RemoteFileEntry) -> UInt64? {
        fileContents[entry.path].map { UInt64($0.count) } ?? entry.size
    }

    private func fixtureData(for entry: RemoteFileEntry) throws -> Data {
        if let data = fileContents[entry.path] { return data }
        guard entry.size == nil || entry.size == 0 else {
            throw RemoteFileError(
                category: .providerFailure,
                userFacingMessage: "The deterministic provider has no content fixture for this file."
            )
        }
        return Data()
    }

    private func allocateStreamIdentifier() -> UInt64 {
        let identifier = nextStreamIdentifier
        nextStreamIdentifier = identifier == UInt64.max ? 1 : identifier + 1
        return identifier
    }

    private func alreadyExistsError() -> RemoteFileError {
        RemoteFileError(category: .alreadyExists)
    }

    private struct ReadableStreamState: Sendable {
        let data: Data
        var offset: Int
    }

    private struct WritableStreamState: Sendable {
        let path: RemotePath
        var data: Data
        var offset: Int
    }
}

private actor InMemoryRemoteReadableFile: RemoteReadableFile {
    private let provider: InMemoryRemoteFileProvider
    private let identifier: UInt64
    private var isClosed = false

    init(provider: InMemoryRemoteFileProvider, identifier: UInt64) {
        self.provider = provider
        self.identifier = identifier
    }

    func read(maximumBytes: Int) async throws -> Data? {
        guard !isClosed else { throw RemoteFileError(category: .invalidOperation) }
        return try await provider.readStream(
            identifier: identifier,
            maximumBytes: maximumBytes
        )
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        try await provider.closeReadableStream(identifier: identifier)
    }
}

private actor InMemoryRemoteWritableFile: RemoteWritableFile {
    private let provider: InMemoryRemoteFileProvider
    private let identifier: UInt64
    private var isClosed = false

    init(provider: InMemoryRemoteFileProvider, identifier: UInt64) {
        self.provider = provider
        self.identifier = identifier
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw RemoteFileError(category: .invalidOperation) }
        try await provider.writeStream(identifier: identifier, data: data)
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        try await provider.closeWritableStream(identifier: identifier)
    }
}
