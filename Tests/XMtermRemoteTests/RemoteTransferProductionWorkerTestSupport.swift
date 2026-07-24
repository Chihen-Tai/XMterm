import Darwin
import Foundation
import XMtermCore

@testable import XMtermRemote

struct ProductionWorkerScenario {
    let owner: RemoteTransferOwnerIdentity
    let sourceEndpoint: RemoteTransferEndpointSnapshot
    let destinationEndpoint: RemoteTransferEndpointSnapshot

    init() throws {
        owner = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        sourceEndpoint = try Self.endpoint(owner: owner, name: "Source")
        destinationEndpoint = try Self.endpoint(owner: owner, name: "Destination")
    }

    func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    func localIdentity(
        _ url: URL,
        kind: RemoteTransferLocalItemKind = .regularFile,
        size: UInt64? = nil
    ) throws -> RemoteTransferLocalFileIdentity {
        try RemoteTransferLocalFileIdentity(
            url: url,
            fileResourceIdentifier: Data(UUID().uuidString.utf8),
            volumeIdentifier: Data("volume".utf8),
            kind: kind,
            observedSize: size,
            observedModificationNanoseconds: 1,
            securityScopedBookmark: nil
        )
    }

    func context(
        kind: RemoteTransferJobKind,
        sources: [RemoteTransferItemSource],
        destination: RemoteTransferDestination,
        collisionPolicy: RemoteTransferCollisionPolicy,
        metadataPolicy: RemoteTransferMetadataPolicy,
        symlinkPolicy: RemoteTransferSymlinkPolicy,
        crossRuntimePolicy: RemoteTransferCrossRuntimePolicy = .sameRuntimeOnly,
        resolvedCollision: RemoteTransferResolvedCollision? = nil,
        applyToAllResolution: RemoteTransferCollisionResolution? = nil
    ) throws -> RemoteTransferWorkerContext {
        let requested = sources.map {
            RemoteTransferRequestedItem(
                logicalKey: RemoteTransferLogicalItemKey(),
                source: $0
            )
        }
        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: kind,
            requestedItems: requested,
            destination: destination,
            collisionPolicy: collisionPolicy,
            metadataPolicy: metadataPolicy,
            symlinkPolicy: symlinkPolicy,
            recursivePolicy: .none,
            crossRuntimePolicy: crossRuntimePolicy
        )
        let attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)
        return RemoteTransferWorkerContext(
            request: request,
            attempt: attempt,
            items: requested.map {
                RemoteTransferAttemptItem(
                    logicalItemKey: $0.logicalKey,
                    attemptItemID: RemoteTransferAttemptItemID()
                )
            },
            checkpointManifest: .empty,
            resolvedCollision: resolvedCollision,
            applyToAllResolution: applyToAllResolution,
            requiresDestinationRevalidation: false
        )
    }

    private static func endpoint(
        owner: RemoteTransferOwnerIdentity,
        name: String
    ) throws -> RemoteTransferEndpointSnapshot {
        try RemoteTransferEndpointSnapshot(
            id: UUID(),
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText(name),
                kind: .simulated
            ),
            trustedConnectionMaterial: ProductionWorkerSupportMaterial()
        )
    }
}

struct ProductionWorkerSupportMaterial: RemoteTransferTrustedConnectionMaterial {
    let retainedByteCount = 0
}

actor ProductionWorkerEndpointFactory: RemoteTransferEndpointProviderFactory {
    private let providers: [UUID: any RemoteTransferEndpointProvider]
    private var requestedIDs: [UUID] = []

    init(providers: [UUID: any RemoteTransferEndpointProvider]) {
        self.providers = providers
    }

    func makeProvider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) async throws -> any RemoteTransferEndpointProvider {
        requestedIDs.append(endpoint.id)
        guard let provider = providers[endpoint.id] else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return provider
    }

    func requests() -> [UUID] { requestedIDs }
}

actor ProductionWorkerEndpointProvider: RemoteTransferEndpointProvider {
    enum Operation: Equatable, Sendable {
        case lstat(RemotePath)
        case openRead(RemotePath)
        case read(RemotePath, Int)
        case closeRead(RemotePath)
        case openWrite(RemotePath)
        case write(RemotePath, Int)
        case closeWrite(RemotePath)
        case createFile(RemotePath)
        case createDirectory(RemotePath)
        case rename(RemotePath, RemotePath, Bool)
        case removeFile(RemotePath)
        case removeDirectory(RemotePath)
        case setPermissions(RemotePath, UInt32)
        case cancelAll
        case close
    }

    private struct FileState: Sendable {
        let data: Data
        let permissions: UInt32
    }

    private let advertisedCapabilities: RemoteFileCapabilities
    private var files: [RemotePath: FileState]
    private var directories: Set<RemotePath>
    private var operations: [Operation] = []
    private var readOffsets: [UUID: (path: RemotePath, offset: Int)] = [:]
    private var writePaths: [UUID: RemotePath] = [:]

    var capabilities: RemoteFileCapabilities { advertisedCapabilities }

    init(
        files: [RemotePath: (Data, UInt32)] = [:],
        directories: Set<RemotePath> = [.root],
        supportsAtomicReplace: Bool = true
    ) {
        self.files = files.mapValues { FileState(data: $0.0, permissions: $0.1) }
        self.directories = directories
        advertisedCapabilities = RemoteFileCapabilities(
            canList: true,
            canMutate: true,
            canTransfer: true,
            supportsAtomicReplace: supportsAtomicReplace
        )
    }

    func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        guard directories.contains(path) else {
            throw RemoteFileError(category: .pathNotFound)
        }
        return try RemoteDirectoryListing(directory: path, entries: [])
    }

    func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes {
        operations.append(.lstat(path))
        if let file = files[path] {
            return RemoteFileAttributes(
                kind: .regular,
                size: UInt64(file.data.count),
                permissions: file.permissions
            )
        }
        if directories.contains(path) {
            return RemoteFileAttributes(kind: .directory)
        }
        throw RemoteFileError(category: .pathNotFound)
    }

    func createFile(_ path: RemotePath) async throws {
        operations.append(.createFile(path))
        try ensureAbsent(path)
        files[path] = FileState(data: Data(), permissions: 0o600)
    }

    func createDirectory(_ path: RemotePath) async throws {
        operations.append(.createDirectory(path))
        try ensureAbsent(path)
        directories.insert(path)
    }

    func rename(
        _ source: RemotePath,
        to destination: RemotePath,
        replace: Bool
    ) async throws {
        operations.append(.rename(source, destination, replace))
        if !replace, files[destination] != nil || directories.contains(destination) {
            throw RemoteFileError(category: .alreadyExists)
        }
        if let file = files.removeValue(forKey: source) {
            files[destination] = file
            directories.remove(destination)
            return
        }
        guard directories.remove(source) != nil else {
            throw RemoteFileError(category: .pathNotFound)
        }
        files[destination] = nil
        directories.insert(destination)
    }

    func removeFile(_ path: RemotePath) async throws {
        operations.append(.removeFile(path))
        guard files.removeValue(forKey: path) != nil else {
            throw RemoteFileError(category: .pathNotFound)
        }
    }

    func removeDirectory(_ path: RemotePath) async throws {
        operations.append(.removeDirectory(path))
        guard directories.remove(path) != nil else {
            throw RemoteFileError(category: .pathNotFound)
        }
    }

    func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws {
        operations.append(.setPermissions(path, permissions))
        guard let file = files[path] else {
            throw RemoteFileError(category: .pathNotFound)
        }
        files[path] = FileState(data: file.data, permissions: permissions)
    }

    func openFileForReading(_ path: RemotePath) async throws -> any RemoteReadableFile {
        operations.append(.openRead(path))
        guard files[path] != nil else { throw RemoteFileError(category: .pathNotFound) }
        let id = UUID()
        readOffsets[id] = (path, 0)
        return ProductionWorkerReadableFile(provider: self, id: id, path: path)
    }

    func openFileForWriting(_ path: RemotePath) async throws -> any RemoteWritableFile {
        operations.append(.openWrite(path))
        try ensureAbsent(path)
        files[path] = FileState(data: Data(), permissions: 0o600)
        let id = UUID()
        writePaths[id] = path
        return ProductionWorkerWritableFile(provider: self, id: id, path: path)
    }

    func cancelAll() async { operations.append(.cancelAll) }
    func close() async { operations.append(.close) }

    func read(id: UUID, path: RemotePath, maximumBytes: Int) throws -> Data? {
        operations.append(.read(path, maximumBytes))
        guard maximumBytes > 0,
              maximumBytes <= RemoteFileTransferLimits.maximumChunkByteCount,
              var state = readOffsets[id],
              state.path == path,
              let file = files[path] else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard state.offset < file.data.count else { return nil }
        let end = min(file.data.count, state.offset + maximumBytes)
        let chunk = file.data[state.offset..<end]
        state.offset = end
        readOffsets[id] = state
        return Data(chunk)
    }

    func closeRead(id: UUID, path: RemotePath) throws {
        operations.append(.closeRead(path))
        guard readOffsets.removeValue(forKey: id) != nil else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    func write(id: UUID, path: RemotePath, data: Data) throws {
        operations.append(.write(path, data.count))
        guard data.count <= RemoteFileTransferLimits.maximumChunkByteCount,
              writePaths[id] == path,
              let file = files[path] else {
            throw RemoteFileError(category: .limitExceeded)
        }
        files[path] = FileState(data: file.data + data, permissions: file.permissions)
    }

    func closeWrite(id: UUID, path: RemotePath) throws {
        operations.append(.closeWrite(path))
        guard writePaths.removeValue(forKey: id) != nil else {
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    func file(_ path: RemotePath) -> (Data, UInt32)? {
        files[path].map { ($0.data, $0.permissions) }
    }

    func recordedOperations() -> [Operation] { operations }

    private func ensureAbsent(_ path: RemotePath) throws {
        guard files[path] == nil, !directories.contains(path) else {
            throw RemoteFileError(category: .alreadyExists)
        }
    }
}

private struct ProductionWorkerReadableFile: RemoteReadableFile {
    let provider: ProductionWorkerEndpointProvider
    let id: UUID
    let path: RemotePath

    func read(maximumBytes: Int) async throws -> Data? {
        try await provider.read(id: id, path: path, maximumBytes: maximumBytes)
    }

    func close() async throws {
        try await provider.closeRead(id: id, path: path)
    }
}

private struct ProductionWorkerWritableFile: RemoteWritableFile {
    let provider: ProductionWorkerEndpointProvider
    let id: UUID
    let path: RemotePath

    func write(_ data: Data) async throws {
        try await provider.write(id: id, path: path, data: data)
    }

    func close() async throws {
        try await provider.closeWrite(id: id, path: path)
    }
}

actor ProductionWorkerLocalStaging: LocalTransferStaging {
    private struct SourceState {
        let data: Data
        let mode: mode_t
    }

    private var sources: [URL: SourceState]
    private var sourceOffsets: [UUID: (url: URL, offset: Int)] = [:]
    private var stagedData: [UUID: Data] = [:]
    private var stagedRecords: [UUID: LocalTransferStagedDownload] = [:]
    private var publishedData: [URL: (Data, mode_t)] = [:]
    private var readMaximums: [Int] = []

    init(sources: [URL: (Data, mode_t)] = [:]) {
        self.sources = sources.mapValues { SourceState(data: $0.0, mode: $0.1) }
    }

    func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalName: RemotePathComponent,
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        try await createDownloadStaging(
            in: directoryIdentity,
            finalNameRawBytes: finalName.rawBytes,
            attemptID: attemptID,
            itemID: itemID
        )
    }

    func createDownloadStaging(
        in directoryIdentity: RemoteTransferLocalFileIdentity,
        finalNameRawBytes: [UInt8],
        attemptID: UUID,
        itemID: RemoteTransferAttemptItemID
    ) async throws -> LocalTransferStagedDownload {
        let finalName = try LocalTransferLocalNameCodec.localName(forRawBytes: finalNameRawBytes)
        let staged = LocalTransferStagedDownload(
            id: UUID(),
            directoryURL: directoryIdentity.url,
            finalName: finalName,
            stagingName: ".xmterm-partial-\(attemptID.uuidString)-\(itemID.rawValue.uuidString)"
        )
        stagedRecords[staged.id] = staged
        stagedData[staged.id] = Data()
        return staged
    }

    func write(_ data: Data, to staged: LocalTransferStagedDownload) async throws {
        guard data.count <= RemoteFileTransferLimits.maximumChunkByteCount,
              let existing = stagedData[staged.id] else {
            throw RemoteFileError(category: .limitExceeded)
        }
        stagedData[staged.id] = existing + data
    }

    func publish(
        _ staged: LocalTransferStagedDownload,
        expectedByteCount: UInt64,
        mode: mode_t
    ) async throws {
        guard let data = stagedData[staged.id],
              UInt64(data.count) == expectedByteCount else {
            throw RemoteFileError(category: .invalidOperation)
        }
        publishedData[staged.finalURL] = (data, mode)
        stagedData[staged.id] = nil
        stagedRecords[staged.id] = nil
    }

    func cleanup(_ staged: LocalTransferStagedDownload) async throws {
        stagedData[staged.id] = nil
        stagedRecords[staged.id] = nil
    }

    func openValidatedSource(
        _ identity: RemoteTransferLocalFileIdentity
    ) async throws -> LocalTransferOpenedSource {
        guard let source = sources[identity.url] else {
            throw RemoteFileError(category: .pathNotFound)
        }
        let opened = LocalTransferOpenedSource(
            id: UUID(),
            url: identity.url,
            observedSize: UInt64(source.data.count),
            permissions: UInt32(source.mode)
        )
        sourceOffsets[opened.id] = (identity.url, 0)
        return opened
    }

    func read(
        _ source: LocalTransferOpenedSource,
        maximumBytes: Int
    ) async throws -> Data? {
        readMaximums.append(maximumBytes)
        guard maximumBytes > 0,
              maximumBytes <= RemoteFileTransferLimits.maximumChunkByteCount,
              var cursor = sourceOffsets[source.id],
              let data = sources[cursor.url]?.data else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard cursor.offset < data.count else { return nil }
        let end = min(data.count, cursor.offset + maximumBytes)
        let chunk = data[cursor.offset..<end]
        cursor.offset = end
        sourceOffsets[source.id] = cursor
        return Data(chunk)
    }

    func closeSource(_ source: LocalTransferOpenedSource) async throws {
        sourceOffsets[source.id] = nil
    }

    func published(_ url: URL) -> (Data, mode_t)? { publishedData[url] }
    func maximumReadRequests() -> [Int] { readMaximums }
    func activeStagingCount() -> Int { stagedRecords.count }
}
