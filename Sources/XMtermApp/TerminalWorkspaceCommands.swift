import Observation
import SwiftUI

/// App-scoped command route that weakly follows the single live window workspace.
///
/// The router survives window recreation, but never owns a workspace or reuses one after its
/// terminal sessions have been shut down.
@MainActor
@Observable
final class TerminalCommandRouter {
    @ObservationIgnored private weak var workspace: TerminalWorkspaceStore?
    @ObservationIgnored private var closeWindowAction: (@MainActor () -> Void)?
    @ObservationIgnored private var newTerminalAction: (@MainActor () -> Void)?
    @ObservationIgnored private var chooseSessionAction: (@MainActor () -> Void)?
    @ObservationIgnored private var manageSessionsAction: (@MainActor () -> Void)?
    private var bindingGeneration = 0

    var canCreateTerminal: Bool {
        _ = bindingGeneration
        return workspace?.canCreateTerminal ?? false
    }

    var canCloseTerminal: Bool {
        _ = bindingGeneration
        return workspace?.selectedSession != nil && workspace?.activeAlert == nil
    }

    var canFindInTerminal: Bool {
        _ = bindingGeneration
        return workspace?.selectedSession != nil
    }

    var canCloseWindow: Bool {
        _ = bindingGeneration
        return workspace != nil && closeWindowAction != nil
    }

    var canChooseSession: Bool {
        _ = bindingGeneration
        return canCreateTerminal && chooseSessionAction != nil
    }

    var canManageSessions: Bool {
        _ = bindingGeneration
        return workspace != nil && manageSessionsAction != nil
    }

    func attach(
        workspace: TerminalWorkspaceStore,
        closeWindow: @escaping @MainActor () -> Void,
        newTerminal: (@MainActor () -> Void)? = nil,
        chooseSession: (@MainActor () -> Void)? = nil,
        manageSessions: (@MainActor () -> Void)? = nil
    ) {
        self.workspace = workspace
        closeWindowAction = closeWindow
        newTerminalAction = newTerminal ?? { [weak workspace] in
            workspace?.createTerminal()
        }
        chooseSessionAction = chooseSession ?? { [weak workspace] in
            workspace?.createSSHTerminal()
        }
        manageSessionsAction = manageSessions
        bindingGeneration &+= 1
    }

    func detach(from workspace: TerminalWorkspaceStore) {
        guard self.workspace === workspace else { return }
        self.workspace = nil
        closeWindowAction = nil
        newTerminalAction = nil
        chooseSessionAction = nil
        manageSessionsAction = nil
        bindingGeneration &+= 1
    }

    func newTerminal() {
        guard canCreateTerminal else { return }
        newTerminalAction?()
    }

    func newSSHTerminal() {
        chooseSession()
    }

    func chooseSession() {
        guard canChooseSession else { return }
        chooseSessionAction?()
    }

    func manageSessions() {
        guard canManageSessions else { return }
        manageSessionsAction?()
    }

    func closeTerminal() {
        guard canCloseTerminal else { return }
        workspace?.requestCloseSelected()
    }

    func closeWindow() {
        guard canCloseWindow else { return }
        closeWindowAction?()
    }

    func findInTerminal() {
        guard canFindInTerminal else { return }
        workspace?.findInSelectedTerminal()
    }
}

struct TerminalCommands: Commands {
    let router: TerminalCommandRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Terminal") {
                router.newTerminal()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!router.canCreateTerminal)

            Button("Choose Session…") {
                router.chooseSession()
            }
            .disabled(!router.canChooseSession)

            Button("Manage Sessions…") {
                router.manageSessions()
            }
            .disabled(!router.canManageSessions)
        }

        CommandMenu("Terminal") {
            Button("Find in Terminal…") {
                router.findInTerminal()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!router.canFindInTerminal)

            Divider()

            Button("Close Terminal") {
                router.closeTerminal()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!router.canCloseTerminal)

            Button("Close Window") {
                router.closeWindow()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(!router.canCloseWindow)
        }
    }
}
