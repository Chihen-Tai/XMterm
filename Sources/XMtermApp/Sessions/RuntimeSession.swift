import XMtermCore
import XMtermRemote
import XMtermTerminal

enum RuntimeSessionCompositionError: Error, Equatable {
    case terminalContractViolation
    case workspaceEligibilityMismatch
}

typealias RemoteFileProviderFactory = @MainActor (
    TerminalSessionID,
    SessionLaunchSpecification
) -> any RemoteFileProvider

typealias RemoteWorkspaceFactory = @MainActor (
    TerminalSessionID,
    SessionLaunchSpecification
) -> RemoteWorkspace

/// Owns the independently failing capabilities for one immutable launch snapshot.
@MainActor
final class RuntimeSession {
    let id: TerminalSessionID
    let launchSpecification: SessionLaunchSpecification
    let terminal: TerminalSession
    let remoteWorkspace: RemoteWorkspace?

    var onCleanupFinished: (() -> Void)?
    var onCleanupFailed: ((String) -> Void)?

    private var didStart = false
    private var didRequestClose = false
    private var terminalDidSettle = false
    private var workspaceDidSettle: Bool
    private var didPublishCleanup = false
    private var workspaceCloseTask: Task<Void, Never>?

    init(
        id: TerminalSessionID,
        launchSpecification: SessionLaunchSpecification,
        terminal: TerminalSession,
        remoteWorkspace: RemoteWorkspace?
    ) throws {
        guard terminal.sessionID == id,
              terminal.launchSpecification == launchSpecification,
              terminal.lifecycle == .idle else {
            throw RuntimeSessionCompositionError.terminalContractViolation
        }
        switch (launchSpecification.target, remoteWorkspace) {
        case (.local, nil), (.ssh, .some):
            break
        case (.local, .some), (.ssh, nil):
            throw RuntimeSessionCompositionError.workspaceEligibilityMismatch
        }

        self.id = id
        self.launchSpecification = launchSpecification
        self.terminal = terminal
        self.remoteWorkspace = remoteWorkspace
        workspaceDidSettle = remoteWorkspace == nil

        terminal.onCleanupFinished = { [weak self] in
            self?.terminalCleanupFinished()
        }
        terminal.onCleanupFailed = { [weak self] message in
            self?.onCleanupFailed?(message)
        }
    }

    func start() {
        guard !didStart, !didRequestClose else { return }
        didStart = true
        terminal.start()
        remoteWorkspace?.start()
    }

    func requestClose() {
        guard !didRequestClose else { return }
        didRequestClose = true

        if let remoteWorkspace {
            workspaceCloseTask = Task { @MainActor [weak self, remoteWorkspace] in
                await remoteWorkspace.close()
                self?.workspaceCleanupFinished()
            }
        }
        terminal.requestClose()
        publishCleanupIfSettled()
    }

    private func terminalCleanupFinished() {
        terminalDidSettle = true
        publishCleanupIfSettled()
    }

    private func workspaceCleanupFinished() {
        workspaceDidSettle = true
        workspaceCloseTask = nil
        publishCleanupIfSettled()
    }

    private func publishCleanupIfSettled() {
        guard didRequestClose,
              terminalDidSettle,
              workspaceDidSettle,
              !didPublishCleanup else { return }
        didPublishCleanup = true
        onCleanupFinished?()
    }
}
