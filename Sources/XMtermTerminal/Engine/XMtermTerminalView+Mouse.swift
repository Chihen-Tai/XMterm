import AppKit

extension XMtermTerminalView {
    func beginMouseEvent(_ event: NSEvent) {
        allowMouseReporting = acceptsInput
            && getTerminal().mouseMode != .off
            && !event.modifierFlags.contains(.option)
    }

    func finishMouseEvent() {
        allowMouseReporting = false
    }
}
