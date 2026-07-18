import Testing
@testable import XMtermRemote

@Suite("Remote selection state")
struct RemoteSelectionStateTests {
    @Test("[FILE-SEL-001] click replaces selection and moves anchor and focus")
    func clickReplacesSelection() throws {
        let fixture = try Fixture()
        let initial = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.beta, command: false, shift: false, visiblePaths: fixture.visible)

        #expect(initial.orderedPaths == [fixture.beta])
        #expect(initial.anchor == fixture.beta)
        #expect(initial.focusedPath == fixture.beta)
    }

    @Test("[FILE-SEL-001] Command-click toggles exact paths and anchors additions")
    func commandClickTogglesExactPath() throws {
        let fixture = try Fixture()
        let selected = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.gamma, command: true, shift: false, visiblePaths: fixture.visible)

        #expect(selected.orderedPaths == [fixture.alpha, fixture.gamma])
        #expect(selected.anchor == fixture.gamma)
        #expect(selected.focusedPath == fixture.gamma)

        let toggled = selected.clicking(
            fixture.gamma,
            command: true,
            shift: false,
            visiblePaths: fixture.visible
        )
        #expect(toggled.orderedPaths == [fixture.alpha])
        #expect(toggled.anchor == fixture.gamma)
        #expect(toggled.focusedPath == fixture.gamma)
    }

    @Test("[FILE-SEL-001] Shift-click replaces with the inclusive projection range")
    func shiftClickSelectsInclusiveRangeInProjectionOrder() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.delta, command: false, shift: true, visiblePaths: fixture.visible)

        #expect(selection.orderedPaths == [fixture.alpha, fixture.beta, fixture.gamma, fixture.delta])
        #expect(selection.anchor == fixture.alpha)
        #expect(selection.focusedPath == fixture.delta)
    }

    @Test("[FILE-SEL-001] Command-Shift-click unions the inclusive range in projection order")
    func commandShiftClickUnionsRange() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.beta, command: true, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.delta, command: true, shift: true, visiblePaths: fixture.visible)

        #expect(selection.orderedPaths == [fixture.alpha, fixture.beta, fixture.gamma, fixture.delta])
        #expect(selection.anchor == fixture.beta)
        #expect(selection.focusedPath == fixture.delta)
    }

    @Test("[FILE-SEL-001] arrows replace selection while Shift-arrows extend the retained anchor")
    func arrowMovementAndExtension() throws {
        let fixture = try Fixture()
        let focused = RemoteSelectionState()
            .clicking(fixture.beta, command: false, shift: false, visiblePaths: fixture.visible)
            .movingFocus(by: 1, extending: false, visiblePaths: fixture.visible)

        #expect(focused.orderedPaths == [fixture.gamma])
        #expect(focused.anchor == fixture.gamma)
        #expect(focused.focusedPath == fixture.gamma)

        let extended = focused.movingFocus(by: 1, extending: true, visiblePaths: fixture.visible)
        #expect(extended.orderedPaths == [fixture.gamma, fixture.delta])
        #expect(extended.anchor == fixture.gamma)
        #expect(extended.focusedPath == fixture.delta)
    }

    @Test("[FILE-SEL-001] arrows begin at the first or last visible row when selection is empty")
    func arrowMovementFromEmptySelection() throws {
        let fixture = try Fixture()
        let down = RemoteSelectionState().movingFocus(
            by: 1,
            extending: false,
            visiblePaths: fixture.visible
        )
        let up = RemoteSelectionState().movingFocus(
            by: -1,
            extending: false,
            visiblePaths: fixture.visible
        )
        let extendingDown = RemoteSelectionState().movingFocus(
            by: 1,
            extending: true,
            visiblePaths: fixture.visible
        )

        #expect(down.orderedPaths == [fixture.alpha])
        #expect(down.anchor == fixture.alpha)
        #expect(up.orderedPaths == [fixture.delta])
        #expect(up.anchor == fixture.delta)
        #expect(extendingDown.orderedPaths == [fixture.alpha])
        #expect(extendingDown.anchor == fixture.alpha)
    }

    @Test("[FILE-SEL-001] Command-A uses every visible path once in projection order")
    func selectingAllUsesProjectionOrder() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState().selectingAll(visiblePaths: [
            fixture.gamma, fixture.alpha, fixture.gamma, fixture.beta
        ])

        #expect(selection.orderedPaths == [fixture.gamma, fixture.alpha, fixture.beta])
        #expect(selection.anchor == fixture.gamma)
        #expect(selection.focusedPath == fixture.gamma)
    }

    @Test("[FILE-SEL-001] Escape clears paths, anchor, and focus")
    func clearingSelection() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clearing()

        #expect(selection.orderedPaths.isEmpty)
        #expect(selection.anchor == nil)
        #expect(selection.focusedPath == nil)
    }

    @Test("[FILE-SEL-001] context-click preserves a selected row and replaces an unselected row")
    func contextClickUsesNativeSelectionSemantics() throws {
        let fixture = try Fixture()
        let selected = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.beta, command: true, shift: false, visiblePaths: fixture.visible)

        let preserved = selected.contextClicking(fixture.alpha, visiblePaths: fixture.visible)
        #expect(preserved == selected)

        let replaced = selected.contextClicking(fixture.delta, visiblePaths: fixture.visible)
        #expect(replaced.orderedPaths == [fixture.delta])
        #expect(replaced.anchor == fixture.delta)
        #expect(replaced.focusedPath == fixture.delta)
    }

    @Test("[FILE-SEL-001] exact raw paths distinguish duplicate lossy display names")
    func exactRawIdentityDistinguishesLossyNames() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.lossyOne, command: false, shift: false, visiblePaths: fixture.lossyVisible)
            .clicking(fixture.lossyTwo, command: true, shift: false, visiblePaths: fixture.lossyVisible)

        #expect(selection.orderedPaths == [fixture.lossyOne, fixture.lossyTwo])
        #expect(fixture.lossyOne.losslessString == nil)
        #expect(fixture.lossyTwo.losslessString == nil)
        #expect(fixture.lossyOne != fixture.lossyTwo)
    }

    @Test("[FILE-SEL-001] collapse removes hidden descendants and selects the ancestor once")
    func collapseReconcilesToVisibleAncestor() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.child, command: false, shift: false, visiblePaths: fixture.collapseVisible)
            .clicking(fixture.outside, command: true, shift: false, visiblePaths: fixture.collapseVisible)
            .reconciling(visiblePaths: [fixture.outside, fixture.parent], collapsedAncestor: fixture.parent)

        #expect(selection.orderedPaths == [fixture.outside, fixture.parent])
        #expect(selection.anchor == fixture.outside)
        #expect(selection.focusedPath == fixture.outside)
    }

    @Test("[FILE-NAV-002] refresh keeps exact surviving paths and removes absent raw paths")
    func refreshReconcilesExactSurvivorsOnly() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.beta, command: true, shift: false, visiblePaths: fixture.visible)
            .reconciling(visiblePaths: [fixture.alpha, fixture.gamma], collapsedAncestor: nil)

        #expect(selection.orderedPaths == [fixture.alpha])
        #expect(selection.anchor == fixture.alpha)
        #expect(selection.focusedPath == fixture.alpha)
    }

    @Test("[FILE-SEL-001] history compatibility projection is nil for multi-selection")
    func historyCompatibilityProjectionRejectsMultiSelection() throws {
        let fixture = try Fixture()
        let selection = RemoteSelectionState()
            .clicking(fixture.alpha, command: false, shift: false, visiblePaths: fixture.visible)
            .clicking(fixture.beta, command: true, shift: false, visiblePaths: fixture.visible)
        let location = RemoteWorkspaceLocation(
            directory: try Self.path("/work"),
            selection: selection,
            scrollRestorationToken: nil
        )

        #expect(location.selectedEntry == nil)
    }

    private struct Fixture {
        let alpha: RemotePath
        let beta: RemotePath
        let gamma: RemotePath
        let delta: RemotePath
        let parent: RemotePath
        let child: RemotePath
        let outside: RemotePath
        let lossyOne: RemotePath
        let lossyTwo: RemotePath

        var visible: [RemotePath] { [alpha, beta, gamma, delta] }
        var collapseVisible: [RemotePath] { [parent, child, outside] }
        var lossyVisible: [RemotePath] { [lossyOne, lossyTwo] }

        init() throws {
            alpha = try Self.path("/work/alpha")
            beta = try Self.path("/work/beta")
            gamma = try Self.path("/work/gamma")
            delta = try Self.path("/work/delta")
            parent = try Self.path("/work/parent")
            child = try Self.path("/work/parent/child")
            outside = try Self.path("/work/outside")
            let lossyDirectory = try Self.path("/work/lossy")
            lossyOne = try RemotePath(
                components: lossyDirectory.components + [RemotePathComponent(rawBytes: [0x80])]
            )
            lossyTwo = try RemotePath(
                components: lossyDirectory.components + [RemotePathComponent(rawBytes: [0x81])]
            )
        }

        private static func path(_ value: String) throws -> RemotePath {
            try RemotePath(rawBytes: Array(value.utf8))
        }
    }

    private static func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}
