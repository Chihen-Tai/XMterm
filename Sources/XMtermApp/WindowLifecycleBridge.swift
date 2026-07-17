import AppKit
import SwiftUI

@MainActor
final class WindowCloseRequester {
    fileprivate weak var observer: WindowLifecycleObserverView?

    func requestClose() {
        observer?.requestWindowClose()
    }
}

struct WindowLifecycleBridge: NSViewRepresentable {
    typealias CloseRequest = @MainActor (@escaping @MainActor (Bool) -> Void) -> Void

    let onCloseRequested: CloseRequest
    let requester: WindowCloseRequester

    func makeNSView(context: Context) -> WindowLifecycleObserverView {
        let view = WindowLifecycleObserverView(frame: .zero)
        view.onCloseRequested = onCloseRequested
        requester.observer = view
        return view
    }

    func updateNSView(_ view: WindowLifecycleObserverView, context: Context) {
        view.onCloseRequested = onCloseRequested
        requester.observer = view
        view.installIfPossible()
    }
}

@MainActor
final class WindowLifecycleObserverView: NSView {
    var onCloseRequested: WindowLifecycleBridge.CloseRequest?

    private weak var installedWindow: NSWindow?
    private weak var originalCloseTarget: AnyObject?
    private var originalCloseAction: Selector?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfPossible()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== installedWindow {
            restoreCloseButton()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func installIfPossible() {
        guard let window else { return }
        if installedWindow !== window {
            restoreCloseButton()
            installedWindow = window
        }

        if let closeButton = window.standardWindowButton(.closeButton),
           closeButton.target !== self {
            originalCloseTarget = closeButton.target as AnyObject?
            originalCloseAction = closeButton.action
            closeButton.target = self
            closeButton.action = #selector(requestWindowClose(_:))
        }
    }

    @objc
    private func requestWindowClose(_ sender: Any?) {
        requestWindowClose()
    }

    func requestWindowClose() {
        guard let window = installedWindow, let onCloseRequested else { return }
        onCloseRequested { [weak self, weak window] approved in
            guard approved, let window else { return }
            self?.restoreCloseButton()
            window.performClose(nil)
        }
    }

    private func restoreCloseButton() {
        guard let window = installedWindow,
              let closeButton = window.standardWindowButton(.closeButton),
              closeButton.target === self else {
            installedWindow = nil
            originalCloseTarget = nil
            originalCloseAction = nil
            return
        }
        closeButton.target = originalCloseTarget
        closeButton.action = originalCloseAction
        installedWindow = nil
        originalCloseTarget = nil
        originalCloseAction = nil
    }

}
