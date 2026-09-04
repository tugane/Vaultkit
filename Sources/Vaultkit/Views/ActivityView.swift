import SwiftUI
import TuganeDesign

/// What is running now, and what will start again after a reboot.
struct ActivityView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    private var flagged: [ActivityItem] { store.activity.filter { !$0.reasons.isEmpty } }
    private var quiet: [ActivityItem] { store.activity.filter { $0.reasons.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Activity") {
                if store.activityRunning {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Look again") {
                        Task { await store.refreshActivity() }
                    }
                }
            }

            Text(summary)
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.activity.isEmpty {
                        EmptyState(symbol: "waveform",
                                   title: "Nothing to show yet",
                                   message: "Vaultkit lists processes running code given on the command line, anything piping a download into a shell, and every third-party item that starts itself at login.")
                            .frame(height: 220)
                    }
                    if !flagged.isEmpty {
                        SectionLabel("Worth a look").padding(.top, 4).padding(.bottom, 4)
                        ForEach(flagged) { ActivityRow(item: $0) }
                    }
                    if !quiet.isEmpty {
                        SectionLabel("Starts automatically").padding(.top, 16).padding(.bottom, 4)
                        Text("Third-party login and system items. Apple's own are not listed: they live on the signed, read-only system volume.")
                            .font(.system(size: 12))
                            .foregroundStyle(p.label3)
                            .padding(.bottom, 6)
                        ForEach(quiet) { ActivityRow(item: $0) }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(flagged.isEmpty ? "Nothing flagged" : "\(plural(flagged.count, "item")) worth a look")
        parts.append("\(plural(quiet.count, "background item")) listed")
        if let at = store.activityCheckedAt {
            parts.append("checked \(ScannerView.relative(at))")
        }
        parts.append("read only, nothing is ever stopped for you")
        return parts.joined(separator: " · ")
    }
}

struct ActivityRow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    let item: ActivityItem

    private var color: Color {
        switch item.severity {
        case .critical: p.red
        case .warning: p.amber
        case .info: p.label3
        }
    }
    private var symbol: String {
        switch item.kind {
        case .process: "bolt.horizontal.circle.fill"
        case .agent: "person.badge.clock.fill"
        case .daemon: "gearshape.2.fill"
        case .cron: "calendar.badge.clock"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(item.kind.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(p.label3)
                    Text(item.detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(p.label3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.title)
                    .font(.system(size: 12.5).monospaced())
                    .foregroundStyle(p.label)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(item.reasons, id: \.self) { reason in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .medium))
                        Text(reason).font(.system(size: 12.5))
                    }
                    .foregroundStyle(item.severity == .critical ? p.redText : p.amberText)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                LinkButton("Copy", color: p.label2, hoverColor: p.label,
                           font: .system(size: 12.5, weight: .medium)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.title, forType: .string)
                }
                if let path = item.path {
                    LinkButton("Reveal", color: p.label2, hoverColor: p.label,
                               font: .system(size: 12.5, weight: .medium)) {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}
