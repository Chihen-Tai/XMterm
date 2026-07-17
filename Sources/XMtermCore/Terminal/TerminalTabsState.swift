import Foundation

package struct TerminalTabsState: Equatable, Sendable {
    public let tabs: [TerminalTab]
    public let selectedTabID: TerminalTab.ID?
    private let nextLocalTitleOrdinal: UInt64
    private let nextRelayTitleOrdinal: UInt64

    public init() {
        tabs = []
        selectedTabID = nil
        nextLocalTitleOrdinal = 1
        nextRelayTitleOrdinal = 1
    }

    private init(
        tabs: [TerminalTab],
        selectedTabID: TerminalTab.ID?,
        nextLocalTitleOrdinal: UInt64,
        nextRelayTitleOrdinal: UInt64
    ) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.nextLocalTitleOrdinal = nextLocalTitleOrdinal
        self.nextRelayTitleOrdinal = nextRelayTitleOrdinal
    }

    public func creatingTab(
        launchSpecification: SessionLaunchSpecification,
        id: TerminalTab.ID = UUID()
    ) throws -> Self {
        guard !tabs.contains(where: { $0.id == id }) else {
            throw TerminalTabsStateError.duplicateIdentifier(id)
        }

        let tab = TerminalTab(id: id, launchSpecification: launchSpecification)
        return Self(
            tabs: tabs + [tab],
            selectedTabID: id,
            nextLocalTitleOrdinal: nextLocalTitleOrdinal,
            nextRelayTitleOrdinal: nextRelayTitleOrdinal
        )
    }

    public func creatingTab(
        kind: TerminalTabKind = .local,
        id: TerminalTab.ID = UUID()
    ) throws -> Self {
        guard !tabs.contains(where: { $0.id == id }) else {
            throw TerminalTabsStateError.duplicateIdentifier(id)
        }
        let nextTitleOrdinal = switch kind {
        case .local: nextLocalTitleOrdinal
        case .relaySSH: nextRelayTitleOrdinal
        }
        guard nextTitleOrdinal < UInt64.max else {
            throw TerminalTabsStateError.titleOrdinalExhausted
        }

        let baseTitle = switch kind {
        case .local: "Local Shell"
        case .relaySSH: "Relay Host"
        }
        let title = nextTitleOrdinal == 1 ? baseTitle : "\(baseTitle) \(nextTitleOrdinal)"
        let tab = TerminalTab(
            id: id,
            launchSpecification: .legacy(kind: kind, title: title)
        )
        return Self(
            tabs: tabs + [tab],
            selectedTabID: id,
            nextLocalTitleOrdinal: kind == .local
                ? nextTitleOrdinal + 1
                : nextLocalTitleOrdinal,
            nextRelayTitleOrdinal: kind == .relaySSH
                ? nextTitleOrdinal + 1
                : nextRelayTitleOrdinal
        )
    }

    public func selectingTab(id: TerminalTab.ID) -> Self {
        guard tabs.contains(where: { $0.id == id }) else { return self }
        return Self(
            tabs: tabs,
            selectedTabID: id,
            nextLocalTitleOrdinal: nextLocalTitleOrdinal,
            nextRelayTitleOrdinal: nextRelayTitleOrdinal
        )
    }

    public func closingTab(id: TerminalTab.ID) -> Self {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return self }

        let remainingTabs = Array(tabs[..<index]) + Array(tabs[(index + 1)...])
        let replacementID: TerminalTab.ID?
        if selectedTabID == id {
            let replacementIndex = min(index, remainingTabs.count - 1)
            replacementID = replacementIndex >= 0 ? remainingTabs[replacementIndex].id : nil
        } else {
            replacementID = selectedTabID
        }

        return Self(
            tabs: remainingTabs,
            selectedTabID: replacementID,
            nextLocalTitleOrdinal: nextLocalTitleOrdinal,
            nextRelayTitleOrdinal: nextRelayTitleOrdinal
        )
    }

    public func transitioningLifecycle(
        of id: TerminalTab.ID,
        by event: TerminalLifecycleEvent
    ) throws -> Self {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw TerminalTabsStateError.unknownIdentifier(id)
        }

        let updatedTabs = try tabs.enumerated().map { currentIndex, tab in
            guard currentIndex == index else { return tab }
            return tab.updatingLifecycle(try tab.lifecycle.transitioned(by: event))
        }
        return Self(
            tabs: updatedTabs,
            selectedTabID: selectedTabID,
            nextLocalTitleOrdinal: nextLocalTitleOrdinal,
            nextRelayTitleOrdinal: nextRelayTitleOrdinal
        )
    }

    public func updatingTitle(of id: TerminalTab.ID, to title: String) throws -> Self {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw TerminalTabsStateError.unknownIdentifier(id)
        }
        guard let title = TerminalTitlePolicy.sanitize(title) else { return self }

        let updatedTabs = tabs.enumerated().map { currentIndex, tab in
            currentIndex == index ? tab.updatingTitle(title) : tab
        }
        return Self(
            tabs: updatedTabs,
            selectedTabID: selectedTabID,
            nextLocalTitleOrdinal: nextLocalTitleOrdinal,
            nextRelayTitleOrdinal: nextRelayTitleOrdinal
        )
    }
}

package enum TerminalTabsStateError: Error, Equatable, Sendable {
    case duplicateIdentifier(TerminalTab.ID)
    case unknownIdentifier(TerminalTab.ID)
    case titleOrdinalExhausted
}
