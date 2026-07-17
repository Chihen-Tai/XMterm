import SwiftUI

struct SessionProfileFailureBanner: View {
    let failure: SessionProfileStoreFailure
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(failure.userMessage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss saved-session message")
            .accessibilityLabel("Dismiss saved-session message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SessionProfileRecoveryView: View {
    let store: SessionProfileStore
    let compact: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(compact ? .title2 : .largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Saved Sessions Need Recovery")
                .font(compact ? .headline : .title2)
            Text(recoveryDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let failure = store.lastFailure {
                SessionProfileFailureBanner(
                    failure: failure,
                    dismiss: store.clearFailure
                )
                .frame(maxWidth: 520)
            }
            if store.isMutating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving recovery…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Button("Use Recovered Profiles") {
                    Task { _ = await store.useRecoveredProfiles() }
                }
                Button("Reset to Defaults") {
                    Task { _ = await store.resetToDefaults() }
                }
            }
            .disabled(store.isMutating)
        }
        .padding(compact ? 12 : 24)
    }

    private var recoveryDescription: String {
        let rejectedCount = store.recovery?.issues.reduce(into: 0) { count, issue in
            if case .rejectedProfiles(let rejected) = issue {
                count += rejected
            }
        } ?? 0
        if rejectedCount > 0 {
            return "XMterm preserved the original file and recovered the valid profiles. \(rejectedCount) invalid profile\(rejectedCount == 1 ? " was" : "s were") excluded."
        }
        return "XMterm preserved the original file. Choose whether to keep the recoverable profiles or replace them with the built-in defaults."
    }
}
