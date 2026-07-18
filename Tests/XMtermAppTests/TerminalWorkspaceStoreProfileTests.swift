import Foundation
import Testing
import XMtermCore
import XMtermRemote
import XMtermTerminal
@testable import XMtermApp

@MainActor
@Suite("Profile-backed terminal workspace", .serialized)
struct TerminalWorkspaceStoreProfileTests {
    @Test("[SESS-007, TAB-001] local and SSH profiles create selected snapshot-backed tabs")
    func localAndSSHProfilesCreateExactSnapshots() async throws {
        let local = makeProfile(
            ordinal: 1,
            name: "Project Shell",
            configuration: .local(
                .init(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: "/Users/example/project"
                )
            )
        )
        let ssh = makeProfile(
            ordinal: 2,
            name: "Research Cluster",
            configuration: .ssh(.configAlias(alias: "research-cluster"))
        )
        let tabIDs = [uuid(101), uuid(102)]
        let sessionIDs = [terminalSessionID(201), terminalSessionID(202)]
        let store = makeStore(tabIDs: tabIDs, sessionIDs: sessionIDs)

        #expect(store.openProfile(local))
        #expect(store.openProfile(ssh))

        #expect(store.tabs.map(\.id) == tabIDs)
        #expect(store.tabs.map(\.title) == ["Project Shell", "Research Cluster"])
        #expect(store.tabs.map(\.sourceProfileID) == [local.id, ssh.id])
        #expect(store.tabs.map(\.launchSpecification.target) == [
            .local(
                .init(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: "/Users/example/project"
                )
            ),
            .ssh(.configAlias(alias: "research-cluster"))
        ])
        #expect(store.tabsState.selectedTabID == tabIDs[1])
        #expect(store.sessions[tabIDs[0]]?.sessionID == sessionIDs[0])
        #expect(store.sessions[tabIDs[1]]?.sessionID == sessionIDs[1])
        #expect(Set(store.sessions.values.map(\.sessionID)).count == 2)
        #expect(store.sessions.values.allSatisfy { session in
            !tabIDs.contains(session.sessionID.rawValue)
                && session.launchSpecification.sourceProfileID != SessionProfileID(
                    rawValue: session.sessionID.rawValue
                )
        })

        await cleanup(store)
    }

    @Test("[SESS-007] opening one profile twice creates independent tabs and sessions")
    func sameProfileCreatesIndependentRuntimeIdentities() async {
        let profile = makeProfile(
            ordinal: 1,
            name: "Relay Host",
            configuration: .ssh(
                .direct(
                    host: "140.109.226.155",
                    port: 54_426,
                    user: "allen921103",
                    identityFilePath: nil
                )
            )
        )
        let tabIDs = [uuid(111), uuid(112)]
        let sessionIDs = [terminalSessionID(211), terminalSessionID(212)]
        let store = makeStore(tabIDs: tabIDs, sessionIDs: sessionIDs)

        #expect(store.openProfile(profile))
        #expect(store.openProfile(profile))

        #expect(store.tabs.map(\.sourceProfileID) == [profile.id, profile.id])
        #expect(store.tabs.map(\.id) == tabIDs)
        #expect(store.sessions[tabIDs[0]]?.sessionID == sessionIDs[0])
        #expect(store.sessions[tabIDs[1]]?.sessionID == sessionIDs[1])
        #expect(store.sessions[tabIDs[0]] !== store.sessions[tabIDs[1]])

        await cleanup(store)
    }

    @Test("[SESS-007, SESS-010] editing and deleting a profile cannot affect an open tab")
    func editAndDeleteCannotAffectOpenTab() async throws {
        let profile = makeProfile(
            ordinal: 1,
            name: "Original Host",
            configuration: .ssh(
                .direct(
                    host: "original.example",
                    port: 22,
                    user: "researcher",
                    identityFilePath: nil
                )
            )
        )
        let tabID = uuid(121)
        let store = makeStore(
            tabIDs: [tabID],
            sessionIDs: [terminalSessionID(221)]
        )
        #expect(store.openProfile(profile))
        let originalTab = try #require(store.tabs.first)
        let collection = try SessionProfileCollection(profiles: [profile])
        let edited = try collection.editing(
            id: profile.id,
            with: aliasDraft(name: "Replacement", alias: "replacement"),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let deleted = try edited.deleting(id: profile.id)

        #expect(edited.profiles.first?.name == "Replacement")
        #expect(deleted.profiles.isEmpty)
        #expect(store.tabs.first == originalTab)
        #expect(store.tabs.first?.title == "Original Host")
        #expect(
            store.tabs.first?.launchSpecification.target == .ssh(
                .direct(
                    host: "original.example",
                    port: 22,
                    user: "researcher",
                    identityFilePath: nil
                )
            )
        )

        await cleanup(store)
    }

    @Test("[SESS-007, SESS-008] failed preflight creates no tab or session")
    func failedPreflightCreatesNothing() {
        var didCreateSession = false
        let store = TerminalWorkspaceStore(
            tabIDSource: { uuid(131) },
            sessionIDSource: { terminalSessionID(231) },
            launchPreflight: { _ in throw FixtureLaunchError.unavailable },
            sessionFactory: { _, _ in
                didCreateSession = true
                throw FixtureLaunchError.unavailable
            }
        )

        let didOpen = store.openProfile(
            makeProfile(ordinal: 1, name: "Unavailable")
        )

        #expect(!didOpen)
        #expect(!didCreateSession)
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
        #expect(store.tabsState.selectedTabID == nil)
        guard case .error(_, let message)? = store.activeAlert else {
            Issue.record("Expected a path-free workspace error")
            return
        }
        #expect(!message.contains("/"))
    }

    @Test("[SESS-008] OpenSSH preflight failure gives repair guidance without exposing paths")
    func sshPreflightFailureNamesOpenSSH() {
        let store = TerminalWorkspaceStore(
            tabIDSource: { uuid(132) },
            sessionIDSource: { terminalSessionID(232) },
            launchPreflight: { _ in
                throw SessionLaunchConfigurationError.sshExecutableUnavailable
            },
            sessionFactory: { sessionID, specification in
                makeSession(id: sessionID, specification: specification)
            }
        )
        let profile = makeProfile(
            ordinal: 1,
            name: "Unavailable SSH",
            configuration: .ssh(.configAlias(alias: "cluster"))
        )

        #expect(!store.openProfile(profile))
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
        guard case .error(_, let message)? = store.activeAlert else {
            Issue.record("Expected a workspace launch error")
            return
        }
        #expect(message.contains("OpenSSH"))
        #expect(!message.contains("/"))
    }

    @Test("[SESS-007] an injected tab/session identity collision fails before publication")
    func identityCollisionCreatesNothing() {
        let collision = uuid(141)
        let store = TerminalWorkspaceStore(
            tabIDSource: { collision },
            sessionIDSource: { TerminalSessionID(rawValue: collision) },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeSession(id: sessionID, specification: specification)
            },
            remoteWorkspaceFactory: { _, _ in
                RemoteWorkspace(composition: .unavailable())
            }
        )

        #expect(!store.openProfile(makeProfile(ordinal: 1, name: "Collision")))
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
    }

    @Test("[SESS-007] a factory cannot substitute a different runtime identity")
    func factoryIdentityMismatchCreatesNothing() {
        let requestedSessionID = terminalSessionID(241)
        let store = TerminalWorkspaceStore(
            tabIDSource: { uuid(142) },
            sessionIDSource: { requestedSessionID },
            launchPreflight: { _ in },
            sessionFactory: { _, specification in
                makeSession(
                    id: terminalSessionID(242),
                    specification: specification
                )
            }
        )

        #expect(!store.openProfile(makeProfile(ordinal: 1, name: "Mismatch")))
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
    }

    @Test("[SESS-007] a tab identity cannot equal its source profile identity")
    func profileAndTabIdentityCollisionCreatesNothing() {
        let profile = makeProfile(ordinal: 1, name: "Profile Tab Collision")
        let store = TerminalWorkspaceStore(
            tabIDSource: { profile.id.rawValue },
            sessionIDSource: { terminalSessionID(243) },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeSession(id: sessionID, specification: specification)
            }
        )

        #expect(!store.openProfile(profile))
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
    }

    @Test("[SESS-007] a runtime identity cannot equal its source profile identity")
    func profileAndSessionIdentityCollisionCreatesNothing() {
        let profile = makeProfile(ordinal: 1, name: "Profile Session Collision")
        let store = TerminalWorkspaceStore(
            tabIDSource: { uuid(143) },
            sessionIDSource: { TerminalSessionID(rawValue: profile.id.rawValue) },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeSession(id: sessionID, specification: specification)
            }
        )

        #expect(!store.openProfile(profile))
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
    }

    @Test("[TAB-003, SESS-007] closing one profile-backed tab preserves its sibling")
    func closeIsolationRemainsByTabIdentity() async throws {
        let local = makeProfile(ordinal: 1, name: "Local")
        let ssh = makeProfile(
            ordinal: 2,
            name: "SSH",
            configuration: .ssh(.configAlias(alias: "cluster"))
        )
        let localTabID = uuid(151)
        let sshTabID = uuid(152)
        let store = makeStore(
            tabIDs: [localTabID, sshTabID],
            sessionIDs: [terminalSessionID(251), terminalSessionID(252)]
        )
        #expect(store.openProfile(local))
        #expect(store.openProfile(ssh))
        try await waitUntil { store.tabs.allSatisfy { $0.lifecycle == .running } }

        store.requestClose(localTabID)

        try await waitUntil { !store.tabs.contains(where: { $0.id == localTabID }) }
        #expect(store.tabs.map(\.id) == [sshTabID])
        #expect(store.sessions[sshTabID]?.launchSpecification.sourceProfileID == ssh.id)

        await cleanup(store)
    }

    private func makeStore(
        tabIDs: [UUID],
        sessionIDs: [TerminalSessionID]
    ) -> TerminalWorkspaceStore {
        var remainingTabIDs = tabIDs
        var remainingSessionIDs = sessionIDs
        return TerminalWorkspaceStore(
            tabIDSource: { remainingTabIDs.removeFirst() },
            sessionIDSource: { remainingSessionIDs.removeFirst() },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeSession(id: sessionID, specification: specification)
            }
        )
    }

    private func makeSession(
        id: TerminalSessionID,
        specification: SessionLaunchSpecification
    ) -> TerminalSession {
        let process = WorkspaceTestTerminalProcess()
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
            sessionID: id,
            launchSpecification: specification,
            configurationFactory: factory,
            processLauncher: { _ in process }
        )
    }

    private func makeProfile(
        ordinal: Int,
        name: String,
        configuration: SessionProfileConfiguration = .local(
            .init(useLoginShell: true, shellPath: nil, workingDirectory: nil)
        )
    ) -> SessionProfile {
        SessionProfile(
            id: SessionProfileID(rawValue: uuid(ordinal)),
            name: name,
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: ordinal,
            configuration: configuration
        )
    }

    private func aliasDraft(name: String, alias: String) -> SessionProfileDraft {
        SessionProfileDraft(
            name: name,
            favorite: false,
            kind: .ssh,
            local: .init(mode: .loginShell, shellPath: "", workingDirectory: ""),
            ssh: .init(
                mode: .configAlias,
                host: "",
                port: "",
                user: "",
                sshConfigAlias: alias,
                identityFilePath: ""
            )
        )
    }

    private func terminalSessionID(_ value: Int) -> TerminalSessionID {
        TerminalSessionID(rawValue: uuid(value))
    }

    private func uuid(_ value: Int) -> UUID {
        let value = UInt32(value)
        return UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0,
                0, 0,
                0, 0,
                0, 0,
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            )
        )
    }

    private func cleanup(_ store: TerminalWorkspaceStore) async {
        store.cleanupAllSessions()
        try? await waitUntil { store.sessions.isEmpty }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for profile-backed workspace state")
    }
}

private enum FixtureLaunchError: Error {
    case unavailable
}
