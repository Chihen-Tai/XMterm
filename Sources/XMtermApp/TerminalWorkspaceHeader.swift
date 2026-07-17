import SwiftUI
import XMtermCore

struct TerminalWorkspaceHeader: View {
    let tabs: [TerminalTab]
    let selectedTabID: TerminalTab.ID?
    let select: (TerminalTab.ID) -> Void
    let close: (TerminalTab.ID) -> Void
    @Binding var isSessionPickerPresented: Bool
    let profileStore: SessionProfileStore
    let launchProfile: (
        SessionProfileID,
        @MainActor () -> Void
    ) async -> Bool
    let createProfile: (SessionProfileDraftKind) -> Void
    let editProfile: (SessionProfile) -> Void
    let manageProfiles: () -> Void
    let restoreTerminalFocus: () -> Void
    let canCreate: Bool

    private let layoutPolicy = TerminalTabStripLayoutPolicy()

    var body: some View {
        GeometryReader { geometry in
            let metrics = layoutPolicy.metrics(
                availableWidth: geometry.size.width,
                tabCount: tabs.count
            )

            HStack(spacing: 0) {
                TerminalTabStrip(
                    tabs: tabs,
                    selectedTabID: selectedTabID,
                    select: select,
                    close: close,
                    isSessionPickerPresented: $isSessionPickerPresented,
                    profileStore: profileStore,
                    launchProfile: launchProfile,
                    createProfile: createProfile,
                    editProfile: editProfile,
                    manageProfiles: manageProfiles,
                    restoreTerminalFocus: restoreTerminalFocus,
                    canCreate: canCreate,
                    metrics: metrics
                )
                .frame(width: metrics.stripWidth, alignment: .leading)

                Spacer(minLength: layoutPolicy.toolbarSeparation)
            }
        }
        .frame(height: 38)
        .background(.bar)
    }
}
