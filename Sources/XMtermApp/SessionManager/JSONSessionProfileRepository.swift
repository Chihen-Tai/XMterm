import Foundation
import XMtermCore

actor JSONSessionProfileRepository: SessionProfileRepository {
    static let schemaVersion = 1
    static let maximumDocumentBytes = 4 * 1_024 * 1_024
    static let maximumProfileCount = 512

    private let fileURL: URL
    private let fileSystem: any SessionProfileFileSystem
    private let makeTemporarySuffix: @Sendable () -> String
    private let makeRecoverySuffix: @Sendable () -> String

    init(
        fileURL: URL,
        fileSystem: any SessionProfileFileSystem = FoundationSessionProfileFileSystem(),
        makeTemporarySuffix: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        },
        makeRecoverySuffix: @escaping @Sendable () -> String = {
            let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            return "\(milliseconds)-\(UUID().uuidString.lowercased())"
        }
    ) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        self.makeTemporarySuffix = makeTemporarySuffix
        self.makeRecoverySuffix = makeRecoverySuffix
    }

    static func live() throws -> JSONSessionProfileRepository {
        let fileManager = FileManager.default
        guard let applicationSupportDirectory = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            throw SessionProfileRepositoryError.applicationSupportDirectoryUnavailable
        }
        return JSONSessionProfileRepository(
            fileURL: storageURL(applicationSupportDirectory: applicationSupportDirectory)
        )
    }

    nonisolated static func storageURL(
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("XMterm", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    func load() async throws -> SessionProfileLoadResult {
        if fileSystem.fileExists(at: fileURL) {
            try repairPermissions(for: fileURL)
            return try loadPrimary()
        }
        return try loadPreservedRecoveryOrReportUninitialized()
    }

    func save(_ collection: SessionProfileCollection) async throws {
        guard collection.profiles.count <= Self.maximumProfileCount else {
            throw SessionProfileRepositoryError.profileLimitExceeded(
                maximumCount: Self.maximumProfileCount
            )
        }
        let encodedData: Data
        do {
            encodedData = try SessionProfileDocumentCodec.encode(collection)
        } catch {
            throw SessionProfileRepositoryError.encodingFailed
        }
        guard encodedData.count <= Self.maximumDocumentBytes else {
            throw SessionProfileRepositoryError.documentTooLarge(
                maximumBytes: Self.maximumDocumentBytes
            )
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileSystem.createDirectory(at: directoryURL, permissions: 0o700)
        } catch {
            throw SessionProfileRepositoryError.directoryPreparationFailed(directoryURL)
        }

        let temporaryURL = uniqueSiblingURL(
            prefix: "sessions.tmp-",
            suffix: makeTemporarySuffix()
        )
        do {
            try fileSystem.writeUserOnlyFile(encodedData, to: temporaryURL)
        } catch {
            try? fileSystem.removeItemIfPresent(at: temporaryURL)
            throw SessionProfileRepositoryError.temporaryWriteFailed(temporaryURL)
        }

        if fileSystem.fileExists(at: fileURL) {
            do {
                try fileSystem.replaceItem(at: fileURL, with: temporaryURL)
            } catch {
                try? fileSystem.removeItemIfPresent(at: temporaryURL)
                throw SessionProfileRepositoryError.atomicReplaceFailed(fileURL)
            }
        } else {
            do {
                try fileSystem.moveItem(at: temporaryURL, to: fileURL)
            } catch {
                try? fileSystem.removeItemIfPresent(at: temporaryURL)
                throw SessionProfileRepositoryError.atomicMoveFailed(fileURL)
            }
        }
    }

    private func loadPrimary() throws -> SessionProfileLoadResult {
        let data = try read(fileURL)
        guard data.count <= Self.maximumDocumentBytes else {
            return try preservePrimary(
                recoveredCollection: SessionProfileCollection(),
                issues: [
                    .documentTooLarge(maximumBytes: Self.maximumDocumentBytes)
                ]
            )
        }
        switch SessionProfileDocumentCodec.decode(data) {
        case .loaded(let collection):
            return .loaded(collection)

        case let .recovery(collection, issues):
            return try preservePrimary(
                recoveredCollection: collection,
                issues: issues
            )
        }
    }

    private func preservePrimary(
        recoveredCollection: SessionProfileCollection,
        issues: [SessionProfileRecoveryIssue]
    ) throws -> SessionProfileLoadResult {
        let recoveryURL = uniqueSiblingURL(
            prefix: "sessions.corrupt-",
            suffix: makeRecoverySuffix()
        )
        do {
            try fileSystem.moveItem(at: fileURL, to: recoveryURL)
        } catch {
            throw SessionProfileRepositoryError.corruptFilePreservationFailed(fileURL)
        }
        return .recoveryRequired(
            SessionProfileRecovery(
                preservedFileURL: recoveryURL,
                recoveredCollection: recoveredCollection,
                issues: issues
            )
        )
    }

    private func loadPreservedRecoveryOrReportUninitialized() throws
        -> SessionProfileLoadResult {
        let directoryURL = fileURL.deletingLastPathComponent()
        guard fileSystem.fileExists(at: directoryURL) else {
            return .uninitialized
        }
        do {
            try fileSystem.setPermissions(0o700, of: directoryURL)
        } catch {
            throw SessionProfileRepositoryError.permissionRepairFailed(directoryURL)
        }

        let entries: [URL]
        do {
            entries = try fileSystem.contentsOfDirectory(at: directoryURL)
        } catch {
            throw SessionProfileRepositoryError.recoveryScanFailed(directoryURL)
        }
        guard let recoveryURL = entries
            .filter(isRecoverySibling)
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .first else {
            return .uninitialized
        }

        do {
            try fileSystem.setPermissions(0o600, of: recoveryURL)
        } catch {
            throw SessionProfileRepositoryError.permissionRepairFailed(recoveryURL)
        }

        let data = try read(recoveryURL)
        let collection: SessionProfileCollection
        var issues: [SessionProfileRecoveryIssue]
        if data.count > Self.maximumDocumentBytes {
            collection = SessionProfileCollection()
            issues = [
                .documentTooLarge(maximumBytes: Self.maximumDocumentBytes)
            ]
        } else {
            switch SessionProfileDocumentCodec.decode(data) {
            case .loaded(let loadedCollection):
                collection = loadedCollection
                issues = []
            case let .recovery(recoveredCollection, recoveryIssues):
                collection = recoveredCollection
                issues = recoveryIssues
            }
        }
        if !issues.contains(.preservedRecoveryFile) {
            issues.append(.preservedRecoveryFile)
        }
        return .recoveryRequired(
            SessionProfileRecovery(
                preservedFileURL: recoveryURL,
                recoveredCollection: collection,
                issues: issues
            )
        )
    }

    private func read(_ url: URL) throws -> Data {
        do {
            return try fileSystem.read(
                from: url,
                upToByteCount: Self.maximumDocumentBytes + 1
            )
        } catch {
            throw SessionProfileRepositoryError.readFailed(url)
        }
    }

    private func repairPermissions(for existingFileURL: URL) throws {
        let directoryURL = existingFileURL.deletingLastPathComponent()
        do {
            try fileSystem.setPermissions(0o700, of: directoryURL)
            try fileSystem.setPermissions(0o600, of: existingFileURL)
        } catch {
            throw SessionProfileRepositoryError.permissionRepairFailed(existingFileURL)
        }
    }

    private func uniqueSiblingURL(prefix: String, suffix: String) -> URL {
        let directoryURL = fileURL.deletingLastPathComponent()
        let requested = directoryURL.appendingPathComponent(
            "\(prefix)\(suffix).json",
            isDirectory: false
        )
        guard fileSystem.fileExists(at: requested) else { return requested }
        return directoryURL.appendingPathComponent(
            "\(prefix)\(suffix)-\(UUID().uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private func isRecoverySibling(_ url: URL) -> Bool {
        url.pathExtension == "json"
            && url.deletingPathExtension().lastPathComponent.hasPrefix("sessions.corrupt-")
    }
}

private enum SessionProfileDocumentDecodeResult {
    case loaded(SessionProfileCollection)
    case recovery(SessionProfileCollection, [SessionProfileRecoveryIssue])
}

private enum SessionProfileDocumentCodec {
    private struct Envelope: Encodable {
        let schemaVersion: Int
        let profiles: [SessionProfile]
    }

    static func encode(_ collection: SessionProfileCollection) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(encodeDate(date))
        }
        return try encoder.encode(
            Envelope(
                schemaVersion: JSONSessionProfileRepository.schemaVersion,
                profiles: collection.profiles
            )
        )
    }

    static func decode(_ data: Data) -> SessionProfileDocumentDecodeResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return recoveryResult(profiles: [], issues: [.malformedDocument])
        }

        guard let version = integerSchemaVersion(root["schemaVersion"]) else {
            return recoveryResult(profiles: [], issues: [.malformedDocument])
        }
        guard version == JSONSessionProfileRepository.schemaVersion else {
            return recoveryResult(
                profiles: [],
                issues: [.unsupportedSchema(version: version)]
            )
        }
        guard let encodedProfiles = root["profiles"] as? [Any] else {
            return recoveryResult(profiles: [], issues: [.malformedDocument])
        }

        var issues: [SessionProfileRecoveryIssue] = []
        if Set(root.keys) != ["schemaVersion", "profiles"] {
            issues.append(.malformedDocument)
        }

        let decoder = profileDecoder()
        var profiles: [SessionProfile] = []
        var seenIDs: Set<SessionProfileID> = []
        var rejectedCount = max(
            0,
            encodedProfiles.count - JSONSessionProfileRepository.maximumProfileCount
        )
        if encodedProfiles.count > JSONSessionProfileRepository.maximumProfileCount {
            issues.append(
                .profileLimitExceeded(
                    maximumCount: JSONSessionProfileRepository.maximumProfileCount
                )
            )
        }
        for encodedProfile in encodedProfiles.prefix(
            JSONSessionProfileRepository.maximumProfileCount
        ) {
            guard JSONSerialization.isValidJSONObject(encodedProfile),
                  let profileData = try? JSONSerialization.data(
                    withJSONObject: encodedProfile,
                    options: [.sortedKeys]
                  ),
                  let decoded = try? decoder.decode(SessionProfile.self, from: profileData),
                  let validated = try? SessionProfileValidator.validatedProfile(decoded),
                  !seenIDs.contains(validated.id) else {
                rejectedCount += 1
                continue
            }
            seenIDs.insert(validated.id)
            profiles.append(validated)
        }
        if rejectedCount > 0 {
            issues.append(.rejectedProfiles(count: rejectedCount))
        }

        if issues.isEmpty,
           let collection = try? SessionProfileCollection(profiles: profiles) {
            return .loaded(collection)
        }
        return recoveryResult(profiles: profiles, issues: issues)
    }

    private static func recoveryResult(
        profiles: [SessionProfile],
        issues: [SessionProfileRecoveryIssue]
    ) -> SessionProfileDocumentDecodeResult {
        let collection = (try? SessionProfileCollection(profiles: profiles))
            ?? SessionProfileCollection()
        return .recovery(collection, issues)
    }

    private static func profileDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = decodeDate(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 UTC date."
                )
            }
            return date
        }
        return decoder
    }

    private static func integerSchemaVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            return nil
        }
        return number.intValue
    }

    private static func encodeDate(_ date: Date) -> String {
        let totalMilliseconds = Int64(
            (date.timeIntervalSince1970 * 1_000).rounded()
        )
        var wholeSeconds = totalMilliseconds / 1_000
        var milliseconds = totalMilliseconds % 1_000
        if milliseconds < 0 {
            wholeSeconds -= 1
            milliseconds += 1_000
        }
        let wholeDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let base = wholeDate.formatted(Date.ISO8601FormatStyle())
        let withoutZulu = base.hasSuffix("Z") ? String(base.dropLast()) : base
        return String(format: "%@.%03lldZ", withoutZulu, milliseconds)
    }

    private static func decodeDate(_ value: String) -> Date? {
        guard value.hasSuffix("Z") else { return nil }
        let withoutZulu = value.dropLast()
        guard let separator = withoutZulu.lastIndex(of: ".") else {
            return try? Date.ISO8601FormatStyle().parse(value)
        }
        let fractionalDigits = withoutZulu[withoutZulu.index(after: separator)...]
        guard fractionalDigits.count == 3,
              fractionalDigits.allSatisfy(\.isNumber),
              let milliseconds = Int(fractionalDigits) else {
            return nil
        }
        let baseValue = "\(withoutZulu[..<separator])Z"
        guard let baseDate = try? Date.ISO8601FormatStyle().parse(baseValue) else {
            return nil
        }
        return baseDate.addingTimeInterval(TimeInterval(milliseconds) / 1_000)
    }
}
