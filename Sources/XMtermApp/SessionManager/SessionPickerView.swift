import SwiftUI
import XMtermCore

struct SessionPickerView: View {
    let store: SessionProfileStore
    let launch: (SessionProfileID) async -> Bool
    let createProfile: (SessionProfileDraftKind) -> Void
    let editProfile: (SessionProfile) -> Void
    let manageProfiles: () -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selectedProfileID: SessionProfileID?
    @State private var isLaunching = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            pickerContent

            Divider()

            HStack(spacing: 8) {
                Button {
                    createProfile(.local)
                } label: {
                    Label("New Local", systemImage: "desktopcomputer")
                }
                Button {
                    createProfile(.ssh)
                } label: {
                    Label("New SSH", systemImage: "network")
                }
                Spacer()
                Button("Manage Sessions…", action: manageProfiles)
            }
            .controlSize(.small)
            .padding(10)
            .disabled(store.state != .content || !store.canMutateProfiles)
        }
        .frame(width: 390)
        .onAppear {
            selectedProfileID = model.selectedProfileID
            searchFocused = true
        }
        .onChange(of: query) { _, newQuery in
            updateSelection(SessionPickerModel(
                collection: store.collection,
                query: newQuery,
                selectedProfileID: selectedProfileID
            ).selectedProfileID)
        }
        .onChange(of: store.collection) { _, newCollection in
            updateSelection(SessionPickerModel(
                collection: newCollection,
                query: query,
                selectedProfileID: selectedProfileID
            ).selectedProfileID)
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        switch store.state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading saved sessions…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)

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
            .frame(minHeight: 220)

        case .recoveryRequired:
            SessionProfileRecoveryView(store: store, compact: true)
                .frame(minHeight: 220)

        case .content:
            contentPicker
        }
    }

    @ViewBuilder
    private var contentPicker: some View {
        VStack(spacing: 8) {
            TextField("Search sessions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    launchSelection()
                }
                .onKeyPress(.upArrow) {
                    moveSelection(.previous)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(.next)
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .accessibilityIdentifier("session-picker-search")
                .padding(.horizontal, 10)
                .padding(.top, 10)

            if let failure = store.lastFailure {
                SessionProfileFailureBanner(
                    failure: failure,
                    dismiss: store.clearFailure
                )
                .padding(.horizontal, 10)

                if case let .pathValidation(failureProfileID, _) = failure,
                   let profile = selectedProfile,
                   failureProfileID == profile.id {
                    Button("Edit “\(profile.name)”…") {
                        editProfile(profile)
                    }
                    .controlSize(.small)
                    .disabled(!store.canMutateProfiles)
                    .accessibilityHint("Open the saved session editor with the unavailable path highlighted")
                }
            }

            if store.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Sessions", systemImage: "tray")
                } description: {
                    Text("Create a local or SSH profile to launch a terminal.")
                }
                .frame(minHeight: 190)
            } else if model.sections.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(minHeight: 190)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.sections) { section in
                                Text(section.kind.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 6)

                                ForEach(section.profileIDs, id: \.self) { id in
                                    if let profile = model.profile(id: id) {
                                        profileRow(profile)
                                            .id(profile.id)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: selectedProfileID) { _, selectedID in
                        guard let selectedID else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: 390)
            }
        }
    }

    private var model: SessionPickerModel {
        SessionPickerModel(
            collection: store.collection,
            query: query,
            selectedProfileID: selectedProfileID
        )
    }

    private var selectedProfile: SessionProfile? {
        guard let selectedProfileID else { return nil }
        return model.profile(id: selectedProfileID)
    }

    private func profileRow(_ profile: SessionProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                select(profile)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: profileIcon(profile))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .lineLimit(1)
                        Text(profileSubtitle(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isLaunching && selectedProfileID == profile.id {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    select(profile)
                    launchSelection()
                }
            )
            .accessibilityLabel("\(profile.name), \(profileSubtitle(profile))")
            .accessibilityHint("Select this session. Press Return or double-click to launch.")
            .accessibilityAddTraits(profile.id == model.selectedProfileID ? .isSelected : [])
            .accessibilityAction(named: "Launch") {
                select(profile)
                launchSelection()
            }

            Button {
                Task {
                    _ = await store.setFavorite(!profile.favorite, for: profile.id)
                }
            } label: {
                Image(systemName: profile.favorite ? "star.fill" : "star")
                    .foregroundStyle(profile.favorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!store.canMutateProfiles || isLaunching)
            .help(profile.favorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(
                profile.favorite ? "Remove \(profile.name) from favorites" : "Add \(profile.name) to favorites"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            profile.id == model.selectedProfileID
                ? Color.accentColor.opacity(0.16)
                : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 4)
    }

    private func select(_ profile: SessionProfile) {
        updateSelection(profile.id)
        searchFocused = true
    }

    private func updateSelection(_ newSelection: SessionProfileID?) {
        if selectedProfileID != newSelection,
           case .pathValidation = store.lastFailure {
            store.clearFailure()
        }
        selectedProfileID = newSelection
    }

    private func moveSelection(_ move: SessionPickerSelectionMove) {
        guard store.state == .content else { return }
        updateSelection(model.movingSelection(move).selectedProfileID)
    }

    private func launchSelection() {
        guard !isLaunching,
              store.canLaunchProfiles,
              let id = model.launchProfileID else { return }
        selectedProfileID = id
        isLaunching = true
        Task { @MainActor in
            _ = await launch(id)
            isLaunching = false
        }
    }

    private func profileIcon(_ profile: SessionProfile) -> String {
        switch profile.configuration {
        case .local: "desktopcomputer"
        case .ssh: "network"
        }
    }

    private func profileSubtitle(_ profile: SessionProfile) -> String {
        switch profile.configuration {
        case .local(let local):
            local.useLoginShell ? "Local login shell" : "Local custom shell"
        case let .ssh(.direct(host, port, user, _)):
            "\(user)@\(host):\(port)"
        case let .ssh(.configAlias(alias)):
            "SSH config alias \(alias)"
        }
    }
}
