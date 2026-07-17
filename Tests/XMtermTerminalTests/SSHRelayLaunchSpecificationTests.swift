import Foundation
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("Fixed relay SSH launch specification")
struct SSHRelayLaunchSpecificationTests {
    @Test("[SESS-004, TERM-PROC-001] Relay launch directly uses exact OpenSSH argv")
    func directLaunchUsesExactExecutableAndOrderedArguments() throws {
        let grid = TerminalGridSize(columns: 132, rows: 43)
        let specification = SSHRelayLaunchSpecification.fixedRelay
        let configuration = specification.configuration(
            inheritedEnvironment: [
                "HOME": "/Users/example",
                "SHELL": "/bin/zsh",
                "SSH_AUTH_SOCK": "/tmp/example-agent"
            ],
            workingDirectoryPath: "/Users/example",
            initialSize: grid
        )

        #expect(specification.executableURL.path == "/usr/bin/ssh")
        #expect(specification.arguments == [
            "-p",
            "54426",
            "allen921103@140.109.226.155"
        ])
        #expect(configuration.executablePath == "/usr/bin/ssh")
        #expect(configuration.argumentZero == nil)
        #expect(configuration.arguments == specification.arguments)
        #expect(try configuration.validatedArgumentVector() == [
            "/usr/bin/ssh",
            "-p",
            "54426",
            "allen921103@140.109.226.155"
        ])
        #expect(configuration.workingDirectoryPath == "/Users/example")
        #expect(configuration.initialSize == grid)
    }

    @Test("[SESS-003, SESS-004, TERM-SEC-001] Relay launch preserves trusted environment without secret options")
    func launchAddsNoWrapperRemoteCommandOrSecurityBypass() {
        let inherited = [
            "HOME": "/Users/example",
            "SHELL": "/bin/zsh",
            "SSH_AUTH_SOCK": "/tmp/example-agent",
            "LC_CTYPE": "UTF-8"
        ]
        let configuration = SSHRelayLaunchSpecification.fixedRelay.configuration(
            inheritedEnvironment: inherited,
            workingDirectoryPath: "/Users/example",
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        #expect(configuration.environment["SSH_AUTH_SOCK"] == "/tmp/example-agent")
        #expect(configuration.environment["SHELL"] == "/bin/zsh")
        #expect(configuration.environment["TERM"] == TerminalConfiguration.termName)
        #expect(configuration.environment["TERM_PROGRAM"] == "XMterm")
        #expect(!configuration.arguments.contains("-c"))
        #expect(!configuration.arguments.contains("BatchMode=yes"))
        #expect(!configuration.arguments.contains("StrictHostKeyChecking=no"))
        #expect(!configuration.arguments.contains("UserKnownHostsFile=/dev/null"))
        #expect(!configuration.arguments.contains(where: { argument in
            let lowercased = argument.lowercased()
            return lowercased.contains("password")
                || lowercased.contains("passphrase")
                || lowercased.contains("otp")
        }))
    }
}
