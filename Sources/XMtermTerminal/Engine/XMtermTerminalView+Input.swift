import AppKit
import XMtermCore

extension XMtermTerminalView {
    func inputRoute(for event: NSEvent) -> TerminalInputRoute {
        TerminalInputRouter.route(
            key: inputKey(for: event),
            modifiers: inputModifiers(for: event.modifierFlags)
        )
    }

    private func inputKey(for event: NSEvent) -> TerminalInputKey {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let character = characters.first else {
            return .special
        }
        return .character(character)
    }

    private func inputModifiers(for flags: NSEvent.ModifierFlags) -> TerminalInputModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: TerminalInputModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    func performLocalAction(_ action: TerminalLocalAction) {
        switch action {
        case .copy:
            copy(self)
        case .paste:
            paste(self)
        case .find:
            showFindBar()
        case .selectAll:
            selectAll(self)
        case .closeTab, .newTab:
            onLocalAction?(action)
        case .unhandledCommand:
            onLocalAction?(action)
        }
    }

    /// Performs local selection cleanup that must precede normal engine handling.
    /// The returned value tells the event monitor whether input is disabled and the event must be
    /// consumed rather than forwarded to SwiftTerm.
    package func prepareForEngineInput(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            clearSelection()
        }
        return !acceptsInput
    }
}
