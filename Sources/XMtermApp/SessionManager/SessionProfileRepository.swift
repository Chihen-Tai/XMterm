import Foundation
import XMtermCore

protocol SessionProfileRepository: Sendable {
    func load() async throws -> SessionProfileLoadResult
    func save(_ collection: SessionProfileCollection) async throws
}

enum SessionProfileLoadResult: Equatable, Sendable {
    case uninitialized
    case loaded(SessionProfileCollection)
    case recoveryRequired(SessionProfileRecovery)
}

struct SessionProfileRecovery: Equatable, Sendable {
    let preservedFileURL: URL
    let recoveredCollection: SessionProfileCollection
    let issues: [SessionProfileRecoveryIssue]

    init(
        preservedFileURL: URL,
        recoveredCollection: SessionProfileCollection,
        issues: [SessionProfileRecoveryIssue]
    ) {
        self.preservedFileURL = preservedFileURL
        self.recoveredCollection = recoveredCollection
        self.issues = issues
    }
}

enum SessionProfileRecoveryIssue: Equatable, Hashable, Sendable {
    case malformedDocument
    case unsupportedSchema(version: Int)
    case rejectedProfiles(count: Int)
    case documentTooLarge(maximumBytes: Int)
    case profileLimitExceeded(maximumCount: Int)
    case preservedRecoveryFile
}

enum SessionProfileRepositoryError: Error, Equatable, Sendable {
    case applicationSupportDirectoryUnavailable
    case encodingFailed
    case documentTooLarge(maximumBytes: Int)
    case profileLimitExceeded(maximumCount: Int)
    case recoveryScanFailed(URL)
    case readFailed(URL)
    case directoryPreparationFailed(URL)
    case permissionRepairFailed(URL)
    case temporaryWriteFailed(URL)
    case atomicMoveFailed(URL)
    case atomicReplaceFailed(URL)
    case corruptFilePreservationFailed(URL)
}

protocol SessionProfileFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func read(from url: URL, upToByteCount maximumByteCount: Int) throws -> Data
    func createDirectory(at url: URL, permissions: Int) throws
    func setPermissions(_ permissions: Int, of url: URL) throws
    func writeUserOnlyFile(_ data: Data, to url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws
    func removeItemIfPresent(at url: URL) throws
}

struct FoundationSessionProfileFileSystem: SessionProfileFileSystem {
    private var fileManager: FileManager { FileManager.default }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func read(from url: URL, upToByteCount maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumByteCount) ?? Data()
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func setPermissions(_ permissions: Int, of url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func writeUserOnlyFile(_ data: Data, to url: URL) throws {
        let created = fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: sourceURL,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    }

    func removeItemIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
