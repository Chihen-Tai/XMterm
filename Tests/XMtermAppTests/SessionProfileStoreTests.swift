import Foundation
import Testing
import XMtermCore
@testable import XMtermApp

@MainActor
@Suite("Session profile store", .serialized)
struct SessionProfileStoreTests {
    @Test("[SESS-007] Missing storage seeds and persists the two defaults exactly once")
    func uninitializedSeedsDefaultsExactlyOnce() async throws {
        let localID = profileID("10000000-0000-0000-0000-000000000001")
        let relayID = profileID("10000000-0000-0000-0000-000000000002")
        let seedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = InMemorySessionProfileRepository(result: .uninitialized)
        var identifiers = [localID, relayID]
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { seedDate },
            idSource: { identifiers.removeFirst() }
        )

        #expect(store.state == .loading)
        await store.load()

        #expect(store.state == .content)
        #expect(store.profiles.map(\.id) == [localID, relayID])
        #expect(store.profiles.map(\.name) == ["Local Terminal", "Relay Host"])
        #expect(store.profiles.allSatisfy { $0.createdAt == seedDate })
        let relay = try #require(store.profiles.last)
        #expect(
            relay.configuration == .ssh(
                .direct(
                    host: "140.109.226.155",
                    port: 54_426,
                    user: "allen921103",
                    identityFilePath: nil
                )
            )
        )
        #expect(await repository.savedCollections().count == 1)

        let reloadedStore = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { Date.distantFuture },
            idSource: {
                Issue.record("Reloading initialized storage must not generate another ID")
                return SessionProfileID()
            }
        )
        await reloadedStore.load()

        #expect(reloadedStore.collection == store.collection)
        #expect(await repository.savedCollections().count == 1)
        #expect(await repository.loadInvocationCount() == 2)
    }

    @Test("[SESS-007] A valid empty collection remains empty and is never reseeded")
    func validEmptyCollectionIsInitialized() async {
        let repository = InMemorySessionProfileRepository(
            result: .loaded(SessionProfileCollection())
        )
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            idSource: {
                Issue.record("An initialized empty collection must not generate IDs")
                return SessionProfileID()
            }
        )

        await store.load()

        #expect(store.state == .content)
        #expect(store.profiles.isEmpty)
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-007] Renamed and deleted defaults survive a new store load")
    func changedDefaultsPersistAcrossReload() async throws {
        let localID = profileID("20000000-0000-0000-0000-000000000001")
        let relayID = profileID("20000000-0000-0000-0000-000000000002")
        let repository = InMemorySessionProfileRepository(result: .uninitialized)
        var identifiers = [localID, relayID]
        var dates = dateSource(startingAt: 1_700_000_000)
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { dates.next() },
            idSource: { identifiers.removeFirst() }
        )
        await store.load()

        #expect(await store.rename(id: localID, to: "My Shell"))
        #expect(await store.delete(id: relayID))

        let reloadedStore = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await reloadedStore.load()

        #expect(reloadedStore.profiles.map(\.id) == [localID])
        #expect(reloadedStore.profiles.map(\.name) == ["My Shell"])
        #expect(await repository.savedCollections().count == 3)
    }

    @Test("[APP-004, SESS-010] Load failure enters a typed retryable error state")
    func loadFailureIsExplicit() async {
        let repository = InMemorySessionProfileRepository(result: .uninitialized)
        await repository.setLoadFailure(true)
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )

        await store.load()

        #expect(store.state == .error)
        #expect(store.lastFailure == .load)
        #expect(store.profiles.isEmpty)
        #expect(store.lastFailure?.userMessage == "XMterm couldn’t load saved sessions. Try again.")
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-007, SESS-010] Failed first-launch persistence publishes no defaults")
    func seedSaveFailureLeavesPublishedStateEmpty() async {
        let repository = InMemorySessionProfileRepository(result: .uninitialized)
        await repository.setSaveFailure(true)
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )

        await store.load()

        #expect(store.state == .error)
        #expect(store.lastFailure == .persistence)
        #expect(store.profiles.isEmpty)
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-010] Recovery blocks ordinary mutations until recovered profiles are accepted")
    func recoveryRequiresExplicitAcceptance() async throws {
        let recovered = try collection(
            profile(
                id: profileID("30000000-0000-0000-0000-000000000001"),
                name: "Recovered"
            )
        )
        let recovery = SessionProfileRecovery(
            preservedFileURL: URL(fileURLWithPath: "/tmp/sessions.corrupt.json"),
            recoveredCollection: recovered,
            issues: [.rejectedProfiles(count: 1)]
        )
        let repository = InMemorySessionProfileRepository(result: .recoveryRequired(recovery))
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )

        await store.load()

        #expect(store.state == .recoveryRequired)
        #expect(store.collection == recovered)
        #expect(store.recovery == recovery)
        #expect(!store.canMutateProfiles)
        #expect(!(await store.create(from: localDraft(name: "Blocked"))))
        #expect(store.lastFailure == .recoveryActionRequired)
        #expect(await repository.savedCollections().isEmpty)

        #expect(await store.useRecoveredProfiles())
        #expect(store.state == .content)
        #expect(store.collection == recovered)
        #expect(store.recovery == nil)
        #expect(store.canMutateProfiles)
        #expect(await repository.savedCollections() == [recovered])
    }

    @Test("[SESS-010] Empty recovery offers defaults but accepting recovery persists empty")
    func emptyRecoveryDistinguishesRecoveredDataFromDefaultPreview() async {
        let recovery = SessionProfileRecovery(
            preservedFileURL: URL(fileURLWithPath: "/tmp/sessions.corrupt-empty.json"),
            recoveredCollection: SessionProfileCollection(),
            issues: [.malformedDocument]
        )
        let repository = InMemorySessionProfileRepository(result: .recoveryRequired(recovery))
        var identifiers = [
            profileID("40000000-0000-0000-0000-000000000001"),
            profileID("40000000-0000-0000-0000-000000000002")
        ]
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            idSource: { identifiers.removeFirst() }
        )

        await store.load()

        #expect(store.state == .recoveryRequired)
        #expect(store.profiles.map(\.name) == ["Local Terminal", "Relay Host"])
        #expect(await store.useRecoveredProfiles())
        #expect(store.profiles.isEmpty)
        #expect(await repository.savedCollections() == [SessionProfileCollection()])
    }

    @Test("[SESS-010] Reset to defaults replaces recovery only after a successful save")
    func resetRecoveryToDefaults() async {
        let recovery = SessionProfileRecovery(
            preservedFileURL: URL(fileURLWithPath: "/tmp/sessions.corrupt-reset.json"),
            recoveredCollection: SessionProfileCollection(),
            issues: [.unsupportedSchema(version: 2)]
        )
        let repository = InMemorySessionProfileRepository(result: .recoveryRequired(recovery))
        var identifiers = [
            profileID("50000000-0000-0000-0000-000000000001"),
            profileID("50000000-0000-0000-0000-000000000002")
        ]
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            idSource: { identifiers.removeFirst() }
        )
        await store.load()
        let preview = store.collection

        await repository.setSaveFailure(true)
        #expect(!(await store.resetToDefaults()))
        #expect(store.state == .recoveryRequired)
        #expect(store.collection == preview)
        #expect(store.recovery == recovery)

        await repository.setSaveFailure(false)
        #expect(await store.resetToDefaults())
        #expect(store.state == .content)
        #expect(store.collection == preview)
        #expect(store.recovery == nil)
        #expect(await repository.savedCollections() == [preview])
    }

    @Test("[APP-004, SESS-010] Failed CRUD writes retain the exact published value")
    func failedWriteDoesNotPublishProposedValue() async throws {
        let id = profileID("60000000-0000-0000-0000-000000000001")
        let original = try collection(profile(id: id, name: "Original"))
        let repository = InMemorySessionProfileRepository(result: .loaded(original))
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await store.load()
        await repository.setSaveFailure(true)

        #expect(!(await store.rename(id: id, to: "Never Published")))

        #expect(store.state == .content)
        #expect(store.collection == original)
        #expect(store.lastFailure == .persistence)
        #expect(
            store.lastFailure?.userMessage
                == "XMterm couldn’t save session changes. Your previous sessions are unchanged."
        )
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-007, SESS-009] CRUD, favorite, and successful-open recency persist")
    func crudFavoriteAndRecencyPersist() async throws {
        let localID = profileID("70000000-0000-0000-0000-000000000001")
        let sshID = profileID("70000000-0000-0000-0000-000000000002")
        let copyID = profileID("70000000-0000-0000-0000-000000000003")
        var identifiers = [localID, sshID, copyID]
        var dates = dateSource(startingAt: 1_700_001_000)
        let repository = InMemorySessionProfileRepository(
            result: .loaded(SessionProfileCollection())
        )
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { dates.next() },
            idSource: { identifiers.removeFirst() }
        )
        await store.load()

        #expect(await store.create(from: localDraft(name: "Local")))
        #expect(await store.create(from: sshDraft(name: "Server")))
        #expect(await store.edit(id: localID, with: localDraft(name: "Edited Local")))
        #expect(await store.duplicate(id: sshID))
        #expect(await store.setFavorite(true, for: localID))
        #expect(await store.recordOpened(id: copyID))
        #expect(await store.delete(id: sshID))

        #expect(store.profiles.map(\.id) == [localID, copyID])
        #expect(store.profiles.map(\.name) == ["Edited Local", "Server Copy"])
        #expect(store.profiles.first?.favorite == true)
        #expect(store.collection.recentProfileIDs() == [copyID])
        #expect(await repository.savedCollections().count == 7)
        #expect(await repository.savedCollections().last == store.collection)
    }

    @Test("[SESS-008] Structural validation prevents persistence and identifies fields")
    func invalidDraftDoesNotPersist() async {
        let repository = InMemorySessionProfileRepository(
            result: .loaded(SessionProfileCollection())
        )
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await store.load()
        let invalid = sshDraft(name: " ", alias: "-unsafe")

        #expect(!(await store.create(from: invalid)))

        guard case .validation(let error)? = store.lastFailure else {
            Issue.record("Expected a structural validation failure")
            return
        }
        #expect(error.fields == [.name, .sshConfigAlias])
        #expect(store.profiles.isEmpty)
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-008] Filesystem validation runs before save without exposing paths")
    func pathValidationDoesNotPersistOrRevealPath() async {
        let issue = SessionProfilePathIssue(field: .identityFilePath, reason: .missing)
        let repository = InMemorySessionProfileRepository(
            result: .loaded(SessionProfileCollection())
        )
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(issues: [issue])
        )
        await store.load()
        let draft = sshDraft(
            name: "Private Host",
            identityFilePath: "/Users/alice/.ssh/private-key"
        )

        #expect(!(await store.create(from: draft)))

        #expect(
            store.lastFailure == .pathValidation(
                profileID: nil,
                issues: [issue]
            )
        )
        #expect(store.profiles.isEmpty)
        #expect(await repository.savedCollections().isEmpty)
        #expect(store.lastFailure?.userMessage.contains("identity file") == true)
        #expect(!(store.lastFailure?.userMessage.contains("/Users/alice") ?? true))
    }

    @Test("[SESS-008] Missing profile operations are typed and non-persistent")
    func missingProfileIsTyped() async {
        let repository = InMemorySessionProfileRepository(
            result: .loaded(SessionProfileCollection())
        )
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await store.load()

        #expect(!(await store.delete(id: SessionProfileID())))

        #expect(store.lastFailure == .profileNotFound)
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-007, SESS-008] explicit launch validation returns the current saved value")
    func launchValidationReturnsCurrentProfileWithoutPersisting() async throws {
        let id = profileID("80000000-0000-0000-0000-000000000001")
        let saved = profile(id: id, name: "Ready")
        let repository = InMemorySessionProfileRepository(
            result: .loaded(try collection(saved))
        )
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await store.load()

        let ready = await store.profileReadyForLaunch(id: id)

        #expect(ready == saved)
        #expect(store.lastFailure == nil)
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-007, SESS-008] failed launch path validation creates no persistence side effect")
    func launchPathFailureIsTypedAndNonPersistent() async throws {
        let id = profileID("80000000-0000-0000-0000-000000000002")
        let saved = profile(
            id: id,
            name: "Unavailable",
            configuration: .local(
                .init(
                    useLoginShell: false,
                    shellPath: "/missing/shell",
                    workingDirectory: nil
                )
            )
        )
        let issue = SessionProfilePathIssue(field: .shellPath, reason: .missing)
        let original = try collection(saved)
        let repository = InMemorySessionProfileRepository(result: .loaded(original))
        let store = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(issues: [issue])
        )
        await store.load()

        #expect(await store.profileReadyForLaunch(id: id) == nil)
        #expect(store.collection == original)
        #expect(
            store.lastFailure == .pathValidation(
                profileID: id,
                issues: [issue]
            )
        )
        #expect(await repository.savedCollections().isEmpty)
        #expect(store.lastFailure?.userMessage.contains("shell executable") == true)
        #expect(!(store.lastFailure?.userMessage.contains("/missing") ?? true))
    }
}

@Suite("Session profile path inspector", .serialized)
struct SessionProfilePathInspectorTests {
    @Test("[SESS-008] Inspector accepts executable shells, directories, and readable files")
    func acceptsValidPaths() async throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let inspector = FoundationSessionProfilePathInspector()

        let local = profile(
            id: SessionProfileID(),
            name: "Custom Local",
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: fixture.executableURL.path,
                    workingDirectory: fixture.directoryURL.path
                )
            )
        )
        let ssh = profile(
            id: SessionProfileID(),
            name: "Direct SSH",
            configuration: .ssh(
                .direct(
                    host: "example.com",
                    port: 22,
                    user: "alice",
                    identityFilePath: fixture.readableFileURL.path
                )
            )
        )

        #expect(await inspector.inspect(local).isEmpty)
        #expect(await inspector.inspect(ssh).isEmpty)
    }

    @Test("[SESS-008] Inspector reports fields and reasons without carrying path values")
    func reportsInvalidPathSemantics() async throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let inspector = FoundationSessionProfilePathInspector()
        let missingDirectory = fixture.rootURL.appending(path: "missing")
        let local = profile(
            id: SessionProfileID(),
            name: "Broken Local",
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: fixture.readableFileURL.path,
                    workingDirectory: missingDirectory.path
                )
            )
        )
        let ssh = profile(
            id: SessionProfileID(),
            name: "Broken SSH",
            configuration: .ssh(
                .direct(
                    host: "example.com",
                    port: 22,
                    user: "alice",
                    identityFilePath: fixture.directoryURL.path
                )
            )
        )

        #expect(
            await inspector.inspect(local) == [
                .init(field: .shellPath, reason: .notExecutable),
                .init(field: .workingDirectory, reason: .missing)
            ]
        )
        #expect(
            await inspector.inspect(ssh) == [
                .init(field: .identityFilePath, reason: .notReadableFile)
            ]
        )
    }
}

private struct PathFixture {
    let rootURL: URL
    let directoryURL: URL
    let executableURL: URL
    let readableFileURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "xmterm-profile-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        directoryURL = rootURL.appending(path: "working", directoryHint: .isDirectory)
        executableURL = rootURL.appending(path: "shell")
        readableFileURL = rootURL.appending(path: "identity")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(
            atPath: executableURL.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard FileManager.default.createFile(
            atPath: readableFileURL.path,
            contents: Data("not-a-real-key".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct IncrementingDateSource {
    private var value: TimeInterval

    init(startingAt value: TimeInterval) {
        self.value = value
    }

    mutating func next() -> Date {
        defer { value += 1 }
        return Date(timeIntervalSince1970: value)
    }
}

private func dateSource(startingAt value: TimeInterval) -> IncrementingDateSource {
    IncrementingDateSource(startingAt: value)
}

private func profileID(_ value: String) -> SessionProfileID {
    SessionProfileID(rawValue: UUID(uuidString: value)!)
}

private func collection(_ profiles: SessionProfile...) throws -> SessionProfileCollection {
    try SessionProfileCollection(profiles: profiles)
}

private func profile(
    id: SessionProfileID,
    name: String,
    configuration: SessionProfileConfiguration = .local(
        LocalSessionProfile(useLoginShell: true, shellPath: nil, workingDirectory: nil)
    )
) -> SessionProfile {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return SessionProfile(
        id: id,
        name: name,
        favorite: false,
        createdAt: date,
        updatedAt: date,
        lastOpenedAt: nil,
        sortOrder: 0,
        configuration: configuration
    )
}

private func localDraft(name: String) -> SessionProfileDraft {
    SessionProfileDraft(
        name: name,
        favorite: false,
        kind: .local,
        local: LocalSessionProfileDraft(
            mode: .loginShell,
            shellPath: "",
            workingDirectory: ""
        ),
        ssh: SSHSessionProfileDraft(
            mode: .direct,
            host: "",
            port: "22",
            user: "",
            sshConfigAlias: "",
            identityFilePath: ""
        )
    )
}

private func sshDraft(
    name: String,
    alias: String? = nil,
    identityFilePath: String = ""
) -> SessionProfileDraft {
    SessionProfileDraft(
        name: name,
        favorite: false,
        kind: .ssh,
        local: LocalSessionProfileDraft(
            mode: .loginShell,
            shellPath: "",
            workingDirectory: ""
        ),
        ssh: SSHSessionProfileDraft(
            mode: alias == nil ? .direct : .configAlias,
            host: "example.com",
            port: "22",
            user: "alice",
            sshConfigAlias: alias ?? "",
            identityFilePath: identityFilePath
        )
    )
}
