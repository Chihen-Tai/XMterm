import SwiftUI
import XMtermCore
import XMtermTerminal

struct TerminalPane: View {
    let session: TerminalSession

    var body: some View {
        ZStack(alignment: .bottom) {
            RetainedTerminalView(terminalView: session.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(
                    TerminalPresentationPolicy.terminalAccessibilityLabel(
                        launchSpecification: session.launchSpecification
                    )
                )
                .accessibilityHint(
                    TerminalPresentationPolicy.terminalAccessibilityHint(
                        kind: session.kind,
                        lifecycle: session.lifecycle
                    )
                )

            statusOverlay

        }
        .overlay(alignment: .bottomTrailing) {
            if session.hasNewOutputBelow {
                Button {
                    session.jumpToLatestOutput()
                } label: {
                    Label("New output", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Return to the latest terminal output")
                .accessibilityLabel("New output below. Jump to latest output")
                .padding(16)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert(
            item: Binding(
                get: { session.activeAlert },
                set: { value in
                    if value == nil { session.dismissAlert() }
                }
            )
        ) { alert in
            alertPresentation(for: alert)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch session.lifecycle {
        case .idle:
            Label(
                statusText,
                systemImage: TerminalPresentationPolicy.statusSymbol(
                    kind: session.kind,
                    lifecycle: session.lifecycle
                )
            )
                .statusBanner()
        case .starting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText + "…")
            }
            .statusBanner()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(statusText)
        case .closing:
            Label(statusText + "…", systemImage: "hourglass")
                .statusBanner()
        case .exited:
            Label(statusText, systemImage: "stop.circle")
                .statusBanner()
        case .failed:
            Label(statusText, systemImage: "exclamationmark.triangle.fill")
                .statusBanner()
        case .running:
            EmptyView()
        }
    }

    private var statusText: String {
        TerminalPresentationPolicy.statusText(kind: session.kind, lifecycle: session.lifecycle)
    }

    private func alertPresentation(for alert: TerminalSessionAlert) -> Alert {
        switch alert {
        case let .paste(prompt):
            let detail: String
            if prompt.containsControlCharacters {
                detail = "The clipboard contains control characters."
            } else {
                detail = "The clipboard contains \(prompt.lineCount) lines."
            }
            return Alert(
                title: Text("Paste potentially unsafe text?"),
                message: Text("\(detail) XMterm will send \(prompt.byteCount) UTF-8 bytes without adding Return or showing the clipboard content."),
                primaryButton: .default(Text("Paste")) {
                    session.resolvePasteAlert(approved: true)
                },
                secondaryButton: .cancel {
                    session.resolvePasteAlert(approved: false)
                }
            )
        case let .error(error):
            return Alert(
                title: Text("Terminal action unavailable"),
                message: Text(error.message),
                dismissButton: .default(Text("OK")) {
                    session.dismissAlert()
                }
            )
        }
    }
}

private extension View {
    func statusBanner() -> some View {
        self
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }
}
