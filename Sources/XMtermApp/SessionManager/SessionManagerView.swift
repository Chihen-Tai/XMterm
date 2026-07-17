import SwiftUI
import XMtermCore

struct SessionManagerView: View {
    let store: SessionProfileStore

    @Environment(\.dismiss) private var dismiss
    @State private var selection: SessionProfileID?
    @State private var editorRoute: EditorRoute?
    @State private var deletionCandidate: SessionProfile?
    @FocusState private var profileListFocused: Bool

    private struct EditorRoute: Identifiable {
        let id = UUID()
        let profile: SessionProfile?
        let initialKind: SessionProfileDraftKind
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Saved Sessions")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()

            Divider()

            managerContent

            Divider()

            HStack {
                if store.isMutating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving changes…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if store.isValidatingLaunch {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating session…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 500)
        .defaultFocus($profileListFocused, true)
        .onAppear {
            stabilizeSelection()
        }
        .onChange(of: store.collection) { _, _ in
            stabilizeSelection()
        }
        .sheet(item: $editorRoute) { route in
            SessionProfileEditorView(
                store: store,
                profile: route.profile,
                initialKind: route.initialKind
            )
        }
        .alert(item: $deletionCandidate) { profile in
            Alert(
                title: Text("Delete “\(profile.name)”?"),
                message: Text(
                    "Existing terminal tabs using this profile will remain open.\nThe saved profile will be removed."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    delete(profile)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private var managerContent: some View {
        switch store.state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading saved sessions…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error:
            ContentUnavailableView {
                Label("Saved Sessions Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(store.lastFailure?.userMessage ?? "XMterm couldn’t load saved sessions.")
            } actions: {
                Button("Try Again") {
                    Task { await store.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .recoveryRequired:
            SessionProfileRecoveryView(store: store, compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .content:
            contentManager
        }
    }

    @ViewBuilder
    private var contentManager: some View {
        VStack(spacing: 0) {
            if let failure = store.lastFailure {
                SessionProfileFailureBanner(
                    failure: failure,
                    dismiss: store.clearFailure
                )
                .padding(10)
            }

            if store.profiles.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView {
                        Label("No Saved Sessions", systemImage: "tray")
                    } description: {
                        Text("Create a local or SSH profile. An initialized empty list will remain empty after restart.")
                    }
                    HStack {
                        Button("New Local Session") {
                            presentNew(.local)
                        }
                        Button("New SSH Session") {
                            presentNew(.ssh)
                        }
                    }
                    .disabled(!store.canMutateProfiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    profileList
                        .frame(minWidth: 260, idealWidth: 300)
                    profileDetail
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                managerToolbar
            }
        }
    }

    private var profileList: some View {
        List(selection: $selection) {
            ForEach(store.profiles) { profile in
                profileRow(profile)
                    .tag(profile.id)
                    .contextMenu {
                        Button("Edit") {
                            selection = profile.id
                            presentEdit(profile)
                        }
                        .disabled(!store.canMutateProfiles)
                        .onAppear {
                            selection = profile.id
                        }
                        Button("Duplicate") {
                            selection = profile.id
                            duplicate(profile)
                        }
                        .disabled(!store.canMutateProfiles)
                        Button(profile.favorite ? "Remove from Favorites" : "Add to Favorites") {
                            selection = profile.id
                            toggleFavorite(profile)
                        }
                        .disabled(!store.canMutateProfiles)
                        Divider()
                        Button("Delete", role: .destructive) {
                            selection = profile.id
                            deletionCandidate = profile
                        }
                        .disabled(!store.canMutateProfiles)
                    }
            }
        }
        .focused($profileListFocused)
        .accessibilityLabel("Saved sessions")
    }

    private func profileRow(_ profile: SessionProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: profileIcon(profile))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .lineLimit(1)
                Text(profileSummary(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if profile.favorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
        }
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        toggleFavorite(profile)
                    } label: {
                        Label(
                            profile.favorite ? "Favorite" : "Not Favorite",
                            systemImage: profile.favorite ? "star.fill" : "star"
                        )
                    }
                    .disabled(!store.canMutateProfiles)
                }

                LabeledContent("Type", value: profileType(profile))
                LabeledContent("Launch", value: profileSummary(profile))
                if let lastOpenedAt = profile.lastOpenedAt {
                    LabeledContent(
                        "Last opened",
                        value: lastOpenedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                } else {
                    LabeledContent("Last opened", value: "Never")
                }

                Text("Editing or deleting this saved template does not alter terminals that are already open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(20)
        } else {
            ContentUnavailableView("Select a Saved Session", systemImage: "sidebar.left")
        }
    }

    private var managerToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Local Session") {
                    presentNew(.local)
                }
                Button("New SSH Session") {
                    presentNew(.ssh)
                }
            } label: {
                Label("Add", systemImage: "plus")
            }

            Button("Edit") {
                if let selectedProfile { presentEdit(selectedProfile) }
            }
            .disabled(selectedProfile == nil)

            Button("Duplicate") {
                if let selectedProfile { duplicate(selectedProfile) }
            }
            .disabled(selectedProfile == nil)

            Button(selectedProfile?.favorite == true ? "Unfavorite" : "Favorite") {
                if let selectedProfile { toggleFavorite(selectedProfile) }
            }
            .disabled(selectedProfile == nil)

            Spacer()

            Button("Delete", role: .destructive) {
                deletionCandidate = selectedProfile
            }
            .disabled(selectedProfile == nil)
        }
        .padding(10)
        .disabled(!store.canMutateProfiles)
    }

    private var selectedProfile: SessionProfile? {
        guard let selection else { return nil }
        return store.profiles.first { $0.id == selection }
    }

    private func stabilizeSelection() {
        if selection == nil,
           case let .pathValidation(failureProfileID?, _)? = store.lastFailure,
           store.profiles.contains(where: { $0.id == failureProfileID }) {
            selection = failureProfileID
            return
        }
        guard selection.flatMap({ id in store.profiles.first { $0.id == id } }) == nil else {
            return
        }
        selection = store.profiles.first?.id
    }

    private func presentNew(_ kind: SessionProfileDraftKind) {
        store.clearFailure()
        editorRoute = EditorRoute(profile: nil, initialKind: kind)
    }

    private func presentEdit(_ profile: SessionProfile) {
        selection = profile.id
        editorRoute = EditorRoute(profile: profile, initialKind: profileDraftKind(profile))
    }

    private func duplicate(_ profile: SessionProfile) {
        Task { _ = await store.duplicate(id: profile.id) }
    }

    private func toggleFavorite(_ profile: SessionProfile) {
        Task { _ = await store.setFavorite(!profile.favorite, for: profile.id) }
    }

    private func delete(_ profile: SessionProfile) {
        Task { @MainActor in
            if await store.delete(id: profile.id) {
                if selection == profile.id {
                    selection = nil
                    stabilizeSelection()
                }
            }
        }
    }

    private func profileDraftKind(_ profile: SessionProfile) -> SessionProfileDraftKind {
        switch profile.configuration {
        case .local: .local
        case .ssh: .ssh
        }
    }

    private func profileIcon(_ profile: SessionProfile) -> String {
        switch profile.configuration {
        case .local: "desktopcomputer"
        case .ssh: "network"
        }
    }

    private func profileType(_ profile: SessionProfile) -> String {
        switch profile.configuration {
        case .local: "Local"
        case .ssh: "SSH"
        }
    }

    private func profileSummary(_ profile: SessionProfile) -> String {
        switch profile.configuration {
        case .local(let local):
            local.useLoginShell ? "Login shell" : "Custom shell"
        case let .ssh(.direct(host, port, user, _)):
            "\(user)@\(host):\(port)"
        case let .ssh(.configAlias(alias)):
            "SSH config alias \(alias)"
        }
    }
}
