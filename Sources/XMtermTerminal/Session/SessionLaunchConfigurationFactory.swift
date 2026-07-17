import Darwin
import Foundation
import XMtermCore

/// Typed construction failures that never embed executable or working-directory paths.
package enum SessionLaunchConfigurationError: Error, Equatable, Sendable {
    case loginShellExecutableUnavailable
    case customShellExecutableUnavailable
    case sshExecutableUnavailable
}

/// Converts one immutable profile snapshot into the existing PTY process boundary.
package struct SessionLaunchConfigurationFactory {
    private static let sshExecutablePath = "/usr/bin/ssh"

    private let inheritedEnvironment: [String: String]
    private let userHomeDirectory: String
    private let loginShellResolver: () throws -> ResolvedTerminalShell
    private let isUsableExecutableFile: (String) -> Bool

    package init(
        inheritedEnvironment: [String: String],
        userHomeDirectory: String,
        loginShellResolver: @escaping () throws -> ResolvedTerminalShell,
        isUsableExecutableFile: @escaping (String) -> Bool
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.userHomeDirectory = userHomeDirectory
        self.loginShellResolver = loginShellResolver
        self.isUsableExecutableFile = isUsableExecutableFile
    }

    package static func live(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        userHomeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Self {
        Self(
            inheritedEnvironment: inheritedEnvironment,
            userHomeDirectory: userHomeDirectory,
            loginShellResolver: {
                try TerminalShellResolver.resolve(
                    accountShell: accountShellPath(),
                    environmentShell: inheritedEnvironment["SHELL"],
                    userHomeDirectory: userHomeDirectory,
                    isUsableExecutableFile: isUsableExecutableFile(at:)
                )
            },
            isUsableExecutableFile: isUsableExecutableFile(at:)
        )
    }

    package func configuration(
        for specification: SessionLaunchSpecification,
        initialSize: TerminalGridSize
    ) throws -> PTYLaunchConfiguration {
        switch specification.target {
        case .local(let local):
            try localConfiguration(for: local, initialSize: initialSize)
        case .ssh(let ssh):
            try sshConfiguration(for: ssh, initialSize: initialSize)
        }
    }

    private func localConfiguration(
        for profile: LocalSessionProfile,
        initialSize: TerminalGridSize
    ) throws -> PTYLaunchConfiguration {
        if profile.useLoginShell {
            let shell: ResolvedTerminalShell
            do {
                shell = try loginShellResolver()
            } catch {
                throw SessionLaunchConfigurationError.loginShellExecutableUnavailable
            }
            guard isUsableExecutableFile(shell.executablePath) else {
                throw SessionLaunchConfigurationError.loginShellExecutableUnavailable
            }
            return PTYLaunchConfiguration(
                executablePath: shell.executablePath,
                argumentZero: shell.argumentZero,
                arguments: shell.arguments,
                environment: localEnvironment(shellPath: shell.executablePath),
                workingDirectoryPath: profile.workingDirectory ?? shell.workingDirectory,
                initialSize: initialSize
            )
        }

        guard let shellPath = profile.shellPath,
              isUsableExecutableFile(shellPath) else {
            throw SessionLaunchConfigurationError.customShellExecutableUnavailable
        }
        return PTYLaunchConfiguration(
            executablePath: shellPath,
            argumentZero: nil,
            arguments: [],
            environment: localEnvironment(shellPath: shellPath),
            workingDirectoryPath: profile.workingDirectory ?? userHomeDirectory,
            initialSize: initialSize
        )
    }

    private func sshConfiguration(
        for profile: SSHSessionProfile,
        initialSize: TerminalGridSize
    ) throws -> PTYLaunchConfiguration {
        guard isUsableExecutableFile(Self.sshExecutablePath) else {
            throw SessionLaunchConfigurationError.sshExecutableUnavailable
        }

        return Self.sshConfiguration(
            for: profile,
            inheritedEnvironment: inheritedEnvironment,
            userHomeDirectory: userHomeDirectory,
            initialSize: initialSize
        )
    }

    package static func sshArguments(for profile: SSHSessionProfile) -> [String] {
        switch profile {
        case let .direct(host, port, user, identityFilePath):
            if let identityFilePath {
                ["-i", identityFilePath, "-p", String(port), "\(user)@\(host)"]
            } else {
                ["-p", String(port), "\(user)@\(host)"]
            }
        case .configAlias(let alias):
            [alias]
        }
    }

    package static func sshConfiguration(
        for profile: SSHSessionProfile,
        inheritedEnvironment: [String: String],
        userHomeDirectory: String,
        initialSize: TerminalGridSize
    ) -> PTYLaunchConfiguration {
        PTYLaunchConfiguration(
            executablePath: Self.sshExecutablePath,
            argumentZero: nil,
            arguments: sshArguments(for: profile),
            environment: inheritedEnvironment.merging(
                [
                    "TERM": TerminalConfiguration.termName,
                    "TERM_PROGRAM": "XMterm"
                ],
                uniquingKeysWith: { _, xmtermValue in xmtermValue }
            ),
            workingDirectoryPath: userHomeDirectory,
            initialSize: initialSize
        )
    }

    private func localEnvironment(shellPath: String) -> [String: String] {
        terminalEnvironment.merging(
            ["SHELL": shellPath],
            uniquingKeysWith: { _, xmtermValue in xmtermValue }
        )
    }

    private var terminalEnvironment: [String: String] {
        inheritedEnvironment.merging(
            [
                "TERM": TerminalConfiguration.termName,
                "TERM_PROGRAM": "XMterm"
            ],
            uniquingKeysWith: { _, xmtermValue in xmtermValue }
        )
    }

    private static func accountShellPath() -> String? {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = suggestedSize > 0 ? Int(suggestedSize) : 16_384
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = buffer.withUnsafeMutableBufferPointer { storage in
            getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &result)
        }
        guard status == 0, result != nil, let shell = account.pw_shell else { return nil }
        let value = String(cString: shell).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isUsableExecutableFile(at path: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: path) else { return false }
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
