import Foundation
@preconcurrency import SwiftTerm

/// Adapts SwiftTerm's pre-concurrency delegate to XMterm's MainActor-owned view.
final class XMtermTerminalViewDelegateBridge: TerminalViewDelegate, @unchecked Sendable {
    weak var owner: XMtermTerminalView?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        deliver { $0.receiveGridSize(columns: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        deliver { $0.receiveTitle(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        deliver { $0.receiveCurrentDirectory(directory) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        deliver { $0.receiveBytes(bytes) }
    }

    func scrolled(source: TerminalView, position: Double) {
        deliver { $0.receiveScrollPosition(position) }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Link activation is intentionally unavailable in Phase 1.
    }

    func bell(source: TerminalView) {
        // Terminal-controlled host sounds are intentionally unavailable in Phase 1.
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 is intercepted before payload decoding; this is defense in depth.
    }

    func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // Host actions and inline image payloads are intentionally unavailable in Phase 1.
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        deliver { $0.receiveVisibleRangeChange() }
    }

    func denyOSC52() {
        deliver { $0.receiveOSC52Denial() }
    }

    private func deliver(
        _ operation: @escaping @MainActor @Sendable (XMtermTerminalView) -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { [weak self] in
                guard let owner = self?.owner else { return }
                operation(owner)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let owner = self?.owner else { return }
            operation(owner)
        }
    }
}
