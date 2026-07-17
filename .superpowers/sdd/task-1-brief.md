### Task 1: Pure tab-strip sizing policy

**Files:**
- Create: `Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift`
- Create: `Sources/XMtermApp/TerminalTabStripLayout.swift`

**Interfaces:**
- Consumes: finite header width, tab count, and optional reserved toolbar width.
- Produces: `TerminalTabStripLayoutPolicy.metrics(availableWidth:tabCount:reservedToolbarWidth:) -> TerminalTabStripLayoutMetrics`.

- [ ] **Step 1: Write failing sizing tests**

Add Swift Testing cases that assert the exact constants and representative geometry:

```swift
@Suite("Terminal tab strip layout")
struct TerminalTabStripLayoutTests {
    private let policy = TerminalTabStripLayoutPolicy()

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
        #expect(metrics.tabWidth >= 120)
        #expect(metrics.tabWidth < 180)
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
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
swift test --filter TerminalTabStripLayoutTests
```

Expected: compile failure because `TerminalTabStripLayoutPolicy` and metrics do not
exist.

- [ ] **Step 3: Implement the minimal pure policy**

Create internal immutable value types with exact public-to-test constants:

```swift
import CoreGraphics

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
        // Sanitize widths, reserve toolbar/separation, use preferred content when
        // it fits, shrink equally to minimum, then keep minimum and scroll.
    }
}
```

Use `gap = tabCount > 0 ? newTabButtonGap : 0`, include
`max(0, tabCount - 1) * interTabSpacing` in content widths, and make
`toolbarRegionMinX` exactly `stripWidth + toolbarSeparation` when space permits.

- [ ] **Step 4: Extend tests for pinned `+`, toolbar separation, zero/invalid width, and thresholds**

Add assertions that:

```swift
#expect(metrics.newTabButtonMinX == policy.leadingPadding + metrics.viewportWidth + policy.newTabButtonGap)
#expect(metrics.stripWidth == metrics.newTabButtonMinX + policy.newTabButtonWidth)
#expect(metrics.toolbarRegionMinX >= metrics.stripWidth + policy.toolbarSeparation)
```

Verify zero tabs omit the gap, reserved toolbar width never overlaps the strip,
nonfinite widths yield bounded metrics, and exact minimum/preferred thresholds do
not oscillate.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run `swift test --filter TerminalTabStripLayoutTests`.

Expected: all layout-policy tests pass.

- [ ] **Step 6: Review the task diff**

Run `git diff -- Sources/XMtermApp/TerminalTabStripLayout.swift Tests/XMtermAppTests/TerminalTabStripLayoutTests.swift` when tracked; otherwise inspect both files directly. Do not create a partial parent-repository commit because `XMterm-starter` is currently untracked under `/Applications/codes`.

---

