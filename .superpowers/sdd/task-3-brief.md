### Task 3: Compose the non-greedy SwiftUI header and scrolling strip

**Files:**
- Create: `Sources/XMtermApp/TerminalWorkspaceHeader.swift`
- Modify: `Sources/XMtermApp/TerminalTabStrip.swift`
- Modify: `Sources/XMtermApp/RootView.swift`
- Modify: `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`

**Interfaces:**
- Consumes: existing tab values and existing select/close/create actions.
- Produces: fixed computed strip width followed by independent remaining header
  space; tab viewport is the only scrollable child.

- [ ] **Step 1: Complete the header-boundary acceptance harness before view changes**

Use policy metrics with a reserved toolbar width and assert:

```swift
let metrics = policy.metrics(
    availableWidth: 900,
    tabCount: 8,
    reservedToolbarWidth: 120
)
#expect(metrics.stripWidth + policy.toolbarSeparation <= 780)
#expect(metrics.toolbarRegionMinX <= 780)
#expect(metrics.newTabButtonMinX >= policy.leadingPadding + metrics.viewportWidth)
```

This assertion belongs in the policy test written before the declarative view is
changed. It must be GREEN after Task 1 and acts as the numerical acceptance harness
for the header composition below.

- [ ] **Step 2: Run the focused acceptance harness**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: the sizing, overflow, pinned-button, and toolbar-boundary tests pass before
the view begins consuming those metrics. If any assertion fails, fix the policy
before changing SwiftUI composition.

- [ ] **Step 3: Create the focused header owner**

`TerminalWorkspaceHeader` uses one `GeometryReader`, calculates metrics once, gives
`TerminalTabStrip` exactly `metrics.stripWidth`, and places a flexible spacer after
it with at least `toolbarSeparation`. It retains the 38-point bar height and `.bar`
background. It adds no toolbar controls.

```swift
GeometryReader { geometry in
    let metrics = layoutPolicy.metrics(
        availableWidth: geometry.size.width,
        tabCount: tabs.count
    )
    HStack(spacing: 0) {
        TerminalTabStrip(/* existing actions */, metrics: metrics)
            .frame(width: metrics.stripWidth, alignment: .leading)
        Spacer(minLength: layoutPolicy.toolbarSeparation)
    }
}
.frame(height: 38)
.background(.bar)
```

- [ ] **Step 4: Refactor the strip around one lazy viewport and pinned menu**

Replace the eager inner stack with:

```swift
ScrollViewReader { proxy in
    ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: layoutPolicy.interTabSpacing) {
            ForEach(tabs) { tab in
                terminalTab(tab)
                    .frame(width: metrics.tabWidth)
                    .id(tab.id)
            }
        }
    }
    .frame(width: metrics.viewportWidth)
    .task(id: revealRequest) {
        guard let target = revealRequest.targetTabID else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .trailing)
        }
    }
}
```

Place the existing `+` `Menu` after the viewport with the policy gap and fixed
28-point target. Remove the old scroll-content horizontal padding and menu trailing
padding, render `leadingPadding` outside the viewport, omit the gap for zero tabs,
and constrain the `Menu` itself rather than only its image. Keep its existing
actions, availability, help, label, and hint;
add `.accessibilityIdentifier("terminal-tab-strip-new-terminal")`. The menu must
not be inside `ScrollView` or `LazyHStack`.

- [ ] **Step 5: Bound tab-cell content and animations**

Give the selection button flexible remaining width and keep the close button fixed.
Apply `.lineLimit(1)` and `.truncationMode(.tail)` to the title. Use a short optional
ease-out animation keyed to ordered tab IDs/selection and return `nil` when
`accessibilityReduceMotion` is true. Width-only reveal during live resize must be
immediate or briefly coalesced rather than animated. Do not add transitions or key
the reader, scroll view, header, or tab cells by metrics, count, index, or title.

- [ ] **Step 6: Switch RootView to the header owner**

Replace only the existing `TerminalTabStrip(...)` call with
`TerminalWorkspaceHeader(...)`, passing the same store values and closures. Keep
the divider, terminal surface, alerts, commands, and lifecycle callbacks unchanged.

- [ ] **Step 7: Build and run focused tests**

Run:

```bash
swift test --filter TerminalTabStripLayoutTests
swift build
```

Expected: focused tests pass and the app compiles without Swift 6 concurrency or
SwiftUI availability warnings.

- [ ] **Step 8: Run app-layer regression tests**

Run:

```bash
swift test --filter TerminalWorkspaceCommandTests
swift test --filter TerminalWorkspaceStoreTests
swift test --filter TerminalWorkspaceStoreSSHTests
```

Expected: creation, selection, close, SSH isolation, and command routing pass
unchanged.

---

