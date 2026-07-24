import Foundation
import XMtermCore

struct OpenSSHSFTPProviderLimits: Equatable, Sendable {
    static let production = Self()

    let maximumEntryCount: Int
    let maximumCumulativeListingPayloadByteCount: Int

    init(
        maximumEntryCount: Int = RemoteDirectoryListing.maximumEntryCount,
        maximumCumulativeListingPayloadByteCount: Int = 32 * 1_024 * 1_024
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumCumulativeListingPayloadByteCount = maximumCumulativeListingPayloadByteCount
    }
}

public actor OpenSSHSFTPRemoteFileProvider: RemoteFileProvider, RemoteTransferEndpointProvider {
    private let client: OpenSSHSFTPClient
    private let limits: OpenSSHSFTPProviderLimits
    private var isClosed = false

    public var capabilities: RemoteFileCapabilities {
        get async {
            RemoteFileCapabilities(
                canList: true,
                canMutate: true,
                canTransfer: true,
                supportsAtomicReplace: await client.supportsPosixRename
            )
        }
    }

    public init(profile: SSHSessionProfile) throws {
        let target = try OpenSSHSFTPTarget(profile: profile)
        client = OpenSSHSFTPClient(
            factory: OpenSSHSubsystemProcessFactory(target: target)
        )
        limits = .production
    }

    init(
        client: OpenSSHSFTPClient,
        limits: OpenSSHSFTPProviderLimits = .production
    ) {
        self.client = client
        self.limits = limits
    }

    public func resolveInitialDirectory() async throws -> RemotePath {
        try ensureOpen()
        do {
            return try RemotePath(rawBytes: try await client.realPath([0x2E]))
        } catch {
            throw await mappedError(error, invalidatingMalformedDomainValue: true)
        }
    }

    public func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        try ensureOpen()
        let handle: [UInt8]
        do {
            handle = try await client.openDirectory(path.rawBytes)
        } catch {
            throw await mappedError(error)
        }

        let entries: [RemoteFileEntry]
        do {
            entries = try await readAllEntries(directory: path, handle: handle)
        } catch let failure as OpenSSHSFTPFailure {
            if failure == .permissionDenied || failure == .pathNotFound {
                do {
                    try await client.closeHandle(handle)
                } catch {
                    await client.invalidate()
                }
            }
            throw failure.remoteFileError
        } catch {
            if let remoteError = error as? RemoteFileError {
                throw remoteError
            }
            throw await mappedError(error, invalidatingMalformedDomainValue: true)
        }

        do {
            try await client.closeHandle(handle)
        } catch {
            await client.invalidate()
            throw await mappedError(error)
        }

        do {
            let completeness: RemoteMetadataCompleteness = entries.allSatisfy {
                $0.metadataCompleteness == .complete
            } ? .complete : .partial
            return try RemoteDirectoryListing(
                directory: path,
                entries: entries,
                metadataCompleteness: completeness
            )
        } catch {
            throw await mappedError(error, invalidatingMalformedDomainValue: true)
        }
    }

    public func cancelAll() async {
        await client.invalidate()
    }

    public func lstat(_ path: RemotePath) async throws -> RemoteFileAttributes {
        try ensureOpen()
        do {
            return Self.makeAttributes(from: try await client.lstat(path.rawBytes))
        } catch {
            throw await mappedError(error)
        }
    }

    public func createFile(_ path: RemotePath) async throws {
        try ensureOpen()
        do {
            let handle = try await client.openFile(
                path.rawBytes,
                flags: [.write, .create, .exclusive]
            )
            try await client.closeFile(handle)
        } catch {
            throw await mappedError(error)
        }
    }

    public func createDirectory(_ path: RemotePath) async throws {
        try ensureOpen()
        do {
            try await client.createDirectory(path.rawBytes)
        } catch {
            throw await mappedError(error)
        }
    }

    public func rename(
        _ source: RemotePath,
        to destination: RemotePath,
        replace: Bool
    ) async throws {
        try ensureOpen()
        do {
            if replace {
                guard try await client.serverSupportsPosixRename() else {
                    throw OpenSSHSFTPFailure.unsupportedProtocol
                }
                try await client.posixRename(source.rawBytes, to: destination.rawBytes)
            } else {
                try await client.rename(source.rawBytes, to: destination.rawBytes)
            }
        } catch {
            throw await mappedError(error)
        }
    }

    public func removeFile(_ path: RemotePath) async throws {
        try ensureOpen()
        do {
            try await client.removeFile(path.rawBytes)
        } catch {
            throw await mappedError(error)
        }
    }

    public func removeDirectory(_ path: RemotePath) async throws {
        try ensureOpen()
        do {
            try await client.removeDirectory(path.rawBytes)
        } catch {
            throw await mappedError(error)
        }
    }

    public func setPermissions(_ permissions: UInt32, at path: RemotePath) async throws {
        try ensureOpen()
        guard permissions <= UInt32(RemoteFileEntry.maximumPermissionBits) else {
            throw RemoteFileError(category: .invalidOperation)
        }
        do {
            try await client.setStat(
                path.rawBytes,
                attributes: SFTPAttributes(permissions: permissions)
            )
        } catch {
            throw await mappedError(error)
        }
    }

    public func openFileForReading(
        _ path: RemotePath
    ) async throws -> any RemoteReadableFile {
        try ensureOpen()
        do {
            let handle = try await client.openFile(path.rawBytes, flags: [.read])
            return OpenSSHSFTPReadableFile(client: client, handle: handle)
        } catch {
            throw await mappedError(error)
        }
    }

    public func openFileForWriting(
        _ path: RemotePath
    ) async throws -> any RemoteWritableFile {
        try ensureOpen()
        do {
            let handle = try await client.openFile(
                path.rawBytes,
                flags: [.write, .create, .exclusive]
            )
            return OpenSSHSFTPWritableFile(
                client: client,
                handle: handle
            )
        } catch {
            throw await mappedError(error)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await client.close()
    }

    private func readAllEntries(
        directory: RemotePath,
        handle: [UInt8]
    ) async throws -> [RemoteFileEntry] {
        var entries: [RemoteFileEntry] = []
        var payloadByteCount = 0

        while true {
            let result = try await client.readDirectory(handle)
            switch result {
            case .endOfDirectory(let packetByteCount):
                payloadByteCount = try await checkedPayloadTotal(
                    payloadByteCount,
                    adding: packetByteCount
                )
                return entries
            case .names(let names, let packetByteCount):
                payloadByteCount = try await checkedPayloadTotal(
                    payloadByteCount,
                    adding: packetByteCount
                )
                for name in names where !Self.isDotEntry(name.rawFilename) {
                    guard entries.count < limits.maximumEntryCount else {
                        await client.invalidate()
                        throw RemoteFileError(category: .limitExceeded)
                    }
                    do {
                        entries.append(try Self.makeEntry(name, in: directory))
                    } catch {
                        await client.invalidate()
                        throw OpenSSHSFTPFailure.malformedResponse
                    }
                }
            }
        }
    }

    private func checkedPayloadTotal(_ current: Int, adding increment: Int) async throws -> Int {
        let result = current.addingReportingOverflow(increment)
        guard !result.overflow,
              result.partialValue <= limits.maximumCumulativeListingPayloadByteCount else {
            await client.invalidate()
            throw RemoteFileError(category: .limitExceeded)
        }
        return result.partialValue
    }

    private static func makeEntry(
        _ name: SFTPName,
        in directory: RemotePath
    ) throws -> RemoteFileEntry {
        let component = try RemotePathComponent(rawBytes: name.rawFilename)
        let attributes = name.attributes
        let permissions = attributes.permissions.map {
            UInt16(truncatingIfNeeded: $0 & UInt32(RemoteFileEntry.maximumPermissionBits))
        }
        let modificationDate = attributes.modificationTime.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let completeness: RemoteMetadataCompleteness = attributes.size != nil
            && attributes.permissions != nil
            && attributes.modificationTime != nil ? .complete : .partial
        return try RemoteFileEntry(
            path: directory.appending(component),
            kind: kind(from: attributes.permissions),
            size: attributes.size,
            modificationDate: modificationDate,
            permissions: permissions,
            symbolicLinkTarget: nil,
            metadataCompleteness: completeness
        )
    }

    private static func kind(from permissions: UInt32?) -> RemoteFileEntry.Kind {
        guard let permissions else { return .other }
        return switch permissions & 0o170000 {
        case 0o040000: .directory
        case 0o100000: .regular
        case 0o120000: .symbolicLink
        default: .other
        }
    }

    private static func makeAttributes(from attributes: SFTPAttributes) -> RemoteFileAttributes {
        RemoteFileAttributes(
            kind: kind(from: attributes.permissions),
            size: attributes.size,
            permissions: attributes.permissions.map {
                $0 & UInt32(RemoteFileEntry.maximumPermissionBits)
            },
            modificationDate: attributes.modificationTime.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
        )
    }

    private static func isDotEntry(_ bytes: [UInt8]) -> Bool {
        bytes == [0x2E] || bytes == [0x2E, 0x2E]
    }

    private func ensureOpen() throws {
        guard !isClosed else {
            throw RemoteFileError(category: .transportUnavailable)
        }
    }

    private func mappedError(
        _ error: any Error,
        invalidatingMalformedDomainValue: Bool = false
    ) async -> RemoteFileError {
        if let remoteError = error as? RemoteFileError {
            return remoteError
        }
        if let failure = error as? OpenSSHSFTPFailure {
            return failure.remoteFileError
        }
        if invalidatingMalformedDomainValue {
            await client.invalidate()
            return RemoteFileError(category: .malformedResponse)
        }
        return RemoteFileError(category: .unknown)
    }
}

private actor OpenSSHSFTPReadableFile: RemoteReadableFile {
    private let client: OpenSSHSFTPClient
    private let handle: SFTPFileHandle
    private var offset: UInt64 = 0
    private var isClosed = false
    private var operationFailed = false

    init(client: OpenSSHSFTPClient, handle: SFTPFileHandle) {
        self.client = client
        self.handle = handle
    }

    func read(maximumBytes: Int) async throws -> Data? {
        guard !isClosed else { throw RemoteFileError(category: .invalidOperation) }
        guard maximumBytes > 0,
              maximumBytes <= RemoteFileTransferLimits.maximumChunkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        do {
            guard let bytes = try await client.readFile(
                handle,
                offset: offset,
                length: maximumBytes
            ) else {
                return nil
            }
            let advanced = offset.addingReportingOverflow(UInt64(bytes.count))
            guard !advanced.overflow else {
                operationFailed = true
                await client.invalidate()
                throw RemoteFileError(category: .limitExceeded)
            }
            offset = advanced.partialValue
            return Data(bytes)
        } catch let error as RemoteFileError {
            operationFailed = true
            await client.settleFileHandleAfterFailure(handle)
            throw error
        } catch let failure as OpenSSHSFTPFailure {
            operationFailed = true
            await client.settleFileHandleAfterFailure(handle)
            throw failure.remoteFileError
        } catch {
            operationFailed = true
            await client.settleFileHandleAfterFailure(handle)
            throw RemoteFileError(category: .unknown)
        }
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        guard !operationFailed else { return }
        do {
            try await client.closeFile(handle)
        } catch let failure as OpenSSHSFTPFailure {
            if failure == .transportUnavailable { return }
            throw failure.remoteFileError
        } catch {
            throw RemoteFileError(category: .unknown)
        }
    }
}

private actor OpenSSHSFTPWritableFile: RemoteWritableFile {
    private let client: OpenSSHSFTPClient
    private let handle: SFTPFileHandle
    private var offset: UInt64
    private var isClosed = false
    private var operationFailed = false

    init(client: OpenSSHSFTPClient, handle: SFTPFileHandle) {
        self.client = client
        self.handle = handle
        offset = 0
    }

    func write(_ data: Data) async throws {
        guard !isClosed else { throw RemoteFileError(category: .invalidOperation) }
        guard data.count <= RemoteFileTransferLimits.maximumChunkByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        guard !data.isEmpty else { return }
        do {
            try await client.writeFile(handle, offset: offset, data: Array(data))
            let advanced = offset.addingReportingOverflow(UInt64(data.count))
            guard !advanced.overflow else {
                operationFailed = true
                await client.invalidate()
                throw RemoteFileError(category: .limitExceeded)
            }
            offset = advanced.partialValue
        } catch let error as RemoteFileError {
            operationFailed = true
            await client.settleFileHandleAfterFailure(handle)
            throw error
        } catch let failure as OpenSSHSFTPFailure {
            operationFailed = true
            await client.settleFileHandleAfterFailure(handle)
            throw failure.remoteFileError
        } catch {
            operationFailed = true
            await client.settleFileHandleAfterFailure(handle)
            throw RemoteFileError(category: .unknown)
        }
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        guard !operationFailed else { return }
        do {
            try await client.closeFile(handle)
        } catch let failure as OpenSSHSFTPFailure {
            if failure == .transportUnavailable { return }
            throw failure.remoteFileError
        } catch {
            throw RemoteFileError(category: .unknown)
        }
    }
}
