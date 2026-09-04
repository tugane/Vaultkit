import SwiftUI
import TuganeDesign

// MARK: - Scanner (UC12)

struct ScannerView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    private var mounted: [Organization] { store.organizations.filter { $0.vault == .mounted } }

    /// Findings grouped by "org/repo", worst first within each group.
    private var groups: [(key: String, items: [ScanFinding])] {
        Dictionary(grouping: store.scanFindings) { "\($0.orgName)/\($0.repo)" }
            .map { (key: $0.key, items: $0.value) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Scanner") {
                if store.scanRunning {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    PillButton(title: "Deep scan", role: .neutral, height: 30, hpad: 14,
                               font: .system(size: 12.5, weight: .medium)) {
                        Task { await store.runScan(deep: true) }
                    }
                    .help("Also read every JS-family source file, not only the files the campaign targets")
                    IconButton(symbol: "arrow.clockwise", help: "Re-check changed files now") {
                        Task { await store.runScan() }
                    }
                }
            }

            Text(statusLine)
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.bottom, 18)

            if mounted.isEmpty {
                EmptyState(
                    symbol: "lock.fill",
                    title: "Nothing to watch",
                    message: "The scanner reads mounted vaults only. Mount one and it gets a full pass, then changed files are re-checked every \(Int(AppStore.scanInterval / 60)) minutes for as long as it stays mounted."
                )
            } else if store.scanFindings.isEmpty {
                EmptyState(
                    symbol: "checkmark.shield.fill",
                    title: "No indicators found",
                    message: "Nothing in \(plural(mounted.count, "mounted vault")) matches the PolinRider indicator set (\(PolinRiderIndicators.version)). Not a clean bill of health — only the absence of what this scanner knows to look for."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.key) { group in
                            SectionLabel(group.key)
                                .padding(.top, 12).padding(.bottom, 4)
                            ForEach(group.items) { finding in
                                ScanFindingRow(finding: finding)
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        parts.append(mounted.isEmpty ? "No vault mounted"
                     : "Watching \(mounted.map(\.displayName).joined(separator: ", "))")
        if let r = store.scanReport {
            let ago = Self.relative(r.finishedAt)
            let what = r.deep ? "deep pass" : (r.full ? "full pass" : "changed files")
            parts.append("last \(what) \(ago) — \(plural(r.filesScanned, "file")) in \(plural(r.reposSeen, "repository"))")
        } else {
            parts.append("no pass yet")
        }
        if let next = store.nextScanAt, !mounted.isEmpty {
            parts.append("next in \(Self.until(next))")
        }
        parts.append("indicators \(PolinRiderIndicators.version)")
        return parts.joined(separator: " · ")
    }

    static func relative(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    static func until(_ date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        return s < 60 ? "under a minute" : "\(s / 60) min"
    }
}

struct ScanFindingRow: View {
    @Environment(\.palette) private var p
    let finding: ScanFinding

    private var color: Color { finding.severity == .critical ? p.red : p.amber }
    private var symbol: String {
        finding.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(finding.indicator).font(.system(size: 13.5, weight: .medium))
                Text(finding.path)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(p.label2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("matched: \(finding.evidence)")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(p.label3)
                Text(finding.remediation)
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.label2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            LinkButton("Reveal", color: p.label2, hoverColor: p.label,
                       font: .system(size: 12.5, weight: .medium)) {
                NSWorkspace.shared.selectFile(finding.absolutePath, inFileViewerRootedAtPath: "")
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}
