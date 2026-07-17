import Foundation

/// Stable identity for one retained terminal runtime.
///
/// A terminal-session identity is intentionally separate from both the saved profile
/// identity and the visible tab identity.
public struct TerminalSessionID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init() {
        self.init(rawValue: UUID())
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Launch-only fields copied from a saved profile before a terminal is created.
public enum SessionLaunchTarget: Hashable, Sendable {
    case local(LocalSessionProfile)
    case ssh(SSHSessionProfile)
}

/// Immutable provenance and launch inputs retained by one launched tab.
public struct SessionLaunchSpecification: Hashable, Sendable {
    public let sourceProfileID: SessionProfileID
    public let initialTitle: String
    public let target: SessionLaunchTarget

    /// Validates the saved value before copying only its launch-relevant fields.
    public init(profile: SessionProfile) throws {
        let validatedProfile = try SessionProfileValidator.validatedProfile(profile)
        sourceProfileID = validatedProfile.id
        initialTitle = validatedProfile.name
        target = switch validatedProfile.configuration {
        case .local(let local):
            .local(local)
        case .ssh(let ssh):
            .ssh(ssh)
        }
    }

    package init(
        sourceProfileID: SessionProfileID,
        initialTitle: String,
        target: SessionLaunchTarget
    ) {
        self.sourceProfileID = sourceProfileID
        self.initialTitle = initialTitle
        self.target = target
    }

    package var kind: TerminalTabKind {
        switch target {
        case .local:
            .local
        case .ssh:
            .relaySSH
        }
    }

    /// Temporary Phase 1/2 compatibility snapshot used until workspace creation is
    /// routed through persisted profiles in the following integration task.
    package static func legacy(kind: TerminalTabKind, title: String) -> Self {
        switch kind {
        case .local:
            Self(
                sourceProfileID: SessionProfileID(
                    rawValue: UUID(
                        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
                    )
                ),
                initialTitle: title,
                target: .local(
                    LocalSessionProfile(
                        useLoginShell: true,
                        shellPath: nil,
                        workingDirectory: nil
                    )
                )
            )
        case .relaySSH:
            Self(
                sourceProfileID: SessionProfileID(
                    rawValue: UUID(
                        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
                    )
                ),
                initialTitle: title,
                target: .ssh(
                    .direct(
                        host: "140.109.226.155",
                        port: 54_426,
                        user: "allen921103",
                        identityFilePath: nil
                    )
                )
            )
        }
    }
}
