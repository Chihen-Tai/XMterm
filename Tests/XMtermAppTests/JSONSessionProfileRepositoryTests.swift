import Foundation
import Testing
import XMtermCore
@testable import XMtermApp

@Suite("JSON session profile repository", .serialized)
struct JSONSessionProfileRepositoryTests {
    @Test("The production resolver appends the bundle-appropriate XMterm sessions path")
    func productionPathUsesApplicationSupportBase() {
        let base = URL(fileURLWithPath: "/Users/example/Library/Application Support")

        let resolved = JSONSessionProfileRepository.storageURL(
            applicationSupportDirectory: base
        )

        #expect(
            resolved.path == "/Users/example/Library/Application Support/XMterm/sessions.json"
        )
    }

    @Test("A missing primary and no recovery file is uninitialized without creating files")
    func missingStoreIsUninitializedAndReadOnly() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)

        let result = try await repository.load()

        #expect(result == .uninitialized)
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directoryURL.path))
    }

    @Test("Save and reload preserve ordered profiles through schema version 1")
    func saveReloadSchemaDeterminismPermissionsAndSecurity() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()

        try await repository.save(collection)
        let firstBytes = try Data(contentsOf: fixture.primaryURL)
        let result = try await repository.load()
        let loaded = try requireLoaded(result)
        let document = try requireJSONObject(firstBytes)
        let text = try #require(String(data: firstBytes, encoding: .utf8))

        #expect(loaded == collection)
        #expect(document["schemaVersion"] as? Int == 1)
        #expect((document["profiles"] as? [Any])?.count == collection.profiles.count)
        #expect(text.contains("T"))
        #expect(text.contains("Z"))
        #expect(text.contains("\"kind\""))
        #expect(text.contains("\"mode\""))
        assertNoCredentialKeys(in: document)
        #expect(try permissions(of: fixture.directoryURL) == 0o700)
        #expect(try permissions(of: fixture.primaryURL) == 0o600)

        try await repository.save(collection)
        let secondBytes = try Data(contentsOf: fixture.primaryURL)
        #expect(secondBytes == firstBytes)
        #expect(try permissions(of: fixture.primaryURL) == 0o600)
        #expect(try temporaryFiles(in: fixture.directoryURL).isEmpty)
    }

    @Test("A valid empty document remains initialized and is never treated as first launch")
    func validEmptyDocumentRemainsInitialized() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)

        try await repository.save(SessionProfileCollection())
        let result = try await repository.load()
        let loaded = try requireLoaded(result)

        #expect(loaded.profiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.primaryURL.path))
    }

    @Test("Save rejects collections beyond the load-time profile limit")
    func saveEnforcesProfileLimit() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let profiles = (0...JSONSessionProfileRepository.maximumProfileCount).map { index in
            SessionProfile(
                id: SessionProfileID(),
                name: "Profile \(index)",
                favorite: false,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastOpenedAt: nil,
                sortOrder: index,
                configuration: .local(
                    LocalSessionProfile(
                        useLoginShell: true,
                        shellPath: nil,
                        workingDirectory: nil
                    )
                )
            )
        }
        let collection = try SessionProfileCollection(profiles: profiles)

        do {
            try await repository.save(collection)
            Issue.record("Expected save profile limit failure")
        } catch let error as SessionProfileRepositoryError {
            #expect(
                error == .profileLimitExceeded(
                    maximumCount: JSONSessionProfileRepository.maximumProfileCount
                )
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.directoryURL.path))
    }

    @Test("Save rejects an encoded document beyond the load-time byte limit")
    func saveEnforcesDocumentByteLimit() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let profile = SessionProfile(
            id: SessionProfileID(),
            name: String(
                repeating: "x",
                count: JSONSessionProfileRepository.maximumDocumentBytes
            ),
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
        let collection = try SessionProfileCollection(profiles: [profile])

        do {
            try await repository.save(collection)
            Issue.record("Expected save document-size failure")
        } catch let error as SessionProfileRepositoryError {
            #expect(
                error == .documentTooLarge(
                    maximumBytes: JSONSessionProfileRepository.maximumDocumentBytes
                )
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.directoryURL.path))
    }

    @Test("Loading repairs permissive legacy directory and file modes before decoding")
    func loadRepairsExistingPermissions() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()
        try await repository.save(collection)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.directoryURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.primaryURL.path
        )

        #expect(try await repository.load() == .loaded(collection))
        #expect(try permissions(of: fixture.directoryURL) == 0o700)
        #expect(try permissions(of: fixture.primaryURL) == 0o600)
    }

    @Test("ISO-8601 persistence documents the millisecond date precision policy")
    func datesRoundTripWithinDocumentedMillisecondPrecision() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let preciseDate = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let profile = SessionProfile(
            id: profileID("11111111-2222-3333-4444-555555555555"),
            name: "Precise Date",
            favorite: false,
            createdAt: preciseDate,
            updatedAt: preciseDate,
            lastOpenedAt: preciseDate,
            sortOrder: 0,
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
        let collection = try SessionProfileCollection(profiles: [profile])

        try await repository.save(collection)
        let loaded = try requireLoaded(try await repository.load())
        let loadedDate = try #require(loaded.profiles.first?.createdAt)
        let text = try #require(
            String(data: Data(contentsOf: fixture.primaryURL), encoding: .utf8)
        )

        #expect(abs(loadedDate.timeIntervalSince(preciseDate)) <= 0.001)
        #expect(text.contains(".123Z"))
    }

    @Test("Atomic replacement failure retains the prior primary and removes staging files")
    func replacementFailureRetainsPriorPrimary() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let original = try makeCollection()
        let realRepository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        try await realRepository.save(original)
        let originalBytes = try Data(contentsOf: fixture.primaryURL)
        let changed = try original.renaming(
            id: try #require(original.profiles.first?.id),
            to: "Renamed Local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let repository = JSONSessionProfileRepository(
            fileURL: fixture.primaryURL,
            fileSystem: FailingSessionProfileFileSystem(failure: .replace)
        )

        do {
            try await repository.save(changed)
            Issue.record("Expected atomic replacement to fail")
        } catch let error as SessionProfileRepositoryError {
            #expect(error == .atomicReplaceFailed(fixture.primaryURL))
        }

        #expect(try Data(contentsOf: fixture.primaryURL) == originalBytes)
        #expect(try temporaryFiles(in: fixture.directoryURL).isEmpty)
        #expect(try await realRepository.load() == .loaded(original))
    }

    @Test("Temporary write failure leaves an existing primary untouched")
    func writeFailureRetainsPriorPrimary() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let collection = try makeCollection()
        let realRepository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        try await realRepository.save(collection)
        let originalBytes = try Data(contentsOf: fixture.primaryURL)
        let repository = JSONSessionProfileRepository(
            fileURL: fixture.primaryURL,
            fileSystem: FailingSessionProfileFileSystem(failure: .write)
        )

        do {
            try await repository.save(collection)
            Issue.record("Expected temporary write to fail")
        } catch let error as SessionProfileRepositoryError {
            guard case .temporaryWriteFailed = error else {
                Issue.record("Expected temporaryWriteFailed, received \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: fixture.primaryURL) == originalBytes)
        #expect(try temporaryFiles(in: fixture.directoryURL).isEmpty)
    }

    @Test("First-save atomic move failure leaves no primary or staging artifact")
    func firstMoveFailureLeavesStoreUninitialized() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(
            fileURL: fixture.primaryURL,
            fileSystem: FailingSessionProfileFileSystem(failure: .move)
        )

        do {
            try await repository.save(try makeCollection())
            Issue.record("Expected first-save move to fail")
        } catch let error as SessionProfileRepositoryError {
            #expect(error == .atomicMoveFailed(fixture.primaryURL))
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
        #expect(try temporaryFiles(in: fixture.directoryURL).isEmpty)
    }

    @Test("A corrupt primary is preserved and never replaced during load")
    func corruptPrimaryIsPreservedForExplicitRecovery() async throws {
        let fixture = try RepositoryFixture(createDirectory: true)
        defer { fixture.remove() }
        let corruptBytes = Data("{ definitely-not-json".utf8)
        try corruptBytes.write(to: fixture.primaryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.directoryURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.primaryURL.path
        )
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)

        let result = try await repository.load()
        let recovery = try requireRecovery(result)

        #expect(recovery.recoveredCollection.profiles.isEmpty)
        #expect(recovery.issues.contains(.malformedDocument))
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
        #expect(FileManager.default.fileExists(atPath: recovery.preservedFileURL.path))
        #expect(try Data(contentsOf: recovery.preservedFileURL) == corruptBytes)
        #expect(try permissions(of: fixture.directoryURL) == 0o700)
        #expect(try permissions(of: recovery.preservedFileURL) == 0o600)
    }

    @Test("Oversized documents are bounded and preserved without JSON materialization")
    func oversizedDocumentEntersRecovery() async throws {
        let fixture = try RepositoryFixture(createDirectory: true)
        defer { fixture.remove() }
        let bytes = Data(
            repeating: 0x41,
            count: JSONSessionProfileRepository.maximumDocumentBytes + 1
        )
        try bytes.write(to: fixture.primaryURL)
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(
            recovery.issues.contains(
                .documentTooLarge(
                    maximumBytes: JSONSessionProfileRepository.maximumDocumentBytes
                )
            )
        )
        #expect(
            try Data(contentsOf: recovery.preservedFileURL).count
                == JSONSessionProfileRepository.maximumDocumentBytes + 1
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
    }

    @Test("Profile-array processing is capped while the original document is preserved")
    func profileCountIsBounded() async throws {
        let fixture = try RepositoryFixture(createDirectory: true)
        defer { fixture.remove() }
        let count = JSONSessionProfileRepository.maximumProfileCount + 1
        let document: [String: Any] = [
            "schemaVersion": 1,
            "profiles": Array(repeating: ["invalid": true], count: count)
        ]
        try writeJSONObject(document, to: fixture.primaryURL)
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(
            recovery.issues.contains(
                .profileLimitExceeded(
                    maximumCount: JSONSessionProfileRepository.maximumProfileCount
                )
            )
        )
        #expect(recovery.issues.contains(.rejectedProfiles(count: count)))
        #expect(recovery.recoveredCollection.profiles.isEmpty)
        #expect(FileManager.default.fileExists(atPath: recovery.preservedFileURL.path))
    }

    @Test("One malformed profile does not discard valid siblings")
    func partialEntryRecoveryPreservesValidProfiles() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()
        try await repository.save(collection)
        var document = try requireJSONObject(Data(contentsOf: fixture.primaryURL))
        var profiles = try #require(document["profiles"] as? [Any])
        profiles.append(["kind": "ssh", "name": "Broken"])
        document["profiles"] = profiles
        let partialBytes = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try partialBytes.write(to: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(recovery.recoveredCollection == collection)
        #expect(recovery.issues.contains(.rejectedProfiles(count: 1)))
        #expect(try Data(contentsOf: recovery.preservedFileURL) == partialBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
    }

    @Test("Duplicate IDs retain the first valid profile and reject later entries")
    func duplicateIDsRequireRecoveryWithoutLosingTheFirstProfile() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()
        try await repository.save(collection)
        var document = try requireJSONObject(Data(contentsOf: fixture.primaryURL))
        var profiles = try #require(document["profiles"] as? [Any])
        profiles.append(try #require(profiles.first))
        document["profiles"] = profiles
        try writeJSONObject(document, to: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(recovery.recoveredCollection == collection)
        #expect(recovery.issues.contains(.rejectedProfiles(count: 1)))
    }

    @Test("Structurally invalid entries are rejected while valid siblings survive")
    func structurallyInvalidEntryDoesNotLoseSiblings() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()
        try await repository.save(collection)
        var document = try requireJSONObject(Data(contentsOf: fixture.primaryURL))
        var profiles = try #require(document["profiles"] as? [[String: Any]])
        var invalid = profiles[1]
        var ssh = try #require(invalid["ssh"] as? [String: Any])
        ssh["host"] = "bad host"
        invalid["ssh"] = ssh
        profiles[1] = invalid
        document["profiles"] = profiles
        try writeJSONObject(document, to: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(
            recovery.recoveredCollection.profiles == [
                collection.profiles[0],
                collection.profiles[2]
            ]
        )
        #expect(recovery.issues.contains(.rejectedProfiles(count: 1)))
    }

    @Test("An unknown schema is preserved and never decoded or downgraded")
    func unsupportedSchemaIsPreservedWithoutPrimaryRewrite() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        try await repository.save(try makeCollection())
        var document = try requireJSONObject(Data(contentsOf: fixture.primaryURL))
        document["schemaVersion"] = 99
        try writeJSONObject(document, to: fixture.primaryURL)
        let unsupportedBytes = try Data(contentsOf: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(recovery.recoveredCollection.profiles.isEmpty)
        #expect(recovery.issues.contains(.unsupportedSchema(version: 99)))
        #expect(try Data(contentsOf: recovery.preservedFileURL) == unsupportedBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
    }

    @Test("Unknown envelope keys enter recovery and are never copied to a new primary")
    func unknownEnvelopeKeyRequiresExplicitRecovery() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()
        try await repository.save(collection)
        var document = try requireJSONObject(Data(contentsOf: fixture.primaryURL))
        document["password"] = "must-not-survive"
        try writeJSONObject(document, to: fixture.primaryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(recovery.recoveredCollection == collection)
        #expect(recovery.issues.contains(.malformedDocument))
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
        #expect(FileManager.default.fileExists(atPath: recovery.preservedFileURL.path))
    }

    @Test("A preserved recovery file prevents accidental first-launch reseeding")
    func missingPrimaryWithRecoverySiblingContinuesRecoveryMode() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = JSONSessionProfileRepository(fileURL: fixture.primaryURL)
        let collection = try makeCollection()
        try await repository.save(collection)
        let recoveryURL = fixture.directoryURL
            .appendingPathComponent("sessions.corrupt-existing.json")
        try FileManager.default.moveItem(at: fixture.primaryURL, to: recoveryURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.directoryURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: recoveryURL.path
        )
        let preservedBytes = try Data(contentsOf: recoveryURL)

        let recovery = try requireRecovery(try await repository.load())

        #expect(
            recovery.preservedFileURL.resolvingSymlinksInPath()
                == recoveryURL.resolvingSymlinksInPath()
        )
        #expect(recovery.recoveredCollection == collection)
        #expect(recovery.issues.contains(.preservedRecoveryFile))
        #expect(!FileManager.default.fileExists(atPath: fixture.primaryURL.path))
        #expect(try Data(contentsOf: recoveryURL) == preservedBytes)
        #expect(try permissions(of: fixture.directoryURL) == 0o700)
        #expect(try permissions(of: recoveryURL) == 0o600)
    }

    @Test("Read failure is typed and leaves the primary in place")
    func readFailureDoesNotDestroyPrimary() async throws {
        let fixture = try RepositoryFixture(createDirectory: true)
        defer { fixture.remove() }
        try Data("opaque".utf8).write(to: fixture.primaryURL)
        let repository = JSONSessionProfileRepository(
            fileURL: fixture.primaryURL,
            fileSystem: FailingSessionProfileFileSystem(failure: .read)
        )

        do {
            _ = try await repository.load()
            Issue.record("Expected read failure")
        } catch let error as SessionProfileRepositoryError {
            #expect(error == .readFailed(fixture.primaryURL))
        }

        #expect(FileManager.default.fileExists(atPath: fixture.primaryURL.path))
    }

    @Test("Preservation failure is typed and leaves corrupt primary bytes in place")
    func preservationFailureDoesNotDestroyPrimary() async throws {
        let fixture = try RepositoryFixture(createDirectory: true)
        defer { fixture.remove() }
        let bytes = Data("not-json".utf8)
        try bytes.write(to: fixture.primaryURL)
        let repository = JSONSessionProfileRepository(
            fileURL: fixture.primaryURL,
            fileSystem: FailingSessionProfileFileSystem(failure: .move)
        )

        do {
            _ = try await repository.load()
            Issue.record("Expected corrupt-file preservation failure")
        } catch let error as SessionProfileRepositoryError {
            #expect(error == .corruptFilePreservationFailed(fixture.primaryURL))
        }

        #expect(try Data(contentsOf: fixture.primaryURL) == bytes)
    }

    private func makeCollection() throws -> SessionProfileCollection {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let openedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let profiles = [
            SessionProfile(
                id: profileID("AAAAAAAA-0000-0000-0000-000000000001"),
                name: "Local Terminal",
                favorite: true,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastOpenedAt: openedAt,
                sortOrder: 0,
                configuration: .local(
                    LocalSessionProfile(
                        useLoginShell: false,
                        shellPath: "/bin/zsh",
                        workingDirectory: "/Users/example/Projects"
                    )
                )
            ),
            SessionProfile(
                id: profileID("AAAAAAAA-0000-0000-0000-000000000002"),
                name: "Direct SSH",
                favorite: false,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastOpenedAt: nil,
                sortOrder: 1,
                configuration: .ssh(
                    .direct(
                        host: "host.example.test",
                        port: 2_222,
                        user: "example-user",
                        identityFilePath: "/Users/example/.ssh/id_test"
                    )
                )
            ),
            SessionProfile(
                id: profileID("AAAAAAAA-0000-0000-0000-000000000003"),
                name: "Alias SSH",
                favorite: true,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastOpenedAt: nil,
                sortOrder: 2,
                configuration: .ssh(.configAlias(alias: "research-cluster"))
            )
        ]
        return try SessionProfileCollection(profiles: profiles)
    }

    private func requireLoaded(
        _ result: SessionProfileLoadResult
    ) throws -> SessionProfileCollection {
        guard case .loaded(let collection) = result else {
            Issue.record("Expected a loaded profile collection, received \(result)")
            throw RepositoryTestError.unexpectedResult
        }
        return collection
    }

    private func requireRecovery(
        _ result: SessionProfileLoadResult
    ) throws -> SessionProfileRecovery {
        guard case .recoveryRequired(let recovery) = result else {
            Issue.record("Expected recovery-required state, received \(result)")
            throw RepositoryTestError.unexpectedResult
        }
        return recovery
    }
}

private struct RepositoryFixture {
    let rootURL: URL
    let directoryURL: URL
    let primaryURL: URL

    init(createDirectory: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmterm-session-repository-\(UUID().uuidString)")
        directoryURL = rootURL.appendingPathComponent("XMterm")
        primaryURL = directoryURL.appendingPathComponent("sessions.json")
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum RepositoryTestError: Error {
    case unexpectedResult
    case injectedFailure
}

private enum InjectedFileSystemFailure {
    case read
    case write
    case move
    case replace
}

private struct FailingSessionProfileFileSystem: SessionProfileFileSystem {
    let failure: InjectedFileSystemFailure
    private let base = FoundationSessionProfileFileSystem()

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func read(from url: URL) throws -> Data {
        if failure == .read { throw RepositoryTestError.injectedFailure }
        return try base.read(
            from: url,
            upToByteCount: JSONSessionProfileRepository.maximumDocumentBytes + 1
        )
    }

    func read(from url: URL, upToByteCount maximumByteCount: Int) throws -> Data {
        if failure == .read { throw RepositoryTestError.injectedFailure }
        return try base.read(from: url, upToByteCount: maximumByteCount)
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        try base.createDirectory(at: url, permissions: permissions)
    }

    func setPermissions(_ permissions: Int, of url: URL) throws {
        try base.setPermissions(permissions, of: url)
    }

    func writeUserOnlyFile(_ data: Data, to url: URL) throws {
        if failure == .write { throw RepositoryTestError.injectedFailure }
        try base.writeUserOnlyFile(data, to: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if failure == .move { throw RepositoryTestError.injectedFailure }
        try base.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        if failure == .replace { throw RepositoryTestError.injectedFailure }
        try base.replaceItem(at: destinationURL, with: sourceURL)
    }

    func removeItemIfPresent(at url: URL) throws {
        try base.removeItemIfPresent(at: url)
    }
}

private func requireJSONObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url)
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        & 0o777
}

private func temporaryFiles(in directoryURL: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("sessions.tmp-") }
}

private func assertNoCredentialKeys(in value: Any) {
    let forbidden: Set<String> = [
        "password",
        "otp",
        "passphrase",
        "privatekey",
        "privatekeycontent"
    ]
    let keys = allJSONKeys(in: value).map {
        $0.lowercased().filter(\.isLetter)
    }
    #expect(forbidden.isDisjoint(with: keys))
}

private func allJSONKeys(in value: Any) -> Set<String> {
    if let dictionary = value as? [String: Any] {
        return dictionary.reduce(into: Set(dictionary.keys)) { result, entry in
            result.formUnion(allJSONKeys(in: entry.value))
        }
    }
    if let array = value as? [Any] {
        return array.reduce(into: []) { result, element in
            result.formUnion(allJSONKeys(in: element))
        }
    }
    return []
}

private func profileID(_ value: String) -> SessionProfileID {
    SessionProfileID(rawValue: UUID(uuidString: value)!)
}
