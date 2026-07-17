import CoreGraphics
import Foundation
import Testing
@testable import XMtermApp

@Suite("Terminal tab strip layout")
struct TerminalTabStripLayoutTests {
    private let policy = TerminalTabStripLayoutPolicy()

    @Test("[TAB-001, TAB-002] reveal request targets the appended selected ID")
    func appendedSelectionIsRevealTarget() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let request = TerminalTabRevealRequest(
            tabIDs: [firstID, secondID, thirdID],
            selectedTabID: thirdID,
            viewportWidth: 300
        )

        #expect(request.targetTabID == thirdID)
    }

    @Test("[TAB-002, TAB-003] reveal request accepts only a contained selected ID")
    func onlyContainedSelectionIsRevealTarget() {
        let firstID = UUID()
        let secondID = UUID()
        let staleID = UUID()
        let validRequest = TerminalTabRevealRequest(
            tabIDs: [firstID, secondID],
            selectedTabID: secondID,
            viewportWidth: 300
        )
        let staleRequest = TerminalTabRevealRequest(
            tabIDs: [firstID, secondID],
            selectedTabID: staleID,
            viewportWidth: 300
        )

        #expect(validRequest.targetTabID == secondID)
        #expect(staleRequest.targetTabID == nil)
    }

    @Test("[TAB-002] viewport width participates in reveal request identity")
    func viewportWidthChangesRequestIdentity() {
        let selectedID = UUID()
        let narrowRequest = TerminalTabRevealRequest(
            tabIDs: [selectedID],
            selectedTabID: selectedID,
            viewportWidth: 300
        )
        let equivalentRequest = TerminalTabRevealRequest(
            tabIDs: [selectedID],
            selectedTabID: selectedID,
            viewportWidth: 300
        )
        let wideRequest = TerminalTabRevealRequest(
            tabIDs: [selectedID],
            selectedTabID: selectedID,
            viewportWidth: 600
        )

        #expect(narrowRequest == equivalentRequest)
        #expect(narrowRequest != wideRequest)
        #expect(Set([narrowRequest, equivalentRequest, wideRequest]).count == 2)
    }

    @Test("[TAB-002] initial reveal settles once without animation")
    func initialRevealSchedule() throws {
        let selectedID = UUID()
        let request = TerminalTabRevealRequest(
            tabIDs: [selectedID],
            selectedTabID: selectedID,
            viewportWidth: 300
        )

        let schedule = try #require(
            TerminalTabRevealSchedulingPolicy().schedule(
                from: nil,
                to: request
            )
        )

        #expect(schedule.delay == .milliseconds(16))
        #expect(!schedule.shouldAnimate)
    }

    @Test("[TAB-001, TAB-002] tab and selection changes use one subtle reveal")
    func tabStateChangeRevealSchedule() throws {
        let firstID = UUID()
        let secondID = UUID()
        let previous = TerminalTabRevealRequest(
            tabIDs: [firstID],
            selectedTabID: firstID,
            viewportWidth: 300
        )
        let current = TerminalTabRevealRequest(
            tabIDs: [firstID, secondID],
            selectedTabID: secondID,
            viewportWidth: 300
        )

        let schedule = try #require(
            TerminalTabRevealSchedulingPolicy().schedule(
                from: previous,
                to: current
            )
        )

        #expect(schedule.delay == .milliseconds(16))
        #expect(schedule.shouldAnimate)
    }

    @Test("[TAB-002] viewport-only reveals debounce and remain unanimated")
    func viewportChangeRevealSchedule() throws {
        let selectedID = UUID()
        let previous = TerminalTabRevealRequest(
            tabIDs: [selectedID],
            selectedTabID: selectedID,
            viewportWidth: 300
        )
        let current = TerminalTabRevealRequest(
            tabIDs: [selectedID],
            selectedTabID: selectedID,
            viewportWidth: 301
        )

        let schedule = try #require(
            TerminalTabRevealSchedulingPolicy().schedule(
                from: previous,
                to: current
            )
        )

        #expect(schedule.delay == .milliseconds(75))
        #expect(!schedule.shouldAnimate)
    }

    @Test("[TAB-002] stale selection produces no reveal schedule")
    func staleSelectionHasNoRevealSchedule() {
        let request = TerminalTabRevealRequest(
            tabIDs: [UUID()],
            selectedTabID: UUID(),
            viewportWidth: 300
        )

        #expect(
            TerminalTabRevealSchedulingPolicy().schedule(
                from: nil,
                to: request
            ) == nil
        )
    }

    @Test("[TAB-002] non-overflow viewport uses actual preferred-width content")
    func nonOverflowIsContentSized() {
        let metrics = policy.metrics(availableWidth: 1_000, tabCount: 3)

        #expect(policy.minimumTabWidth == 120)
        #expect(policy.preferredTabWidth == 180)
        #expect(policy.maximumTabWidth == 240)
        #expect(metrics.tabWidth == 180)
        #expect(metrics.tabContentWidth == 548)
        #expect(metrics.viewportWidth == 548)
        #expect(!metrics.requiresHorizontalScrolling)
    }

    @Test("[TAB-002] tabs shrink equally before minimum-width overflow")
    func tabsShrinkEqually() {
        let metrics = policy.metrics(availableWidth: 500, tabCount: 3)

        #expect(metrics.tabWidth == 148)
        #expect(metrics.viewportWidth == metrics.tabContentWidth)
        #expect(!metrics.requiresHorizontalScrolling)
    }

    @Test("[TAB-002, A11Y-003] overflow holds the readable minimum width")
    func overflowUsesMinimumWidth() {
        let metrics = policy.metrics(availableWidth: 360, tabCount: 4)

        #expect(metrics.tabWidth == 120)
        #expect(metrics.tabContentWidth > metrics.viewportWidth)
        #expect(metrics.requiresHorizontalScrolling)
    }

    @Test("[TAB-001, TAB-002] new-terminal control is pinned after the viewport")
    func newTabButtonIsPinnedAfterViewport() {
        let metrics = policy.metrics(availableWidth: 1_000, tabCount: 3)

        #expect(metrics.newTabButtonMinX == 560)
        #expect(metrics.stripWidth == 588)
        #expect(metrics.toolbarRegionMinX == 596)
        #expect(
            metrics.newTabButtonMinX
                == policy.leadingPadding + metrics.viewportWidth + policy.newTabButtonGap
        )
        #expect(metrics.stripWidth == metrics.newTabButtonMinX + policy.newTabButtonWidth)
        #expect(metrics.toolbarRegionMinX == metrics.stripWidth + policy.toolbarSeparation)
    }

    @Test("[TAB-002, MAC-001] reserved toolbar width remains outside the tab strip")
    func reservedToolbarWidthDoesNotOverlapStrip() {
        let availableWidth: CGFloat = 900
        let reservedToolbarWidth: CGFloat = 120
        let metrics = policy.metrics(
            availableWidth: availableWidth,
            tabCount: 8,
            reservedToolbarWidth: reservedToolbarWidth
        )

        #expect(metrics.stripWidth + policy.toolbarSeparation <= 780)
        #expect(metrics.toolbarRegionMinX <= 780)
        #expect(
            metrics.newTabButtonMinX
                >= policy.leadingPadding + metrics.viewportWidth
        )
        #expect(metrics.stripWidth + policy.toolbarSeparation == 780)
        #expect(metrics.toolbarRegionMinX == metrics.stripWidth + policy.toolbarSeparation)
        #expect(availableWidth - metrics.toolbarRegionMinX >= reservedToolbarWidth)
    }

    @Test("[TAB-001] zero tabs omit the gap before the new-terminal control")
    func zeroTabsOmitNewTabButtonGap() {
        let metrics = policy.metrics(availableWidth: 1_000, tabCount: 0)

        #expect(metrics.tabWidth == 0)
        #expect(metrics.tabContentWidth == 0)
        #expect(metrics.viewportWidth == 0)
        #expect(metrics.newTabButtonMinX == policy.leadingPadding)
        #expect(metrics.stripWidth == policy.leadingPadding + policy.newTabButtonWidth)
        #expect(!metrics.requiresHorizontalScrolling)
    }

    @Test("[TAB-001, TAB-002] sub-minimum header proposals stay bounded")
    func narrowHeaderProposalsStayBounded() {
        for availableWidth in [CGFloat(0), 8, 35, 36, 43] {
            let metrics = policy.metrics(availableWidth: availableWidth, tabCount: 0)

            #expect(metrics.allWidthsAreFiniteAndNonnegative)
            #expect(metrics.viewportWidth == 0)
            #expect(metrics.toolbarRegionMinX <= availableWidth)
        }

        let exactFixedChrome = policy.metrics(availableWidth: 44, tabCount: 0)
        #expect(exactFixedChrome.stripWidth == 36)
        #expect(
            exactFixedChrome.toolbarRegionMinX
                == exactFixedChrome.stripWidth + policy.toolbarSeparation
        )
        #expect(exactFixedChrome.toolbarRegionMinX == 44)
    }

    @Test("[TAB-002] invalid width proposals produce finite nonnegative geometry")
    func invalidWidthsAreSanitized() {
        let metrics = [CGFloat.nan, .infinity, -.infinity, -100].map {
            policy.metrics(availableWidth: $0, tabCount: 3)
        }

        #expect(metrics.allSatisfy { $0.allWidthsAreFiniteAndNonnegative })
        #expect(metrics.allSatisfy { $0.viewportWidth == 0 })
    }

    @Test("[TAB-002] invalid toolbar reservations consume no tab-strip width")
    func invalidToolbarReservationsAreSanitized() {
        let baseline = policy.metrics(availableWidth: 500, tabCount: 3)
        let invalidReservations = [CGFloat.nan, .infinity, -.infinity, -100]

        for reservation in invalidReservations {
            #expect(
                policy.metrics(
                    availableWidth: 500,
                    tabCount: 3,
                    reservedToolbarWidth: reservation
                ) == baseline
            )
        }
    }

    @Test("[TAB-002] exact preferred and minimum thresholds are stable")
    func exactThresholdsDoNotOscillate() {
        let exactPreferred = policy.metrics(availableWidth: 596, tabCount: 3)
        let belowPreferred = policy.metrics(availableWidth: 595, tabCount: 3)
        let exactMinimum = policy.metrics(availableWidth: 416, tabCount: 3)
        let belowMinimum = policy.metrics(availableWidth: 415, tabCount: 3)

        #expect(exactPreferred.tabWidth == 180)
        #expect(!exactPreferred.requiresHorizontalScrolling)
        #expect(belowPreferred.tabWidth < 180)
        #expect(!belowPreferred.requiresHorizontalScrolling)
        #expect(exactMinimum.tabWidth == 120)
        #expect(!exactMinimum.requiresHorizontalScrolling)
        #expect(belowMinimum.tabWidth == 120)
        #expect(belowMinimum.requiresHorizontalScrolling)
    }
}

private extension TerminalTabStripLayoutMetrics {
    var allWidthsAreFiniteAndNonnegative: Bool {
        let widths = [
            tabWidth,
            tabContentWidth,
            viewportWidth,
            stripWidth,
            newTabButtonMinX,
            toolbarRegionMinX
        ]
        return widths.allSatisfy { $0.isFinite && $0 >= 0 }
    }
}
