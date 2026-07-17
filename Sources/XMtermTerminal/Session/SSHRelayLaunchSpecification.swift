import Foundation
import XMtermCore

/// Immutable direct-OpenSSH launch contract for the single Phase 2 relay target.
package struct SSHRelayLaunchSpecification: Equatable, Sendable {
    package static let fixedRelay = Self(
        profile: .direct(
            host: "140.109.226.155",
            port: 54_426,
            user: "allen921103",
            identityFilePath: nil
        )
    )

    package var executableURL: URL {
        URL(fileURLWithPath: "/usr/bin/ssh")
    }

    package var arguments: [String] {
        SessionLaunchConfigurationFactory.sshArguments(for: profile)
    }

    private let profile: SSHSessionProfile

    private init(profile: SSHSessionProfile) {
        self.profile = profile
    }

    package func configuration(
        inheritedEnvironment: [String: String],
        workingDirectoryPath: String,
        initialSize: TerminalGridSize
    ) -> PTYLaunchConfiguration {
        SessionLaunchConfigurationFactory.sshConfiguration(
            for: profile,
            inheritedEnvironment: inheritedEnvironment,
            userHomeDirectory: workingDirectoryPath,
            initialSize: initialSize
        )
    }
}
