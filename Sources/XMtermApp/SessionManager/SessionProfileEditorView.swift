import SwiftUI
import XMtermCore

struct SessionProfileEditorView: View {
    let store: SessionProfileStore
    let profile: SessionProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: SessionProfileDraft
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case name
        case host
        case alias
        case shell
    }

    init(
        store: SessionProfileStore,
        profile: SessionProfile? = nil,
        initialKind: SessionProfileDraftKind = .local
    ) {
        self.store = store
        self.profile = profile
        _draft = State(
            initialValue: profile.map(SessionProfileEditorDrafts.editing)
                ?? SessionProfileEditorDrafts.newProfile(kind: initialKind)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(profile == nil ? "New Saved Session" : "Edit Saved Session")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Profile") {
                    TextField("Name", text: $draft.name)
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("session-profile-name")
                    fieldMessages(for: .name)

                    Picker("Type", selection: $draft.kind) {
                        Text("Local").tag(SessionProfileDraftKind.local)
                        Text("SSH").tag(SessionProfileDraftKind.ssh)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Favorite", isOn: $draft.favorite)
                }

                switch draft.kind {
                case .local:
                    localFields
                case .ssh:
                    sshFields
                }

                if let failure = visibleFailure {
                    Section {
                        SessionProfileFailureBanner(
                            failure: failure,
                            dismiss: store.clearFailure
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if store.isMutating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 540)
        .frame(minHeight: 520)
        .defaultFocus($focusedField, .name)
        .onChange(of: draft) { _, _ in
            store.clearFailure()
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    @ViewBuilder
    private var localFields: some View {
        Section("Local Shell") {
            Picker("Launch mode", selection: $draft.local.mode) {
                Text("Login Shell").tag(LocalSessionProfileDraftMode.loginShell)
                Text("Custom Shell").tag(LocalSessionProfileDraftMode.customShell)
            }
            .pickerStyle(.segmented)

            if draft.local.mode == .customShell {
                TextField("Shell executable path", text: $draft.local.shellPath)
                    .focused($focusedField, equals: .shell)
                    .accessibilityIdentifier("session-profile-shell-path")
                fieldMessages(for: .shellPath)
            } else {
                Text("XMterm will use the account login shell and preserve login-shell behavior.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField(
                "Working directory (optional)",
                text: $draft.local.workingDirectory
            )
            .accessibilityIdentifier("session-profile-working-directory")
            fieldMessages(for: .workingDirectory)
        }
    }

    @ViewBuilder
    private var sshFields: some View {
        Section("SSH") {
            Picker("Connection", selection: $draft.ssh.mode) {
                Text("Direct Host").tag(SSHSessionProfileDraftMode.direct)
                Text("SSH Config Alias").tag(SSHSessionProfileDraftMode.configAlias)
            }
            .pickerStyle(.segmented)

            switch draft.ssh.mode {
            case .direct:
                TextField("Host", text: $draft.ssh.host)
                    .focused($focusedField, equals: .host)
                    .accessibilityIdentifier("session-profile-host")
                fieldMessages(for: .host)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("User", text: $draft.ssh.user)
                            .accessibilityIdentifier("session-profile-user")
                        fieldMessages(for: .user)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Port", text: $draft.ssh.port)
                            .frame(width: 100)
                            .accessibilityIdentifier("session-profile-port")
                        fieldMessages(for: .port)
                    }
                }

                TextField(
                    "Identity file path (optional)",
                    text: $draft.ssh.identityFilePath
                )
                .accessibilityIdentifier("session-profile-identity-path")
                fieldMessages(for: .identityFilePath)

            case .configAlias:
                TextField("SSH config alias", text: $draft.ssh.sshConfigAlias)
                    .focused($focusedField, equals: .alias)
                    .accessibilityIdentifier("session-profile-alias")
                fieldMessages(for: .sshConfigAlias)
                Text("XMterm passes this alias directly to system OpenSSH and does not reimplement SSH config resolution.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var structuralIssues: [SessionProfileValidationIssue] {
        SessionProfileEditorDrafts.structuralIssues(for: draft)
    }

    private var canSave: Bool {
        structuralIssues.isEmpty && store.canMutateProfiles
    }

    private var visibleFailure: SessionProfileStoreFailure? {
        guard let failure = store.lastFailure else { return nil }
        if case let .pathValidation(failureProfileID, _) = failure,
           failureProfileID != profile?.id {
            return nil
        }
        return failure
    }

    @ViewBuilder
    private func fieldMessages(for field: SessionProfileValidationField) -> some View {
        let structural = structuralIssues.filter { $0.field == field }
        let pathIssues = pathIssues(for: field)

        ForEach(Array(structural.enumerated()), id: \.offset) { _, issue in
            Text(SessionProfileEditorDrafts.message(for: issue))
                .font(.caption)
                .foregroundStyle(.red)
        }
        ForEach(Array(pathIssues.enumerated()), id: \.offset) { _, issue in
            Text(SessionProfileEditorDrafts.message(for: issue))
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func pathIssues(
        for field: SessionProfileValidationField
    ) -> [SessionProfilePathIssue] {
        guard case let .pathValidation(failureProfileID, issues)? = store.lastFailure,
              failureProfileID == profile?.id else { return [] }
        return issues.filter { $0.field == field }
    }

    private func save() {
        guard canSave else { return }
        let draft = draft
        let profileID = profile?.id
        Task { @MainActor in
            let didSave: Bool
            if let profileID {
                didSave = await store.edit(id: profileID, with: draft)
            } else {
                didSave = await store.create(from: draft)
            }
            if didSave {
                dismiss()
            }
        }
    }
}
