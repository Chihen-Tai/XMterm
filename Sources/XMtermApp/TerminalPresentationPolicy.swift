import XMtermCore
import XMtermTerminal

struct TerminalClosePresentation: Equatable {
    let title: String
    let message: String
    let confirmButtonTitle: String
}

enum TerminalPresentationPolicy {
    static func statusSymbol(kind: TerminalTabKind, lifecycle: TerminalLifecycle) -> String {
        if kind == .relaySSH, lifecycle == .running {
            return "network"
        }
        return switch lifecycle {
        case .idle: "circle"
        case .starting: "ellipsis.circle"
        case .running: "checkmark.circle.fill"
        case .closing: "xmark.circle"
        case .exited: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    static func statusText(kind: TerminalTabKind, lifecycle: TerminalLifecycle) -> String {
        switch kind {
        case .local:
            return localStatusText(lifecycle)
        case .relaySSH:
            return sshStatusText(lifecycle)
        }
    }

    static func terminalAccessibilityLabel(kind: TerminalTabKind) -> String {
        switch kind {
        case .local:
            "Local terminal"
        case .relaySSH:
            "SSH terminal, Relay Host, allen921103 at 140.109.226.155, port 54426"
        }
    }

    static func terminalAccessibilityLabel(
        launchSpecification: SessionLaunchSpecification
    ) -> String {
        switch launchSpecification.target {
        case .local:
            "Local terminal, \(launchSpecification.initialTitle)"
        case let .ssh(.direct(host, port, user, _)):
            "SSH terminal, \(launchSpecification.initialTitle), \(user) at \(host), port \(port)"
        case let .ssh(.configAlias(alias)):
            "SSH terminal, \(launchSpecification.initialTitle), SSH config alias \(alias)"
        }
    }

    static func terminalAccessibilityHint(
        kind: TerminalTabKind,
        lifecycle: TerminalLifecycle
    ) -> String {
        let selectionHint = "Hold Option while dragging to force local selection when terminal mouse reporting is active."
        switch lifecycle {
        case .running:
            switch kind {
            case .local:
                return "Type commands in the local shell. \(selectionHint)"
            case .relaySSH:
                return "Type into the OpenSSH session. Authentication and host-key prompts appear in the terminal. \(selectionHint)"
            }
        case .idle:
            return "The terminal has not started. Input is disabled. Existing scrollback remains selectable and searchable. \(selectionHint)"
        case .starting:
            return "The terminal process is starting. Input is disabled until startup completes. Existing scrollback remains selectable and searchable. \(selectionHint)"
        case .closing:
            return "The terminal process is closing. Input is disabled. Existing scrollback remains selectable and searchable. \(selectionHint)"
        case .exited:
            return "The terminal process has exited. Input is disabled. Existing scrollback remains selectable and searchable. \(selectionHint)"
        case .failed:
            return "The terminal process failed. Input is disabled. Existing scrollback remains selectable and searchable. \(selectionHint)"
        }
    }

    static func closePresentation(for prompt: TerminalClosePrompt) -> TerminalClosePresentation {
        switch prompt.disposition {
        case .confirmSSHSession:
            return TerminalClosePresentation(
                title: "Close this SSH terminal?",
                message: "Closing the tab will terminate the SSH session and may stop a command currently running in this terminal.",
                confirmButtonTitle: "Close"
            )
        case .confirmForegroundJob:
            return TerminalClosePresentation(
                title: "Close \(prompt.title)?",
                message: "A foreground command is running in this terminal. Closing it will end the local shell and terminate that command.",
                confirmButtonTitle: "Close Terminal"
            )
        case .confirmUnknownForegroundActivity:
            return TerminalClosePresentation(
                title: "Close \(prompt.title)?",
                message: "XMterm could not determine the foreground command state. Closing this terminal will end the local shell and may terminate active work.",
                confirmButtonTitle: "Close Terminal"
            )
        case .closeImmediately:
            return TerminalClosePresentation(
                title: "Close \(prompt.title)?",
                message: "Closing this terminal will end its local shell.",
                confirmButtonTitle: "Close Terminal"
            )
        }
    }

    static func shutdownMessage(for prompt: TerminalWorkspaceShutdownPrompt) -> String {
        let localCount = prompt.foregroundJobCount + prompt.unknownForegroundActivityCount
        var descriptions: [String] = []
        if localCount > 0 {
            let noun = localCount == 1 ? "terminal" : "terminals"
            descriptions.append(
                "\(localCount) local \(noun) with active or unknown foreground work"
            )
        }
        if prompt.sshSessionCount > 0 {
            let noun = prompt.sshSessionCount == 1 ? "terminal" : "terminals"
            descriptions.append("\(prompt.sshSessionCount) active SSH \(noun)")
        }

        let affected = descriptions.count == 2
            ? descriptions.joined(separator: " and ")
            : descriptions.first ?? "the active terminals"
        let uncertainty = prompt.unknownForegroundActivityCount == 0
            ? ""
            : " XMterm could not determine foreground activity for \(prompt.unknownForegroundActivityCount) local terminal\(prompt.unknownForegroundActivityCount == 1 ? "" : "s")."
        let sshConsequence: String
        if prompt.sshSessionCount == 1 {
            sshConsequence = " Closing this SSH terminal will terminate its SSH session and may stop a command currently running in it."
        } else if prompt.sshSessionCount > 1 {
            sshConsequence = " Closing these SSH terminals will terminate their SSH sessions and may stop commands currently running in them."
        } else {
            sshConsequence = ""
        }
        return "This will close \(affected).\(uncertainty)\(sshConsequence)"
    }

    private static func localStatusText(_ lifecycle: TerminalLifecycle) -> String {
        switch lifecycle {
        case .idle: "Terminal idle"
        case .starting: "Starting local shell"
        case .running: "Local shell running"
        case .closing: "Closing local shell"
        case let .exited(status): status.summary
        case let .failed(failure): failure.userFacingMessage
        }
    }

    private static func sshStatusText(_ lifecycle: TerminalLifecycle) -> String {
        switch lifecycle {
        case .idle:
            "SSH terminal idle"
        case .starting:
            "Starting SSH"
        case .running:
            "SSH session active"
        case .closing:
            "Closing SSH session"
        case .exited(.exited(code: 0)):
            "SSH process exited normally"
        case let .exited(.exited(code)):
            "SSH process exited with status \(code)"
        case let .exited(.signaled(signal)):
            "SSH process terminated by signal \(signal)"
        case let .failed(failure):
            sshFailureText(failure)
        }
    }

    private static func sshFailureText(_ failure: TerminalFailure) -> String {
        switch failure {
        case .ptyCreation:
            "XMterm could not create the SSH terminal"
        case .launch:
            "SSH failed to start"
        case .read:
            "XMterm lost SSH terminal output"
        case .write:
            "XMterm could not send input to SSH"
        case .resize:
            "XMterm could not resize the SSH terminal"
        }
    }
}
