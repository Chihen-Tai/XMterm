import Foundation
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("Profile-backed terminal sessions", .serialized)
@MainActor
struct TerminalSessionProfileTests {
    @Test("[SESS-007] a profile-backed terminal retains distinct runtime identity and provenance")
    func terminalSessionIdentityAndSnapshotRemainDistinct() throws {
        let profileID = SessionProfileID(
            rawValue: try #require(
                UUID(uuidString: "00000000-0000-0000-0000-000000000551")
            )
        )
        let tabID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000552")
        )
        let sessionID = TerminalSessionID(
            rawValue: try #require(
                UUID(uuidString: "00000000-0000-0000-0000-000000000553")
            )
        )
        let specification = try makeSpecification(
            id: profileID,
            name: "Config Alias",
            configuration: .ssh(.configAlias(alias: "research-cluster"))
        )
        let session = TerminalSession(
            sessionID: sessionID,
            launchSpecification: specification,
            configurationFactory: makeFactory(executablePaths: ["/usr/bin/ssh"]),
            processLauncher: RecordingTerminalProcessLauncher().launch
        )

        #expect(profileID.rawValue != tabID)
        #expect(session.sessionID == sessionID)
        #expect(session.sessionID.rawValue != tabID)
        #expect(session.sessionID.rawValue != profileID.rawValue)
        #expect(session.launchSpecification == specification)
        #expect(session.launchSpecification.sourceProfileID == profileID)
        #expect(session.kind == .relaySSH)
    }

    @Test("[SESS-004, SESS-007] generic alias sessions launch through the shared PTY path")
    func genericAliasSessionUsesFactoryConfiguration() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let specification = try makeSpecification(
            name: "Config Alias",
            configuration: .ssh(.configAlias(alias: "research-cluster"))
        )
        let session = TerminalSession(
            sessionID: TerminalSessionID(),
            launchSpecification: specification,
            configurationFactory: makeFactory(executablePaths: ["/usr/bin/ssh"]),
            processLauncher: launcher.launch
        )

        session.start()

        try await waitUntil { session.lifecycle == .running }
        let configuration = try #require(await launcher.configurations.first)
        #expect(configuration.executablePath == "/usr/bin/ssh")
        #expect(configuration.arguments == ["research-cluster"])
        #expect(await session.closeDisposition() == .confirmSSHSession)
        #expect(await launcher.process.foregroundQueryCount == 0)
        session.requestClose()
        try await waitUntil { await launcher.process.closeCount == 1 }
    }

    @Test("[SESS-007, SESS-010] later profile replacement cannot reconfigure a session")
    func laterProfileReplacementCannotReconfigureSession() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let profileID = SessionProfileID()
        let original = makeProfile(
            id: profileID,
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
        let specification = try SessionLaunchSpecification(profile: original)
        let replacement = makeProfile(
            id: profileID,
            name: "Replacement Host",
            configuration: .ssh(.configAlias(alias: "replacement"))
        )
        let session = TerminalSession(
            sessionID: TerminalSessionID(),
            launchSpecification: specification,
            configurationFactory: makeFactory(executablePaths: ["/usr/bin/ssh"]),
            processLauncher: launcher.launch
        )

        session.start()

        try await waitUntil { session.lifecycle == .running }
        let configuration = try #require(await launcher.configurations.first)
        #expect(replacement.name == "Replacement Host")
        #expect(session.launchSpecification.initialTitle == "Original Host")
        #expect(configuration.arguments == ["-p", "22", "researcher@original.example"])
        session.requestClose()
        try await waitUntil { await launcher.process.closeCount == 1 }
    }

    @Test("[SESS-007, TERM-STATE-001] unavailable executables produce path-free lifecycle failures")
    func unavailableExecutableFailureDoesNotExposePath() async throws {
        let sensitivePath = "/private/sensitive/custom-shell"
        let specification = try makeSpecification(
            name: "Private Shell",
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: sensitivePath,
                    workingDirectory: "/private/sensitive/work"
                )
            )
        )
        let session = TerminalSession(
            sessionID: TerminalSessionID(),
            launchSpecification: specification,
            configurationFactory: makeFactory(executablePaths: []),
            processLauncher: RecordingTerminalProcessLauncher().launch
        )

        session.start()

        try await waitUntil {
            if case .failed(.launch(let message)) = session.lifecycle {
                return !message.contains(sensitivePath) && !message.contains("/private/sensitive")
            }
            return false
        }
        #expect(
            session.lifecycle
                == .failed(.launch(message: "The configured login shell could not be launched."))
        )
    }

    private func makeFactory(
        executablePaths: Set<String>
    ) -> SessionLaunchConfigurationFactory {
        SessionLaunchConfigurationFactory(
            inheritedEnvironment: [
                "SHELL": "/bin/zsh",
                "SSH_AUTH_SOCK": "/fixture/agent.sock"
            ],
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

    private func makeSpecification(
        id: SessionProfileID = SessionProfileID(),
        name: String,
        configuration: SessionProfileConfiguration
    ) throws -> SessionLaunchSpecification {
        try SessionLaunchSpecification(
            profile: makeProfile(id: id, name: name, configuration: configuration)
        )
    }

    private func makeProfile(
        id: SessionProfileID,
        name: String,
        configuration: SessionProfileConfiguration
    ) -> SessionProfile {
        SessionProfile(
            id: id,
            name: name,
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: configuration
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for profile-backed terminal state")
                return
            }
            await Task.yield()
        }
    }
}
