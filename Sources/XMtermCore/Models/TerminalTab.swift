import Foundation

package struct TerminalTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    package let launchSpecification: SessionLaunchSpecification
    public let title: String
    public let lifecycle: TerminalLifecycle

    package var kind: TerminalTabKind {
        launchSpecification.kind
    }

    package var sourceProfileID: SessionProfileID {
        launchSpecification.sourceProfileID
    }

    package init(
        id: UUID = UUID(),
        launchSpecification: SessionLaunchSpecification,
        title: String? = nil,
        lifecycle: TerminalLifecycle = .idle
    ) {
        self.id = id
        self.launchSpecification = launchSpecification
        self.title = title ?? launchSpecification.initialTitle
        self.lifecycle = lifecycle
    }

    package init(
        id: UUID = UUID(),
        kind: TerminalTabKind = .local,
        title: String,
        lifecycle: TerminalLifecycle = .idle
    ) {
        self.id = id
        launchSpecification = .legacy(kind: kind, title: title)
        self.title = title
        self.lifecycle = lifecycle
    }

    func updatingTitle(_ title: String) -> Self {
        Self(
            id: id,
            launchSpecification: launchSpecification,
            title: title,
            lifecycle: lifecycle
        )
    }

    func updatingLifecycle(_ lifecycle: TerminalLifecycle) -> Self {
        Self(
            id: id,
            launchSpecification: launchSpecification,
            title: title,
            lifecycle: lifecycle
        )
    }
}
