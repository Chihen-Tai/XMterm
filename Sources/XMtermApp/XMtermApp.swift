import SwiftUI

@main
struct XMtermApp: App {
    @NSApplicationDelegateAdaptor(XMtermApplicationDelegate.self)
    private var applicationDelegate
    @State private var commandRouter = TerminalCommandRouter()
    @State private var profileStore = SessionProfileStore.live()

    var body: some Scene {
        Window("XMterm", id: "main") {
            RootView(
                applicationDelegate: applicationDelegate,
                commandRouter: commandRouter,
                profileStore: profileStore
            )
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            TerminalCommands(router: commandRouter)
        }
    }
}
