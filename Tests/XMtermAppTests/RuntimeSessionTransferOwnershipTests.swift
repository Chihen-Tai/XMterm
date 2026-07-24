import Foundation
import Testing
import XMtermCore
import XMtermRemote
import XMtermTerminal

@testable import XMtermApp

@Suite("Runtime session transfer ownership")
@MainActor
struct RuntimeSessionTransferOwnershipTests {
    @Test("[FILE-WORKSPACE-001, SESS-011] local runtime has no remote workspace or transfer coordinator")
    func localRuntimeOwnsNoRemoteTransferCapability() throws {
        let sessionID = TerminalSessionID()
        let specification = SessionLaunchSpecification.legacy(kind: .local, title: "Local")
        let runtime = try RuntimeSession(
            id: sessionID,
            launchSpecification: specification,
            terminal: makeTerminal(sessionID: sessionID, specification: specification),
            remoteWorkspace: nil
        )

        #expect(runtime.remoteWorkspace == nil)
    }

    @Test("[SESS-011] SSH runtime transfer owner uses launching terminal session identity")
    func sshRuntimeOwnsWorkspaceCoordinatorForItsSessionIdentity() throws {
        let sessionID = TerminalSessionID()
        let specification = SessionLaunchSpecification.legacy(kind: .relaySSH, title: "SSH")
        let workspaceID = RemoteWorkspaceID()
        let owner = RemoteTransferOwnerIdentity(
            runtimeID: sessionID,
            workspaceID: workspaceID
        )
        let workspace = RemoteWorkspace(
            id: workspaceID,
            composition: .unavailable(owner: owner)
        )
        let runtime = try RuntimeSession(
            id: sessionID,
            launchSpecification: specification,
            terminal: makeTerminal(sessionID: sessionID, specification: specification),
            remoteWorkspace: workspace
        )

        #expect(runtime.remoteWorkspace === workspace)
        #expect(workspace.transferOwner.runtimeID == sessionID)
        #expect(workspace.transferOwner.workspaceID == workspace.id)
        #expect(workspace.transfers.owner == workspace.transferOwner)
    }

    @Test("[SESS-011] SSH runtime rejects a workspace owned by another terminal session")
    func sshRuntimeRejectsMismatchedTransferOwner() {
        let sessionID = TerminalSessionID()
        let specification = SessionLaunchSpecification.legacy(kind: .relaySSH, title: "SSH")
        let workspaceID = RemoteWorkspaceID()
        let workspace = RemoteWorkspace(
            id: workspaceID,
            composition: .unavailable(
                owner: RemoteTransferOwnerIdentity(
                    runtimeID: TerminalSessionID(),
                    workspaceID: workspaceID
                )
            )
        )

        #expect(throws: RuntimeSessionCompositionError.workspaceOwnerMismatch) {
            try RuntimeSession(
                id: sessionID,
                launchSpecification: specification,
                terminal: makeTerminal(sessionID: sessionID, specification: specification),
                remoteWorkspace: workspace
            )
        }
    }

    private func makeTerminal(
        sessionID: TerminalSessionID,
        specification: SessionLaunchSpecification
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
            processLauncher: { _ in RuntimeSessionTestTerminalProcess() }
        )
    }
}
