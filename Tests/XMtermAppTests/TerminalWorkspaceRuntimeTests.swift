import Foundation
import Testing
import XMtermCore
import XMtermRemote
import XMtermTerminal
@testable import XMtermApp

@Suite("Session-centric workspace registry", .serialized)
@MainActor
struct TerminalWorkspaceRuntimeTests {
    @Test("[FILE-WORKSPACE-001, SESS-011] local launch never constructs a remote workspace")
    func localLaunchExcludesWorkspaceFactory() async throws {
        var workspaceFactoryCalls = 0
        let store = makeStore {
            workspaceFactoryCalls += 1
            return RemoteWorkspace(provider: RuntimeSessionTestRemoteFileProvider())
        }

        #expect(store.openProfile(makeProfile(kind: .local)))
        let tabID = try #require(store.tabsState.selectedTabID)
        let runtime = try #require(store.runtimes[tabID])
        #expect(workspaceFactoryCalls == 0)
        #expect(runtime.remoteWorkspace == nil)
        #expect(store.selectedRuntime === runtime)
        #expect(store.selectedSession === runtime.terminal)
        #expect(store.sessions[tabID] === runtime.terminal)

        store.cleanupAllSessions()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test("[FILE-WORKSPACE-001, SESS-007] repeated SSH launches own fresh workspaces")
    func repeatedSSHLaunchesOwnFreshWorkspaces() async throws {
        var createdWorkspaces: [RemoteWorkspace] = []
        let store = makeStore {
            let workspace = RemoteWorkspace(provider: RuntimeSessionTestRemoteFileProvider())
            createdWorkspaces.append(workspace)
            return workspace
        }
        let profile = makeProfile(kind: .relaySSH)

        #expect(store.openProfile(profile))
        #expect(store.openProfile(profile))

        #expect(store.runtimes.count == 2)
        #expect(createdWorkspaces.count == 2)
        #expect(createdWorkspaces[0] !== createdWorkspaces[1])
        let runtimes = store.tabs.compactMap { store.runtimes[$0.id] }
        #expect(runtimes.count == 2)
        #expect(runtimes[0] !== runtimes[1])
        #expect(runtimes[0].terminal !== runtimes[1].terminal)
        #expect(runtimes[0].remoteWorkspace !== runtimes[1].remoteWorkspace)
        #expect(runtimes.allSatisfy { $0.launchSpecification == runtimes[0].launchSpecification })

        store.cleanupAllSessions()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test("[FILE-WORKSPACE-001, SESS-011] a retained workspace identity cannot be reused")
    func reusedWorkspaceIdentityIsRejectedWithoutClosingOwner() async throws {
        let provider = RuntimeSessionTestRemoteFileProvider()
        let sharedWorkspace = RemoteWorkspace(provider: provider)
        var workspaceFactoryCalls = 0
        let store = makeStore {
            workspaceFactoryCalls += 1
            return sharedWorkspace
        }
        let profile = makeProfile(kind: .relaySSH)

        #expect(store.openProfile(profile))
        let firstTabID = try #require(store.tabsState.selectedTabID)
        let firstRuntime = try #require(store.runtimes[firstTabID])
        try await eventually { sharedWorkspace.availability == .available }

        #expect(!store.openProfile(profile))
        #expect(workspaceFactoryCalls == 2)
        #expect(store.tabs.count == 1)
        #expect(store.runtimes.count == 1)
        #expect(store.runtimes[firstTabID] === firstRuntime)
        #expect(firstRuntime.remoteWorkspace === sharedWorkspace)
        #expect(await provider.snapshot().closeCount == 0)

        store.cleanupAllSessions()
        try await eventually { store.runtimes.isEmpty }
        #expect(await provider.snapshot().closeCount == 1)
    }

    @Test("[SESS-006, SESS-011] close hides tab but retains runtime until both capabilities settle")
    func closeRetainsRuntimeUntilAggregateSettles() async throws {
        let terminalProcess = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        let provider = RuntimeSessionTestRemoteFileProvider(suspendsClose: true)
        let store = makeStore(
            terminalProcess: terminalProcess,
            workspaceFactory: { RemoteWorkspace(provider: provider) }
        )
        #expect(store.openProfile(makeProfile(kind: .relaySSH)))
        let tabID = try #require(store.tabsState.selectedTabID)
        let runtime = try #require(store.runtimes[tabID])
        try await eventually {
            runtime.terminal.lifecycle == .running
                && runtime.remoteWorkspace?.availability == .available
        }

        store.requestClose(tabID)
        try await eventually {
            let providerSnapshot = await provider.snapshot()
            let terminalCloseCount = await terminalProcess.recordedCloseCount()
            return store.tabs.isEmpty
                && providerSnapshot.closeCount == 1
                && terminalCloseCount == 1
        }
        #expect(store.runtimes[tabID] === runtime)

        await terminalProcess.releaseClose()
        await Task.yield()
        #expect(store.runtimes[tabID] === runtime)

        await provider.releaseClose()
        try await eventually { store.runtimes[tabID] == nil }
        #expect(store.sessions[tabID] == nil)
    }

    @Test("[SESS-011] stale capability callbacks cannot target a reused tab identity")
    func staleCallbacksUseExactRuntimeIdentity() async throws {
        let reusedTabID = uuid(301)
        var nextSessionIdentity = 401
        let process = RuntimeSessionTestTerminalProcess()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { reusedTabID },
            sessionIDSource: {
                defer { nextSessionIdentity += 1 }
                return TerminalSessionID(rawValue: uuid(nextSessionIdentity))
            },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process
                )
            }
        )

        #expect(store.openProfile(makeProfile(kind: .local)))
        let first = try #require(store.runtimes[reusedTabID])
        try await eventually { first.terminal.lifecycle == .running }
        store.requestClose(reusedTabID)
        try await eventually { store.runtimes[reusedTabID] == nil }

        let replacementProfile = SessionProfile(
            id: SessionProfileID(rawValue: uuid(302)),
            name: "Replacement",
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2),
            lastOpenedAt: nil,
            sortOrder: 1,
            configuration: .local(
                .init(useLoginShell: true, shellPath: nil, workingDirectory: nil)
            )
        )
        #expect(store.openProfile(replacementProfile))
        #expect(store.tabs.first?.title == "Replacement")

        first.terminal.terminalView.onTitleChanged?("stale title")

        #expect(store.tabs.first?.title == "Replacement")
        store.cleanupAllSessions()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test("[SESS-007, SESS-011] terminal contract is validated before workspace construction")
    func terminalContractPrecedesWorkspaceFactory() {
        var workspaceFactoryCalls = 0
        let requestedSessionID = TerminalSessionID(rawValue: uuid(501))
        let process = RuntimeSessionTestTerminalProcess()
        let store = TerminalWorkspaceStore(
            tabIDSource: { uuid(502) },
            sessionIDSource: { requestedSessionID },
            launchPreflight: { _ in },
            sessionFactory: { _, specification in
                makeTerminal(
                    sessionID: TerminalSessionID(rawValue: uuid(503)),
                    specification: specification,
                    process: process
                )
            },
            remoteWorkspaceFactory: { _, _ in
                workspaceFactoryCalls += 1
                return RemoteWorkspace(provider: RuntimeSessionTestRemoteFileProvider())
            }
        )

        #expect(!store.openProfile(makeProfile(kind: .relaySSH)))
        #expect(workspaceFactoryCalls == 0)
        #expect(store.tabs.isEmpty)
        #expect(store.runtimes.isEmpty)
    }

    @Test("[SESS-007, SESS-011] terminal lifecycle is validated before workspace construction")
    func terminalLifecyclePrecedesWorkspaceFactory() {
        var workspaceFactoryCalls = 0
        let requestedSessionID = TerminalSessionID(rawValue: uuid(511))
        let process = RuntimeSessionTestTerminalProcess()
        let store = TerminalWorkspaceStore(
            tabIDSource: { uuid(512) },
            sessionIDSource: { requestedSessionID },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                let terminal = makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process
                )
                terminal.requestClose()
                return terminal
            },
            remoteWorkspaceFactory: { _, _ in
                workspaceFactoryCalls += 1
                return RemoteWorkspace(provider: RuntimeSessionTestRemoteFileProvider())
            }
        )

        #expect(!store.openProfile(makeProfile(kind: .relaySSH)))
        #expect(workspaceFactoryCalls == 0)
        #expect(store.tabs.isEmpty)
        #expect(store.runtimes.isEmpty)
    }

    @Test("[SESS-006, SESS-011] a hidden closing runtime blocks tab identity reuse")
    func hiddenRuntimeBlocksIdentityReuse() async throws {
        let reusedTabID = uuid(601)
        var nextSessionIdentity = 701
        var workspaceFactoryCalls = 0
        let process = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        let provider = RuntimeSessionTestRemoteFileProvider(suspendsClose: true)
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { reusedTabID },
            sessionIDSource: {
                defer { nextSessionIdentity += 1 }
                return TerminalSessionID(rawValue: uuid(nextSessionIdentity))
            },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process
                )
            },
            remoteWorkspaceFactory: { _, _ in
                workspaceFactoryCalls += 1
                return RemoteWorkspace(provider: provider)
            }
        )

        #expect(store.openProfile(makeProfile(kind: .relaySSH)))
        let retainedRuntime = try #require(store.runtimes[reusedTabID])
        try await eventually { retainedRuntime.terminal.lifecycle == .running }
        store.requestClose(reusedTabID)
        try await eventually {
            let providerSnapshot = await provider.snapshot()
            let terminalCloseCount = await process.recordedCloseCount()
            return store.tabs.isEmpty
                && providerSnapshot.closeCount == 1
                && terminalCloseCount == 1
        }

        #expect(!store.openProfile(makeProfile(kind: .local)))
        #expect(store.tabs.isEmpty)
        #expect(store.runtimes[reusedTabID] === retainedRuntime)
        #expect(workspaceFactoryCalls == 1)

        await process.releaseClose()
        await provider.releaseClose()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test("[SESS-006, SESS-007] a hidden tab identity cannot become a session identity")
    func hiddenTabIdentityBlocksSessionIdentityReuse() async throws {
        let firstTabID = uuid(611)
        let secondTabID = uuid(612)
        var remainingTabIDs = [firstTabID, secondTabID]
        var remainingSessionIDs = [
            TerminalSessionID(rawValue: uuid(711)),
            TerminalSessionID(rawValue: firstTabID),
        ]
        let process = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        let provider = RuntimeSessionTestRemoteFileProvider(suspendsClose: true)
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { remainingTabIDs.removeFirst() },
            sessionIDSource: { remainingSessionIDs.removeFirst() },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process
                )
            },
            remoteWorkspaceFactory: { _, _ in
                RemoteWorkspace(provider: provider)
            }
        )

        #expect(store.openProfile(makeProfile(kind: .relaySSH)))
        let retainedRuntime = try #require(store.runtimes[firstTabID])
        try await eventually { retainedRuntime.terminal.lifecycle == .running }
        store.requestClose(firstTabID)
        try await eventually {
            let providerSnapshot = await provider.snapshot()
            let terminalCloseCount = await process.recordedCloseCount()
            return store.tabs.isEmpty
                && providerSnapshot.closeCount == 1
                && terminalCloseCount == 1
        }

        #expect(!store.openProfile(makeProfile(kind: .local)))
        #expect(store.tabs.isEmpty)
        #expect(store.runtimes[firstTabID] === retainedRuntime)

        await process.releaseClose()
        await provider.releaseClose()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test(
        "[SESS-007] a retained profile identity cannot become a tab or session identity",
        arguments: [true, false]
    )
    func retainedProfileIdentityBlocksRuntimeIdentityReuse(collisionIsTabID: Bool) async throws {
        let profileID = SessionProfileID(rawValue: uuid(621))
        let profileUUID = profileID.rawValue
        let firstTabID = uuid(622)
        let secondTabID = collisionIsTabID ? profileUUID : uuid(623)
        let firstSessionID = TerminalSessionID(rawValue: uuid(721))
        let secondSessionID = TerminalSessionID(
            rawValue: collisionIsTabID ? uuid(722) : profileUUID
        )
        var remainingTabIDs = [firstTabID, secondTabID]
        var remainingSessionIDs = [firstSessionID, secondSessionID]
        let process = RuntimeSessionTestTerminalProcess()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { remainingTabIDs.removeFirst() },
            sessionIDSource: { remainingSessionIDs.removeFirst() },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process
                )
            }
        )
        let retainedProfile = makeProfile(
            kind: .local,
            id: profileID,
            name: "Retained Profile"
        )

        #expect(store.openProfile(retainedProfile))
        let retainedRuntime = try #require(store.runtimes[firstTabID])
        #expect(!store.openProfile(makeProfile(kind: .local)))
        #expect(store.tabs.count == 1)
        #expect(store.runtimes.count == 1)
        #expect(store.runtimes[firstTabID] === retainedRuntime)

        store.cleanupAllSessions()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test(
        "[SESS-007] a new profile identity cannot reuse a retained tab or session identity",
        arguments: [true, false]
    )
    func newProfileIdentityBlocksRetainedRuntimeIdentityReuse(collisionIsTabID: Bool) async throws {
        let firstTabID = uuid(631)
        let firstSessionID = TerminalSessionID(rawValue: uuid(731))
        var remainingTabIDs = [firstTabID, uuid(632)]
        var remainingSessionIDs = [firstSessionID, TerminalSessionID(rawValue: uuid(732))]
        let process = RuntimeSessionTestTerminalProcess()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { remainingTabIDs.removeFirst() },
            sessionIDSource: { remainingSessionIDs.removeFirst() },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process
                )
            }
        )

        #expect(store.openProfile(makeProfile(kind: .local)))
        let retainedRuntime = try #require(store.runtimes[firstTabID])
        let collidingProfileID = SessionProfileID(
            rawValue: collisionIsTabID ? firstTabID : firstSessionID.rawValue
        )
        let collidingProfile = makeProfile(
            kind: .local,
            id: collidingProfileID,
            name: "Colliding Profile"
        )

        #expect(!store.openProfile(collidingProfile))
        #expect(store.tabs.count == 1)
        #expect(store.runtimes.count == 1)
        #expect(store.runtimes[firstTabID] === retainedRuntime)

        store.cleanupAllSessions()
        try await eventually { store.runtimes.isEmpty }
    }

    @Test("[MAC-002, SESS-011] shutdown completion observes all visible tabs closed")
    func synchronousShutdownSettlementClosesTabsBeforeCompletion() async throws {
        let tabID = uuid(641)
        let process = RuntimeSessionTestTerminalProcess()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { tabID },
            sessionIDSource: { TerminalSessionID(rawValue: uuid(741)) },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: process,
                    failsLaunch: true
                )
            }
        )

        #expect(store.openProfile(makeProfile(kind: .local)))
        let runtime = try #require(store.runtimes[tabID])
        try await eventually {
            if case .failed = runtime.terminal.lifecycle { return true }
            return false
        }
        #expect(store.tabs.count == 1)
        #expect(store.runtimes.count == 1)
        var shutdownResult: Bool?
        var tabCountAtCompletion: Int?
        var runtimeCountAtCompletion: Int?

        store.requestWorkspaceShutdown(.window) { result in
            shutdownResult = result
            tabCountAtCompletion = store.tabs.count
            runtimeCountAtCompletion = store.runtimes.count
        }

        try await eventually { shutdownResult != nil }
        #expect(shutdownResult == true)
        #expect(tabCountAtCompletion == 0)
        #expect(runtimeCountAtCompletion == 0)
        #expect(store.tabs.isEmpty)
        #expect(store.runtimes.isEmpty)
    }

    @Test("[MAC-002, SESS-011] full shutdown waits for every runtime capability")
    func fullShutdownWaitsForAllCapabilities() async throws {
        let tabIDs = [uuid(801), uuid(802), uuid(803)]
        var remainingTabIDs = tabIDs
        var nextSessionIdentity = 901
        let localProcess = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        let firstSSHProcess = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        let secondSSHProcess = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        var terminalProcesses = [localProcess, firstSSHProcess, secondSSHProcess]
        let firstProvider = RuntimeSessionTestRemoteFileProvider(suspendsClose: true)
        let secondProvider = RuntimeSessionTestRemoteFileProvider(suspendsClose: true)
        var providers = [firstProvider, secondProvider]
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: { remainingTabIDs.removeFirst() },
            sessionIDSource: {
                defer { nextSessionIdentity += 1 }
                return TerminalSessionID(rawValue: uuid(nextSessionIdentity))
            },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: terminalProcesses.removeFirst()
                )
            },
            remoteWorkspaceFactory: { _, _ in
                RemoteWorkspace(provider: providers.removeFirst())
            }
        )

        #expect(store.openProfile(makeProfile(kind: .local)))
        #expect(store.openProfile(makeProfile(kind: .relaySSH)))
        let secondSSHProfile = SessionProfile(
            id: SessionProfileID(rawValue: uuid(804)),
            name: "SSH Two",
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 3),
            lastOpenedAt: nil,
            sortOrder: 2,
            configuration: .ssh(.configAlias(alias: "relay-two"))
        )
        #expect(store.openProfile(secondSSHProfile))
        try await eventually {
            store.runtimes.count == 3
                && store.runtimes.values.allSatisfy { $0.terminal.lifecycle == .running }
                && store.runtimes.values.compactMap(\.remoteWorkspace).allSatisfy {
                    $0.availability == .available
                }
        }
        let capturedRuntimes = store.runtimes
        var shutdownResults: [Bool] = []

        store.requestWorkspaceShutdown(.window) { shutdownResults.append($0) }
        try await eventually {
            let localCloseCount = await localProcess.recordedCloseCount()
            let firstCloseCount = await firstSSHProcess.recordedCloseCount()
            let secondCloseCount = await secondSSHProcess.recordedCloseCount()
            let firstProviderSnapshot = await firstProvider.snapshot()
            let secondProviderSnapshot = await secondProvider.snapshot()
            return store.tabs.isEmpty
                && localCloseCount == 1
                && firstCloseCount == 1
                && secondCloseCount == 1
                && firstProviderSnapshot.closeCount == 1
                && secondProviderSnapshot.closeCount == 1
        }
        #expect(store.runtimes.count == 3)
        #expect(shutdownResults.isEmpty)

        await localProcess.releaseClose()
        try await eventually { store.runtimes[tabIDs[0]] == nil }
        #expect(store.runtimes[tabIDs[1]] === capturedRuntimes[tabIDs[1]])
        #expect(store.runtimes[tabIDs[2]] === capturedRuntimes[tabIDs[2]])
        #expect(shutdownResults.isEmpty)

        await firstSSHProcess.releaseClose()
        await Task.yield()
        #expect(store.runtimes[tabIDs[1]] === capturedRuntimes[tabIDs[1]])
        await firstProvider.releaseClose()
        try await eventually { store.runtimes[tabIDs[1]] == nil }
        #expect(store.runtimes[tabIDs[2]] === capturedRuntimes[tabIDs[2]])
        #expect(shutdownResults.isEmpty)

        await secondProvider.releaseClose()
        await Task.yield()
        #expect(store.runtimes[tabIDs[2]] === capturedRuntimes[tabIDs[2]])
        #expect(shutdownResults.isEmpty)
        await secondSSHProcess.releaseClose()
        try await eventually { store.runtimes.isEmpty && shutdownResults == [true] }
        #expect(store.sessions.isEmpty)
    }

    private func makeStore(
        terminalProcess: RuntimeSessionTestTerminalProcess = RuntimeSessionTestTerminalProcess(),
        workspaceFactory: @escaping @MainActor () -> RemoteWorkspace
    ) -> TerminalWorkspaceStore {
        var nextIdentity = 1
        return TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately },
            tabIDSource: {
                defer { nextIdentity += 1 }
                return uuid(nextIdentity)
            },
            sessionIDSource: {
                defer { nextIdentity += 1 }
                return TerminalSessionID(rawValue: uuid(nextIdentity))
            },
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                makeTerminal(
                    sessionID: sessionID,
                    specification: specification,
                    process: terminalProcess
                )
            },
            remoteWorkspaceFactory: { _, _ in workspaceFactory() }
        )
    }

    private func makeTerminal(
        sessionID: TerminalSessionID,
        specification: SessionLaunchSpecification,
        process: RuntimeSessionTestTerminalProcess,
        failsLaunch: Bool = false
    ) -> TerminalSession {
        TerminalSession(
            sessionID: sessionID,
            launchSpecification: specification,
            configurationFactory: SessionLaunchConfigurationFactory(
                inheritedEnvironment: [:],
                userHomeDirectory: "/fixture/home",
                loginShellResolver: {
                    ResolvedTerminalShell(
                        executablePath: "/bin/zsh",
                        argumentZero: "-zsh",
                        arguments: [],
                        workingDirectory: "/fixture/home"
                    )
                },
                isUsableExecutableFile: { _ in true }
            ),
            processLauncher: { _ in
                if failsLaunch {
                    throw TerminalWorkspaceRuntimeTestError.launchFailed
                }
                return process
            }
        )
    }

    private func makeProfile(
        kind: TerminalTabKind,
        id: SessionProfileID? = nil,
        name: String? = nil
    ) -> SessionProfile {
        SessionProfile(
            id: id ?? SessionProfileID(rawValue: uuid(kind == .local ? 201 : 202)),
            name: name ?? (kind == .local ? "Local" : "SSH"),
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: kind == .local
                ? .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
                : .ssh(.configAlias(alias: "relay"))
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic store state")
    }

    private func uuid(_ value: Int) -> UUID {
        let value = UInt32(value)
        return UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0,
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
                0, 1
            )
        )
    }
}

private enum TerminalWorkspaceRuntimeTestError: Error {
    case launchFailed
}
