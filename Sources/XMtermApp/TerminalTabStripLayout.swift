import CoreGraphics
import XMtermCore

struct TerminalTabRevealRequest: Equatable, Hashable, Sendable {
    let tabIDs: [TerminalTab.ID]
    let selectedTabID: TerminalTab.ID?
    let viewportWidth: CGFloat

    var targetTabID: TerminalTab.ID? {
        guard let selectedTabID, tabIDs.contains(selectedTabID) else { return nil }
        return selectedTabID
    }
}

struct TerminalTabRevealSchedule: Equatable, Sendable {
    let delay: Duration
    let shouldAnimate: Bool
}

struct TerminalTabRevealSchedulingPolicy: Equatable, Sendable {
    let renderSettleDelay: Duration = .milliseconds(16)
    let viewportDebounceDelay: Duration = .milliseconds(75)

    func schedule(
        from previous: TerminalTabRevealRequest?,
        to current: TerminalTabRevealRequest
    ) -> TerminalTabRevealSchedule? {
        guard current.targetTabID != nil else { return nil }

        let tabStateChanged = previous.map {
            $0.tabIDs != current.tabIDs
                || $0.selectedTabID != current.selectedTabID
        } ?? false
        let viewportOnlyChange = previous != nil && !tabStateChanged

        return TerminalTabRevealSchedule(
            delay: viewportOnlyChange ? viewportDebounceDelay : renderSettleDelay,
            shouldAnimate: tabStateChanged
        )
    }
}

struct TerminalTabStripLayoutMetrics: Equatable, Sendable {
    let tabWidth: CGFloat
    let tabContentWidth: CGFloat
    let viewportWidth: CGFloat
    let stripWidth: CGFloat
    let newTabButtonMinX: CGFloat
    let toolbarRegionMinX: CGFloat
    let requiresHorizontalScrolling: Bool
}

struct TerminalTabStripLayoutPolicy: Equatable, Sendable {
    let minimumTabWidth: CGFloat = 120
    let preferredTabWidth: CGFloat = 180
    let maximumTabWidth: CGFloat = 240
    let interTabSpacing: CGFloat = 4
    let leadingPadding: CGFloat = 8
    let newTabButtonGap: CGFloat = 4
    let newTabButtonWidth: CGFloat = 28
    let toolbarSeparation: CGFloat = 8

    func metrics(
        availableWidth: CGFloat,
        tabCount: Int,
        reservedToolbarWidth: CGFloat = 0
    ) -> TerminalTabStripLayoutMetrics {
        let availableWidth = finiteNonnegative(availableWidth)
        let tabCount = max(0, tabCount)
        let gap = tabCount > 0 ? newTabButtonGap : 0
        let fixedStripWidth = leadingPadding + gap + newTabButtonWidth
        let maximumToolbarReservation = max(
            0,
            availableWidth - fixedStripWidth - toolbarSeparation
        )
        let reservedToolbarWidth = min(
            finiteNonnegative(reservedToolbarWidth),
            maximumToolbarReservation
        )
        let viewportCapacity = max(
            0,
            availableWidth
                - fixedStripWidth
                - toolbarSeparation
                - reservedToolbarWidth
        )
        let tabGeometry = tabGeometry(
            viewportCapacity: viewportCapacity,
            tabCount: tabCount
        )
        let newTabButtonMinX = leadingPadding + tabGeometry.viewportWidth + gap
        let stripWidth = newTabButtonMinX + newTabButtonWidth
        let toolbarRegionMinX = min(
            availableWidth,
            stripWidth + toolbarSeparation
        )

        return TerminalTabStripLayoutMetrics(
            tabWidth: tabGeometry.tabWidth,
            tabContentWidth: tabGeometry.contentWidth,
            viewportWidth: tabGeometry.viewportWidth,
            stripWidth: stripWidth,
            newTabButtonMinX: newTabButtonMinX,
            toolbarRegionMinX: toolbarRegionMinX,
            requiresHorizontalScrolling: tabGeometry.requiresScrolling
        )
    }

    private func tabGeometry(
        viewportCapacity: CGFloat,
        tabCount: Int
    ) -> (
        tabWidth: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat,
        requiresScrolling: Bool
    ) {
        guard tabCount > 0 else { return (0, 0, 0, false) }

        let spacingWidth = CGFloat(tabCount - 1) * interTabSpacing
        let preferredContentWidth = CGFloat(tabCount) * preferredTabWidth + spacingWidth
        let minimumContentWidth = CGFloat(tabCount) * minimumTabWidth + spacingWidth

        if preferredContentWidth <= viewportCapacity {
            return (
                preferredTabWidth,
                preferredContentWidth,
                preferredContentWidth,
                false
            )
        }
        if minimumContentWidth <= viewportCapacity {
            let tabWidth = (viewportCapacity - spacingWidth) / CGFloat(tabCount)
            return (tabWidth, viewportCapacity, viewportCapacity, false)
        }
        return (minimumTabWidth, minimumContentWidth, viewportCapacity, true)
    }

    private func finiteNonnegative(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return 0 }
        return max(0, width)
    }
}
