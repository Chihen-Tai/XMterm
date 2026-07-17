import SwiftUI

/// A lifecycle-neutral bridge for a terminal view retained by its owning session.
package struct RetainedTerminalView: NSViewRepresentable {
    package let terminalView: XMtermTerminalView

    package init(terminalView: XMtermTerminalView) {
        self.terminalView = terminalView
    }

    package func makeNSView(context: Context) -> XMtermTerminalView {
        terminalView
    }

    package func updateNSView(_ nsView: XMtermTerminalView, context: Context) {
        // The owning session and AppKit view are reference-stable; SwiftUI has no duplicated state.
    }

    package static func dismantleNSView(_ nsView: XMtermTerminalView, coordinator: ()) {
        // Tab switching can dismantle a representable. Process/view lifecycle belongs to the
        // owning TerminalSession, so dismantling must not close the PTY or clear scrollback.
    }

    @MainActor
    var representedViewForTesting: XMtermTerminalView {
        terminalView
    }
}
