import Foundation
import Testing
import XMtermCore
import XMtermTerminal
@testable import XMtermApp

@MainActor
@Suite("Session profile launch coordinator", .serialized)
struct SessionProfileLaunchCoordinatorTests {
    @Test("[SESS-007, SESS-009] successful launch records recency after publishing the tab")
    func successfulLaunchRecordsRecency() async throws {
        let profile = makeProfile()
        let repository = InMemorySessionProfileRepository(
            result: .loaded(try SessionProfileCollection(profiles: [profile]))
        )
        let profileStore = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(),
            clock: { Date(timeIntervalSince1970: 10) }
        )
        await profileStore.load()
        let workspace = makeWorkspace()
        let coordinator = SessionProfileLaunchCoordinator(
            profileStore: profileStore,
            workspace: workspace
        )

        #expect(await coordinator.launch(profile.id))

        try await waitUntil {
            profileStore.profiles.first?.lastOpenedAt == Date(timeIntervalSince1970: 10)
        }

        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs.first?.sourceProfileID == profile.id)
        #expect(profileStore.profiles.first?.lastOpenedAt == Date(timeIntervalSince1970: 10))
        #expect(await repository.savedCollections().count == 1)
        await cleanup(workspace)
    }

    @Test("[SESS-007, SESS-010] failed recency persistence leaves the launched tab intact")
    func recencyFailureDoesNotRollBackLaunch() async throws {
        let profile = makeProfile()
        let original = try SessionProfileCollection(profiles: [profile])
        let repository = InMemorySessionProfileRepository(result: .loaded(original))
        let profileStore = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await profileStore.load()
        await repository.setSaveFailure(true)
        let workspace = makeWorkspace()
        let coordinator = SessionProfileLaunchCoordinator(
            profileStore: profileStore,
            workspace: workspace
        )

        #expect(await coordinator.launch(profile.id))

        try await waitUntil {
            profileStore.lastFailure == .persistence
        }

        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs.first?.sourceProfileID == profile.id)
        #expect(profileStore.collection == original)
        #expect(profileStore.lastFailure == .persistence)
        #expect(await repository.savedCollections().isEmpty)
        await cleanup(workspace)
    }

    @Test("[SESS-007, SESS-008] launch validation failure publishes no workspace state")
    func launchValidationFailureCreatesNoTab() async throws {
        let profile = makeProfile()
        let repository = InMemorySessionProfileRepository(
            result: .loaded(try SessionProfileCollection(profiles: [profile]))
        )
        let profileStore = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector(
                issues: [.init(field: .workingDirectory, reason: .missing)]
            )
        )
        await profileStore.load()
        let workspace = makeWorkspace()
        let coordinator = SessionProfileLaunchCoordinator(
            profileStore: profileStore,
            workspace: workspace
        )

        #expect(!(await coordinator.launch(profile.id)))
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.sessions.isEmpty)
        #expect(profileStore.collection.profiles == [profile])
        #expect(await repository.savedCollections().isEmpty)
    }

    @Test("[SESS-009] runtime publication releases UI before structured recency persistence")
    func runtimePublicationReleasesUIBeforeRecencyPersistence() async throws {
        let profile = makeProfile()
        let repository = SuspendingRecencyRepository(
            collection: try SessionProfileCollection(profiles: [profile])
        )
        let profileStore = SessionProfileStore(
            repository: repository,
            pathInspector: StubSessionProfilePathInspector()
        )
        await profileStore.load()
        let workspace = makeWorkspace()
        let coordinator = SessionProfileLaunchCoordinator(
            profileStore: profileStore,
            workspace: workspace
        )
        var launchResult: Bool?
        var didPublishRuntime = false
        let launchTask = Task { @MainActor in
            launchResult = await coordinator.launch(profile.id) {
                didPublishRuntime = true
            }
        }

        for _ in 0..<300 {
            if await repository.hasPendingSave() { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await repository.hasPendingSave())
        #expect(workspace.tabs.count == 1)
        #expect(didPublishRuntime)
        #expect(launchResult == nil)

        await repository.finishSave()
        await launchTask.value
        #expect(launchResult == true)
        await cleanup(workspace)
    }

    private func makeWorkspace() -> TerminalWorkspaceStore {
        TerminalWorkspaceStore(
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                let factory = SessionLaunchConfigurationFactory(
                    inheritedEnvironment: [:],
                    userHomeDirectory: "/Users/example",
                    loginShellResolver: {
                        ResolvedTerminalShell(
                            executablePath: "/bin/zsh",
                            argumentZero: "-zsh",
                            arguments: [],
                            workingDirectory: "/Users/example"
                        )
                    },
                    isUsableExecutableFile: { _ in true }
                )
                return TerminalSession(
                    sessionID: sessionID,
                    launchSpecification: specification,
                    configurationFactory: factory,
                    processLauncher: { _ in WorkspaceTestTerminalProcess() }
                )
            }
        )
    }

    private func makeProfile() -> SessionProfile {
        SessionProfile(
            id: SessionProfileID(),
            name: "Local",
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: .local(
                .init(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
    }

    private func cleanup(_ workspace: TerminalWorkspaceStore) async {
        workspace.cleanupAllSessions()
        for _ in 0..<300 {
            if workspace.sessions.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for launch-coordinator state")
    }
}

private actor SuspendingRecencyRepository: SessionProfileRepository {
    private let collection: SessionProfileCollection
    private var saveContinuation: CheckedContinuation<Void, Never>?

    init(collection: SessionProfileCollection) {
        self.collection = collection
    }

    func load() async throws -> SessionProfileLoadResult {
        .loaded(collection)
    }

    func save(_ collection: SessionProfileCollection) async throws {
        _ = collection
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
    }

    func hasPendingSave() -> Bool {
        saveContinuation != nil
    }

    func finishSave() {
        let continuation = saveContinuation
        saveContinuation = nil
        continuation?.resume()
    }
}
