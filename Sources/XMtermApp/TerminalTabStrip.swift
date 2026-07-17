import SwiftUI
import XMtermCore

struct TerminalTabStrip: View {
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
    let metrics: TerminalTabStripLayoutMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealGeneration = 0
    @State private var previousRevealRequest: TerminalTabRevealRequest?
    @State private var pickerLaunchSucceeded = false
    @FocusState private var newTerminalButtonFocused: Bool

    private let layoutPolicy = TerminalTabStripLayoutPolicy()
    private let revealSchedulingPolicy = TerminalTabRevealSchedulingPolicy()

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: layoutPolicy.leadingPadding)
                .frame(width: layoutPolicy.leadingPadding)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: layoutPolicy.interTabSpacing) {
                        ForEach(tabs) { tab in
                            terminalTab(tab)
                                .frame(width: metrics.tabWidth)
                                .id(tab.id)
                        }
                    }
                }
                .frame(width: metrics.viewportWidth)
                .task(id: revealRequest) {
                    await revealSelectedTab(using: proxy)
                }
            }
            .frame(width: metrics.viewportWidth)

            if !tabs.isEmpty {
                Spacer(minLength: layoutPolicy.newTabButtonGap)
                    .frame(width: layoutPolicy.newTabButtonGap)
            }

            newTerminalButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal tabs")
    }

    private var revealRequest: TerminalTabRevealRequest {
        TerminalTabRevealRequest(
            tabIDs: tabs.map(\.id),
            selectedTabID: selectedTabID,
            viewportWidth: metrics.viewportWidth
        )
    }

    private var tabListAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    private var newTerminalButton: some View {
        Button {
            pickerLaunchSucceeded = false
            isSessionPickerPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            width: layoutPolicy.newTabButtonWidth,
            height: layoutPolicy.newTabButtonWidth
        )
        .buttonStyle(.borderless)
        .focused($newTerminalButtonFocused)
        .disabled(!canCreate)
        .help("Choose a saved local or SSH session")
        .accessibilityLabel("New terminal")
        .accessibilityHint("Open the searchable saved-session picker")
        .accessibilityIdentifier("terminal-tab-strip-new-terminal")
        .popover(isPresented: $isSessionPickerPresented, arrowEdge: .bottom) {
            SessionPickerView(
                store: profileStore,
                launch: { profileID in
                    await launchProfile(profileID) {
                        pickerLaunchSucceeded = true
                        isSessionPickerPresented = false
                        Task { @MainActor in
                            await Task.yield()
                            restoreTerminalFocus()
                        }
                    }
                },
                createProfile: createProfile,
                editProfile: editProfile,
                manageProfiles: manageProfiles,
                dismiss: {
                    isSessionPickerPresented = false
                }
            )
        }
        .onChange(of: isSessionPickerPresented) { wasPresented, isPresented in
            if isPresented {
                pickerLaunchSucceeded = false
            } else if wasPresented, !pickerLaunchSucceeded {
                newTerminalButtonFocused = true
            }
        }
    }

    @MainActor
    private func revealSelectedTab(using proxy: ScrollViewProxy) async {
        let request = revealRequest
        let schedule = revealSchedulingPolicy.schedule(
            from: previousRevealRequest,
            to: request
        )
        previousRevealRequest = request
        revealGeneration += 1
        let generation = revealGeneration
        guard let target = request.targetTabID, let schedule else { return }

        do {
            try await Task.sleep(for: schedule.delay)
        } catch {
            return
        }
        guard !Task.isCancelled, generation == revealGeneration else { return }

        withAnimation(schedule.shouldAnimate ? tabListAnimation : nil) {
            proxy.scrollTo(target, anchor: .trailing)
        }
    }

    private func terminalTab(_ tab: TerminalTab) -> some View {
        HStack(spacing: 7) {
            Button {
                select(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: TerminalPresentationPolicy.statusSymbol(
                            kind: tab.kind,
                            lifecycle: tab.lifecycle
                        )
                    )
                        .foregroundStyle(statusColor(for: tab))
                        .accessibilityHidden(true)
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(TerminalPresentationPolicy.statusText(kind: tab.kind, lifecycle: tab.lifecycle))
            .accessibilityLabel(
                "\(tab.title), \(TerminalPresentationPolicy.statusText(kind: tab.kind, lifecycle: tab.lifecycle))"
            )
            .accessibilityAddTraits(tab.id == selectedTabID ? .isSelected : [])

            Button {
                close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 28, height: 28)
            }
            .frame(width: 28, height: 28)
            .buttonStyle(.plain)
            .help("Close \(tab.title)")
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            tab.id == selectedTabID
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                : .clear
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    tab.id == selectedTabID ? Color.accentColor.opacity(0.55) : .clear,
                    lineWidth: 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func statusColor(for tab: TerminalTab) -> Color {
        switch tab.lifecycle {
        case .running: tab.kind == .relaySSH ? .blue : .green
        case .failed: .orange
        case .idle, .starting, .closing, .exited: .secondary
        }
    }
}
