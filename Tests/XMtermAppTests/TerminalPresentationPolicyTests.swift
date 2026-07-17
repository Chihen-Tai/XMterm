import Testing
import XMtermCore
import XMtermTerminal
@testable import XMtermApp

@Suite("Terminal presentation policy")
struct TerminalPresentationPolicyTests {
    @Test("[TAB-005, TERM-STATE-001] relay status copy reports only observable process state")
    func relayStatusCopyIsNeutralAndHonest() {
        #expect(
            TerminalPresentationPolicy.statusText(kind: .relaySSH, lifecycle: .idle)
                == "SSH terminal idle"
        )
        #expect(
            TerminalPresentationPolicy.statusText(kind: .relaySSH, lifecycle: .starting)
                == "Starting SSH"
        )
        let running = TerminalPresentationPolicy.statusText(
            kind: .relaySSH,
            lifecycle: .running
        )
        #expect(running == "SSH session active")
        #expect(!running.localizedCaseInsensitiveContains("connected"))
        #expect(
            TerminalPresentationPolicy.statusSymbol(kind: .relaySSH, lifecycle: .running)
                == "network"
        )
        #expect(
            TerminalPresentationPolicy.statusText(
                kind: .relaySSH,
                lifecycle: .exited(.exited(code: 255))
            ) == "SSH process exited with status 255"
        )
        #expect(
            TerminalPresentationPolicy.statusText(
                kind: .relaySSH,
                lifecycle: .exited(.signaled(signal: 15))
            ) == "SSH process terminated by signal 15"
        )
        #expect(
            TerminalPresentationPolicy.statusText(
                kind: .relaySSH,
                lifecycle: .failed(.launch(message: "fixture"))
            ) == "SSH failed to start"
        )
    }

    @Test("[TERM-STATE-001] local status copy remains unchanged")
    func localStatusCopyRemainsPhaseOneCompatible() {
        #expect(
            TerminalPresentationPolicy.statusText(kind: .local, lifecycle: .starting)
                == "Starting local shell"
        )
        #expect(
            TerminalPresentationPolicy.statusText(kind: .local, lifecycle: .running)
                == "Local shell running"
        )
        #expect(
            TerminalPresentationPolicy.statusText(
                kind: .local,
                lifecycle: .exited(.exited(code: 7))
            ) == "Exited with status 7"
        )
    }

    @Test("[TAB-003] live relay close presentation matches the documented decision")
    func relayClosePresentationUsesExactCopy() {
        let prompt = TerminalClosePrompt(
            tabID: TerminalTab.ID(),
            title: "Relay Host",
            disposition: .confirmSSHSession
        )

        let presentation = TerminalPresentationPolicy.closePresentation(for: prompt)

        #expect(presentation.title == "Close this SSH terminal?")
        #expect(
            presentation.message
                == "Closing the tab will terminate the SSH session and may stop a command currently running in this terminal."
        )
        #expect(presentation.confirmButtonTitle == "Close")
    }

    @Test("[MAC-002, TAB-003] mixed shutdown copy distinguishes local and SSH terminals")
    func shutdownCopyDistinguishesTerminalKinds() {
        let prompt = TerminalWorkspaceShutdownPrompt(
            scope: .window,
            foregroundJobCount: 1,
            unknownForegroundActivityCount: 0,
            sshSessionCount: 2
        )

        let message = TerminalPresentationPolicy.shutdownMessage(for: prompt)

        #expect(message.contains("1 local terminal"))
        #expect(message.contains("2 active SSH terminals"))
        #expect(message.localizedCaseInsensitiveContains("terminate"))
        #expect(message.localizedCaseInsensitiveContains("may stop"))
        #expect(!message.contains("3 local terminals"))
    }

    @Test("[A11Y-002, TERM-STATE-001] relay accessibility describes state without claiming connection")
    func relayAccessibilityIdentifiesFixedTarget() {
        let label = TerminalPresentationPolicy.terminalAccessibilityLabel(kind: .relaySSH)
        let runningHint = TerminalPresentationPolicy.terminalAccessibilityHint(
            kind: .relaySSH,
            lifecycle: .running
        )
        let exitedHint = TerminalPresentationPolicy.terminalAccessibilityHint(
            kind: .relaySSH,
            lifecycle: .exited(.exited(code: 255))
        )

        #expect(label.contains("Relay Host"))
        #expect(label.contains("140.109.226.155"))
        #expect(runningHint.contains("OpenSSH"))
        #expect(exitedHint.localizedCaseInsensitiveContains("input is disabled"))
        #expect(exitedHint.localizedCaseInsensitiveContains("scrollback"))
        #expect(!exitedHint.localizedCaseInsensitiveContains("type into"))
        #expect(!label.localizedCaseInsensitiveContains("connected"))
        #expect(!runningHint.localizedCaseInsensitiveContains("connected"))
        #expect(!exitedHint.localizedCaseInsensitiveContains("connected"))
    }

    @Test("[A11Y-002, SESS-007] direct SSH accessibility uses the immutable launch snapshot")
    func directSSHAccessibilityUsesLaunchSnapshotWithoutIdentityPath() throws {
        let specification = try launchSpecification(
            name: "Research Cluster",
            configuration: .ssh(
                .direct(
                    host: "cluster.example",
                    port: 2_222,
                    user: "researcher",
                    identityFilePath: "/Users/example/.ssh/research"
                )
            )
        )

        let label = TerminalPresentationPolicy.terminalAccessibilityLabel(
            launchSpecification: specification
        )

        #expect(label == "SSH terminal, Research Cluster, researcher at cluster.example, port 2222")
        #expect(!label.contains("/Users/example"))
    }

    @Test("[A11Y-002, SESS-007] SSH alias accessibility reports the saved alias")
    func aliasAccessibilityUsesAliasWithoutFabricatingHostFields() throws {
        let specification = try launchSpecification(
            name: "Lab Alias",
            configuration: .ssh(.configAlias(alias: "lab-cluster"))
        )

        let label = TerminalPresentationPolicy.terminalAccessibilityLabel(
            launchSpecification: specification
        )

        #expect(label == "SSH terminal, Lab Alias, SSH config alias lab-cluster")
        #expect(!label.contains(" at "))
        #expect(!label.contains("port"))
    }

    @Test("[A11Y-002, SESS-007] local accessibility never exposes filesystem paths")
    func localAccessibilityOmitsLaunchPaths() throws {
        let specification = try launchSpecification(
            name: "Project Shell",
            configuration: .local(
                .init(
                    useLoginShell: false,
                    shellPath: "/opt/homebrew/bin/fish",
                    workingDirectory: "/Users/example/secret-project"
                )
            )
        )

        let label = TerminalPresentationPolicy.terminalAccessibilityLabel(
            launchSpecification: specification
        )

        #expect(label == "Local terminal, Project Shell")
        #expect(!label.contains("/opt"))
        #expect(!label.contains("/Users"))
    }

    private func launchSpecification(
        name: String,
        configuration: SessionProfileConfiguration
    ) throws -> SessionLaunchSpecification {
        try SessionLaunchSpecification(
            profile: SessionProfile(
                id: SessionProfileID(),
                name: name,
                favorite: false,
                createdAt: .init(timeIntervalSince1970: 1),
                updatedAt: .init(timeIntervalSince1970: 1),
                lastOpenedAt: nil,
                sortOrder: 0,
                configuration: configuration
            )
        )
    }
}
