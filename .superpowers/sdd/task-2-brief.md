### Task 2: Stable active-tab reveal request

**Files:**
- Modify: `Sources/XMtermApp/TerminalTabStripLayout.swift`
- Modify: `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`

**Interfaces:**
- Consumes: current ordered tab IDs, selected ID, and viewport width.
- Produces: hashable `TerminalTabRevealRequest` with a valid optional `targetTabID`.

- [ ] **Step 1: Write failing reveal-target tests**

```swift
@Test("[TAB-001, TAB-002] creation reveals the selected appended tab")
func creationTargetsAppendedSelection() {
    let request = TerminalTabRevealRequest(
        tabIDs: [firstID, secondID, thirdID],
        selectedTabID: thirdID,
        viewportWidth: 300
    )
    #expect(request.targetTabID == thirdID)
}

@Test("[TAB-002, TAB-003] selection and replacement selection remain revealable")
func selectionTargetsOnlyAContainedID() {
    #expect(validRequest.targetTabID == secondID)
    #expect(staleRequest.targetTabID == nil)
}
```

Also assert that changing viewport width changes request identity so resize can
reveal the active tab again.

- [ ] **Step 2: Run focused tests and confirm RED**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: compile failure because `TerminalTabRevealRequest` does not exist.

- [ ] **Step 3: Implement the immutable request**

```swift
struct TerminalTabRevealRequest: Equatable, Hashable, Sendable {
    let tabIDs: [TerminalTab.ID]
    let selectedTabID: TerminalTab.ID?
    let viewportWidth: CGFloat

    var targetTabID: TerminalTab.ID? {
        guard let selectedTabID, tabIDs.contains(selectedTabID) else { return nil }
        return selectedTabID
    }
}
```

Import `XMtermCore` in the policy file; do not move selection state out of
`TerminalTabsState`.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: sizing and reveal tests pass.

- [ ] **Step 5: Re-run immutable tab-state regression tests**

Run `swift test --filter TerminalTabsStateTests`.

Expected: creation selects the appended ID; closure preserves or replaces selection
exactly as before.

---

