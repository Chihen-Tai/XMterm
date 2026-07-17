import Foundation
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("Profile launch configuration factory")
struct SessionLaunchConfigurationFactoryTests {
    private let grid = TerminalGridSize(columns: 132, rows: 43)

    @Test("[SESS-004, SESS-007] relay and generic direct SSH use exact discrete argv")
    func relayAndGenericDirectSSHUseExactDiscreteArguments() throws {
        let factory = makeFactory(executablePaths: ["/usr/bin/ssh", "/bin/zsh"])
        let relay = try factory.configuration(
            for: specification(
                name: "Relay Host",
                target: .ssh(
                    .direct(
                        host: "140.109.226.155",
                        port: 54_426,
                        user: "allen921103",
                        identityFilePath: nil
                    )
                )
            ),
            initialSize: grid
        )
        let generic = try factory.configuration(
            for: specification(
                name: "Compute",
                target: .ssh(
                    .direct(
                        host: "compute.example",
                        port: 2_222,
                        user: "researcher",
                        identityFilePath: nil
                    )
                )
            ),
            initialSize: grid
        )

        #expect(relay.executablePath == "/usr/bin/ssh")
        #expect(relay.argumentZero == nil)
        #expect(relay.arguments == ["-p", "54426", "allen921103@140.109.226.155"])
        #expect(generic.arguments == ["-p", "2222", "researcher@compute.example"])
        #expect(try generic.validatedArgumentVector() == [
            "/usr/bin/ssh",
            "-p",
            "2222",
            "researcher@compute.example"
        ])
    }

    @Test("[SESS-004, SESS-007] identity path precedes port and target without a shell wrapper")
    func identityArgumentOrderIsExactWithoutWrapper() throws {
        let factory = makeFactory(executablePaths: ["/usr/bin/ssh"])
        let configuration = try factory.configuration(
            for: specification(
                name: "Identity Host",
                target: .ssh(
                    .direct(
                        host: "identity.example",
                        port: 22,
                        user: "operator",
                        identityFilePath: "/Users/example/.ssh/id_fixture"
                    )
                )
            ),
            initialSize: grid
        )

        #expect(configuration.executablePath == "/usr/bin/ssh")
        #expect(configuration.argumentZero == nil)
        #expect(configuration.arguments == [
            "-i",
            "/Users/example/.ssh/id_fixture",
            "-p",
            "22",
            "operator@identity.example"
        ])
        #expect(!configuration.arguments.contains("-c"))
        #expect(!configuration.arguments.contains(where: { $0.contains("ssh ") }))
    }

    @Test("[SESS-004, SESS-007] config aliases are the sole SSH argument with no option separator")
    func configAliasUsesExactlyOneArgument() throws {
        let factory = makeFactory(executablePaths: ["/usr/bin/ssh"])
        let configuration = try factory.configuration(
            for: specification(
                name: "Config Host",
                target: .ssh(.configAlias(alias: "research-cluster"))
            ),
            initialSize: grid
        )

        #expect(configuration.executablePath == "/usr/bin/ssh")
        #expect(configuration.arguments == ["research-cluster"])
        #expect(!configuration.arguments.contains("--"))
        #expect(try configuration.validatedArgumentVector() == [
            "/usr/bin/ssh",
            "research-cluster"
        ])
    }

    @Test("[SESS-004, SESS-007] option-shaped aliases are rejected before launch construction")
    func optionShapedAliasIsRejectedUpstream() {
        let profile = makeProfile(
            name: "Unsafe Alias",
            configuration: .ssh(.configAlias(alias: "-oProxyCommand=fixture"))
        )

        #expect(throws: SessionProfileValidationError.self) {
            try SessionLaunchSpecification(profile: profile)
        }
    }

    @Test("[SESS-007, TERM-PROC-001] login shell resolution and working-directory override stay exact")
    func loginShellResolutionAndWorkingDirectoryAreExact() throws {
        let factory = SessionLaunchConfigurationFactory(
            inheritedEnvironment: inheritedEnvironment,
            userHomeDirectory: "/Users/example",
            loginShellResolver: {
                try TerminalShellResolver.resolve(
                    accountShell: "/opt/homebrew/bin/fish",
                    environmentShell: "/bin/bash",
                    userHomeDirectory: "/Users/example",
                    isUsableExecutableFile: { $0 == "/opt/homebrew/bin/fish" }
                )
            },
            isUsableExecutableFile: { _ in true }
        )
        let configuration = try factory.configuration(
            for: specification(
                name: "Project Shell",
                target: .local(
                    LocalSessionProfile(
                        useLoginShell: true,
                        shellPath: nil,
                        workingDirectory: "/Users/example/project"
                    )
                )
            ),
            initialSize: grid
        )

        #expect(configuration.executablePath == "/opt/homebrew/bin/fish")
        #expect(configuration.argumentZero == "-fish")
        #expect(configuration.arguments.isEmpty)
        #expect(configuration.workingDirectoryPath == "/Users/example/project")
        #expect(configuration.environment["SHELL"] == "/opt/homebrew/bin/fish")
        #expect(configuration.environment["TERM"] == TerminalConfiguration.termName)
        #expect(configuration.environment["TERM_PROGRAM"] == "XMterm")
    }

    @Test("[SESS-007, TERM-PROC-001] custom shells use normal argv zero and optional working directory")
    func customShellUsesNormalArgumentZeroAndWorkingDirectory() throws {
        let factory = makeFactory(executablePaths: ["/opt/local/bin/fish"])
        let configuration = try factory.configuration(
            for: specification(
                name: "Custom Shell",
                target: .local(
                    LocalSessionProfile(
                        useLoginShell: false,
                        shellPath: "/opt/local/bin/fish",
                        workingDirectory: "/Users/example/work"
                    )
                )
            ),
            initialSize: grid
        )

        #expect(configuration.executablePath == "/opt/local/bin/fish")
        #expect(configuration.argumentZero == nil)
        #expect(configuration.arguments.isEmpty)
        #expect(try configuration.validatedArgumentVector() == ["/opt/local/bin/fish"])
        #expect(configuration.workingDirectoryPath == "/Users/example/work")
        #expect(configuration.environment["SHELL"] == "/opt/local/bin/fish")
    }

    @Test("[SESS-003, SESS-004] SSH inherits OpenSSH agent and locale environment")
    func sshPreservesInheritedOpenSSHEnvironment() throws {
        let factory = makeFactory(executablePaths: ["/usr/bin/ssh"])
        let configuration = try factory.configuration(
            for: specification(
                name: "Alias",
                target: .ssh(.configAlias(alias: "cluster"))
            ),
            initialSize: grid
        )

        #expect(configuration.environment["SSH_AUTH_SOCK"] == "/fixture/agent.sock")
        #expect(configuration.environment["SHELL"] == "/bin/zsh")
        #expect(configuration.environment["LC_CTYPE"] == "UTF-8")
        #expect(configuration.environment["TERM"] == TerminalConfiguration.termName)
        #expect(configuration.environment["TERM_PROGRAM"] == "XMterm")
        #expect(configuration.workingDirectoryPath == "/Users/example")
    }

    @Test("[SESS-007] missing SSH and custom-shell executables fail with path-free typed errors")
    func missingExecutablesFailWithoutPathValuesInErrors() throws {
        let factory = makeFactory(executablePaths: [])
        let ssh = try specification(
            name: "Missing SSH",
            target: .ssh(.configAlias(alias: "cluster"))
        )
        let custom = try specification(
            name: "Missing Shell",
            target: .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: "/private/sensitive/custom-shell",
                    workingDirectory: nil
                )
            )
        )

        #expect(throws: SessionLaunchConfigurationError.sshExecutableUnavailable) {
            try factory.configuration(for: ssh, initialSize: grid)
        }
        #expect(throws: SessionLaunchConfigurationError.customShellExecutableUnavailable) {
            try factory.configuration(for: custom, initialSize: grid)
        }
    }

    private var inheritedEnvironment: [String: String] {
        [
            "HOME": "/Users/example",
            "SHELL": "/bin/zsh",
            "SSH_AUTH_SOCK": "/fixture/agent.sock",
            "LC_CTYPE": "UTF-8"
        ]
    }

    private func makeFactory(
        executablePaths: Set<String>
    ) -> SessionLaunchConfigurationFactory {
        SessionLaunchConfigurationFactory(
            inheritedEnvironment: inheritedEnvironment,
            userHomeDirectory: "/Users/example",
            loginShellResolver: {
                ResolvedTerminalShell(
                    executablePath: "/bin/zsh",
                    argumentZero: "-zsh",
                    arguments: [],
                    workingDirectory: "/Users/example"
                )
            },
            isUsableExecutableFile: executablePaths.contains
        )
    }

    private func specification(
        name: String,
        target: SessionLaunchTarget
    ) throws -> SessionLaunchSpecification {
        let configuration: SessionProfileConfiguration = switch target {
        case .local(let local): .local(local)
        case .ssh(let ssh): .ssh(ssh)
        }
        return try SessionLaunchSpecification(
            profile: makeProfile(
                name: name,
                configuration: configuration
            )
        )
    }

    private func makeProfile(
        name: String,
        configuration: SessionProfileConfiguration
    ) -> SessionProfile {
        SessionProfile(
            id: SessionProfileID(),
            name: name,
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: configuration
        )
    }
}
