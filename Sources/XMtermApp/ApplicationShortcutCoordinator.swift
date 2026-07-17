import AppKit

enum ApplicationShortcutAction: Equatable {
    case closeTerminal
    case closeWindow
}

enum ApplicationShortcutRouter {
    static func route(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ApplicationShortcutAction? {
        guard charactersIgnoringModifiers?.lowercased() == "w" else { return nil }

        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command] {
            return .closeTerminal
        }
        if modifiers == [.command, .shift] {
            return .closeWindow
        }
        return nil
    }
}

enum ApplicationMenuShortcutNormalizationError: Error {
    case closeTerminalItemMissing
    case closeWindowItemMissing
}

/// Repairs AppKit's runtime menu after SwiftUI has installed its default File > Close command.
///
/// SwiftUI otherwise resolves the duplicate Command-W declarations in favor of window closure,
/// even though XMterm's interaction contract assigns Command-W to the selected terminal and
/// Shift-Command-W to the window. Mutating the framework-owned menu is an AppKit integration
/// boundary; application/domain state remains immutable.
@MainActor
enum ApplicationMenuShortcutNormalizer {
    static func normalize(_ mainMenu: NSMenu) throws {
        let items = flattenedItems(in: mainMenu)
        guard let closeTerminal = items.first(where: { $0.title == "Close Terminal" }) else {
            throw ApplicationMenuShortcutNormalizationError.closeTerminalItemMissing
        }
        guard let closeWindow = items.first(where: { $0.title == "Close Window" }) else {
            throw ApplicationMenuShortcutNormalizationError.closeWindowItemMissing
        }

        for item in items where item !== closeTerminal && isCommandW(item) {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }

        closeTerminal.keyEquivalent = "w"
        closeTerminal.keyEquivalentModifierMask = [.command]
        closeWindow.keyEquivalent = "w"
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
    }

    private static func flattenedItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(flattenedItems(in:)) ?? [])
        }
    }

    private static func isCommandW(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent.lowercased() == "w"
            && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                == [.command]
    }
}
