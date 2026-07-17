import SwiftUI
import XMtermCore

struct RootView: View {
    let applicationDelegate: XMtermApplicationDelegate
    let commandRouter: TerminalCommandRouter
    let profileStore: SessionProfileStore

    @State private var workspace = TerminalWorkspaceStore()
    @State private var windowCloseRequester = WindowCloseRequester()
    @State private var isSessionPickerPresented = false
    @State private var isSessionManagerPresented = false
    @State private var editorRoute: EditorRoute?
    @State private var didBeginProfileWorkflow = false

    private struct EditorRoute: Identifiable {
        let id = UUID()
        let profile: SessionProfile?
        let kind: SessionProfileDraftKind
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                savedSessionsSummary
                Divider()
                RemoteWorkspaceSidebar(store: workspace)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 420)
        } detail: {
            VStack(spacing: 0) {
                TerminalWorkspaceHeader(
                    tabs: workspace.tabs,
                    selectedTabID: workspace.tabsState.selectedTabID,
                    select: workspace.selectTab,
                    close: workspace.requestClose,
                    isSessionPickerPresented: $isSessionPickerPresented,
                    profileStore: profileStore,
                    launchProfile: launchProfile,
                    createProfile: presentEditor,
                    editProfile: presentEditor,
                    manageProfiles: presentSessionManager,
                    restoreTerminalFocus: workspace.focusSelectedTerminal,
                    canCreate: workspace.canCreateTerminal
                )
                Divider()
                terminalSurface
                    .overlay(alignment: .top) {
                        if let failure = visibleProfileFailure {
                            SessionProfileFailureBanner(
                                failure: failure,
                                dismiss: profileStore.clearFailure
                            )
                            .frame(maxWidth: 520)
                            .padding(12)
                        }
                    }
            }
        }
        .task {
            await beginProfileWorkflowIfNeeded()
        }
        .onAppear {
            workspace.newTerminalRequest = requestDefaultTerminal
            commandRouter.attach(
                workspace: workspace,
                closeWindow: windowCloseRequester.requestClose,
                newTerminal: requestDefaultTerminal,
                chooseSession: presentSessionPicker,
                manageSessions: presentSessionManager
            )
            applicationDelegate.onCloseTerminalRequested = { [weak commandRouter] in
                commandRouter?.closeTerminal()
            }
            applicationDelegate.onCloseWindowRequested = { [weak windowCloseRequester] in
                windowCloseRequester?.requestClose()
            }
            applicationDelegate.onTerminationRequested = { [weak workspace] completion in
                guard let workspace else {
                    completion(true)
                    return
                }
                workspace.requestWorkspaceShutdown(.application, completion: completion)
            }
        }
        .onDisappear {
            workspace.newTerminalRequest = nil
            commandRouter.detach(from: workspace)
            workspace.cleanupAllSessions()
        }
        .sheet(isPresented: $isSessionManagerPresented) {
            SessionManagerView(store: profileStore)
        }
        .sheet(item: $editorRoute) { route in
            SessionProfileEditorView(
                store: profileStore,
                profile: route.profile,
                initialKind: route.kind
            )
        }
        .alert(
            item: $workspace.activeAlert,
            content: workspaceAlert
        )
        .background {
            WindowLifecycleBridge(
                onCloseRequested: { [weak workspace] completion in
                    guard let workspace else {
                        completion(true)
                        return
                    }
                    workspace.requestWorkspaceShutdown(.window, completion: completion)
                },
                requester: windowCloseRequester
            )
            .frame(width: 0, height: 0)
        }
    }

    private var savedSessionsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Button {
                presentSessionManager()
            } label: {
                Label("Saved Sessions", systemImage: "rectangle.stack")
            }
            .buttonStyle(.plain)
            LabeledContent("Profiles", value: profileCountValue)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Saved terminal sessions")
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let session = workspace.selectedSession {
            TerminalPane(session: session)
                .id(session.sessionID)
        } else {
            emptyTerminalSurface
        }
    }

    @ViewBuilder
    private var emptyTerminalSurface: some View {
        switch profileStore.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading saved sessions…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error:
            ContentUnavailableView {
                Label("Saved Sessions Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(profileStore.lastFailure?.userMessage ?? "XMterm couldn’t load saved sessions.")
            } actions: {
                Button("Try Again") {
                    Task { await retryProfileLoad() }
                }
                Button("Manage Sessions…") {
                    presentSessionManager()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .recoveryRequired:
            SessionProfileRecoveryView(store: profileStore, compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .content where profileStore.profiles.isEmpty:
            ContentUnavailableView {
                Label("No Saved Sessions", systemImage: "tray")
            } description: {
                Text("Create a local or SSH profile. XMterm will not silently recreate deleted defaults.")
            } actions: {
                Button("New Local Session") {
                    presentEditor(.local)
                }
                Button("New SSH Session") {
                    presentEditor(.ssh)
                }
                Button("Manage Sessions…") {
                    presentSessionManager()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .content:
            ContentUnavailableView {
                Label("No Terminal Open", systemImage: "terminal")
            } description: {
                Text("Choose a saved session, or press Command-T to open the first saved login-shell profile.")
            } actions: {
                Button("Choose Session…") {
                    presentSessionPicker()
                }
                if defaultLocalProfileID != nil {
                    Button("Open Default Local Session") {
                        requestDefaultTerminal()
                    }
                    .keyboardShortcut("t", modifiers: .command)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var visibleProfileFailure: SessionProfileStoreFailure? {
        guard profileStore.state == .content else { return nil }
        return profileStore.lastFailure
    }

    private var profileCountValue: String {
        switch profileStore.state {
        case .loading:
            "Loading…"
        case .content:
            String(profileStore.profiles.count)
        case .recoveryRequired:
            "Recovery required"
        case .error:
            "Unavailable"
        }
    }

    private var defaultLocalProfileID: SessionProfileID? {
        SessionProfileLaunchPolicy.defaultLocalProfileID(in: profileStore.collection)
    }

    @MainActor
    private func beginProfileWorkflowIfNeeded() async {
        guard !didBeginProfileWorkflow else { return }
        didBeginProfileWorkflow = true
        if profileStore.state == .loading {
            await profileStore.load()
        }
        guard workspace.tabs.isEmpty,
              profileStore.state == .content,
              let defaultLocalProfileID else { return }
        _ = await launchProfile(defaultLocalProfileID)
    }

    @MainActor
    private func retryProfileLoad() async {
        await profileStore.load()
        guard workspace.tabs.isEmpty,
              profileStore.state == .content,
              let defaultLocalProfileID else { return }
        _ = await launchProfile(defaultLocalProfileID)
    }

    @MainActor
    private func launchProfile(
        _ id: SessionProfileID,
        onRuntimePublished: @MainActor () -> Void = {}
    ) async -> Bool {
        await SessionProfileLaunchCoordinator(
            profileStore: profileStore,
            workspace: workspace
        ).launch(id, onRuntimePublished: onRuntimePublished)
    }

    private func requestDefaultTerminal() {
        Task { @MainActor in
            guard let defaultLocalProfileID else {
                presentSessionPicker()
                return
            }
            _ = await launchProfile(defaultLocalProfileID)
        }
    }

    private func presentSessionPicker() {
        isSessionPickerPresented = true
    }

    private func presentSessionManager() {
        isSessionPickerPresented = false
        Task { @MainActor in
            await Task.yield()
            isSessionManagerPresented = true
        }
    }

    private func presentEditor(_ kind: SessionProfileDraftKind) {
        isSessionPickerPresented = false
        profileStore.clearFailure()
        Task { @MainActor in
            await Task.yield()
            editorRoute = EditorRoute(profile: nil, kind: kind)
        }
    }

    private func presentEditor(_ profile: SessionProfile) {
        isSessionPickerPresented = false
        Task { @MainActor in
            await Task.yield()
            editorRoute = EditorRoute(
                profile: profile,
                kind: profileDraftKind(profile)
            )
        }
    }

    private func profileDraftKind(_ profile: SessionProfile) -> SessionProfileDraftKind {
        switch profile.configuration {
        case .local: .local
        case .ssh: .ssh
        }
    }

    private func workspaceAlert(_ alert: TerminalWorkspaceAlert) -> Alert {
        switch alert {
        case let .close(prompt):
            let presentation = TerminalPresentationPolicy.closePresentation(for: prompt)
            return Alert(
                title: Text(presentation.title),
                message: Text(presentation.message),
                primaryButton: .destructive(Text(presentation.confirmButtonTitle)) {
                    workspace.confirmClose(prompt)
                },
                secondaryButton: .cancel {
                    workspace.dismissWorkspaceAlert()
                }
            )
        case let .shutdown(prompt):
            let title = prompt.scope == .window ? "Close this XMterm window?" : "Quit XMterm?"
            let buttonTitle = prompt.scope == .window ? "Close Window" : "Quit XMterm"
            return Alert(
                title: Text(title),
                message: Text(TerminalPresentationPolicy.shutdownMessage(for: prompt)),
                primaryButton: .destructive(Text(buttonTitle)) {
                    workspace.confirmWorkspaceShutdown(prompt)
                },
                secondaryButton: .cancel {
                    workspace.dismissWorkspaceAlert()
                }
            )
        case let .error(_, message):
            return Alert(
                title: Text("XMterm could not complete that action"),
                message: Text(message),
                dismissButton: .default(Text("OK")) {
                    workspace.dismissWorkspaceAlert()
                }
            )
        }
    }
}
