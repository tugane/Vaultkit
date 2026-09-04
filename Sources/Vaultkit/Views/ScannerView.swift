import SwiftUI
import TuganeDesign

// MARK: - Scanner (UC12)

struct ScannerView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    @State private var tab: Tab = .findings

    enum Tab: String, CaseIterable { case findings = "Findings", quarantine = "Quarantine", history = "History" }

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
                autoToggle
                if store.scanRunning {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    PillButton(title: "Deep Scan", role: .neutral, height: 30, hpad: 14,
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
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                ForEach(Tab.allCases, id: \.self) { t in
                    PillButton(title: tabTitle(t), role: tab == t ? .accent : .neutral, height: 30, hpad: 14,
                               font: .system(size: 12.5, weight: tab == t ? .semibold : .medium)) { tab = t }
                }
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .findings: findings
                    case .quarantine: quarantineList
                    case .history: historyList
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
    }

    private func tabTitle(_ t: Tab) -> String {
        switch t {
        case .findings: store.scanFindings.isEmpty ? "Findings" : "Findings \(store.scanFindings.count)"
        case .quarantine: store.quarantine.isEmpty ? "Quarantine" : "Quarantine \(store.quarantine.count)"
        case .history: "History"
        }
    }

    private var autoToggle: some View {
        Button { store.autoQuarantine.toggle() } label: {
            HStack(spacing: 8) {
                CheckBox(on: store.autoQuarantine)
                Text("Auto-quarantine")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(p.label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help("Act on critical hits the moment they are found: cut appended loaders back to the real config, move artifacts and malicious packages into the vault's quarantine")
        .padding(.trailing, 6)
    }

    // MARK: findings

    @ViewBuilder
    private var findings: some View {
        LastScanCard()
        if mounted.isEmpty {
            note(symbol: "lock.fill", title: "Nothing to watch",
                 text: "The Scanner reads mounted vaults only. Mount one and it gets a full pass, then changed files are re-checked every \(Int(AppStore.scanInterval / 60)) minutes for as long as it stays mounted.")
        } else if store.scanFindings.isEmpty {
            note(symbol: "checkmark.shield.fill", title: "No indicators found",
                 text: "Nothing in \(plural(mounted.count, "mounted vault")) matches the PolinRider indicator set. Not a clean bill of health — only the absence of what this Scanner knows to look for.")
        } else {
            ForEach(groups, id: \.key) { group in
                SectionLabel(group.key)
                    .padding(.top, 12).padding(.bottom, 4)
                ForEach(group.items) { finding in
                    ScanFindingRow(finding: finding) { Task { await store.fix(finding) } }
                }
            }
        }
    }

    // MARK: quarantine

    @ViewBuilder
    private var quarantineList: some View {
        Text("Quarantine lives inside each vault at .vaultkit/quarantine, so held bytes stay encrypted at rest and never leave the organization. Originals are purged automatically \(plural(Int(AppStore.quarantineTTL / 60), "minute")) after they are set aside — restore inside that window is the only way to get a file back. A locked vault's quarantine is untouched until it is mounted again.")
            .font(.system(size: 12.5))
            .foregroundStyle(p.label2)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
        if store.quarantine.isEmpty {
            note(symbol: "archivebox", title: "Quarantine is empty",
                 text: mounted.isEmpty ? "Quarantine is per vault and only visible while that vault is mounted."
                                       : "Nothing has been set aside in \(plural(mounted.count, "mounted vault")).")
        } else {
            ForEach(store.quarantine) { item in
                QuarantineRow(item: item,
                              restore: { store.restore(item) },
                              purge: { store.purge(item) })
            }
        }
    }

    // MARK: history

    @ViewBuilder
    private var historyList: some View {
        if store.history.actions.isEmpty && store.history.scans.isEmpty {
            note(symbol: "clock", title: "No history yet",
                 text: "Every pass and every action is recorded here — what was scanned, what was found, what was cut, moved, restored or purged.")
        } else {
            if !store.history.actions.isEmpty {
                SectionLabel("Actions").padding(.top, 4).padding(.bottom, 4)
                ForEach(store.history.actions.prefix(100)) { a in ActionRow(action: a) }
            }
            if !store.history.scans.isEmpty {
                SectionLabel("Passes").padding(.top, 16).padding(.bottom, 4)
                ForEach(store.history.scans.prefix(100)) { e in ScanEventRow(event: e) }
            }
        }
    }

    // MARK: bits

    private func note(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Mascot(symbol: symbol, tint: p.label3).frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.label2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(p.card, radius: 12)
    }

    private var statusLine: String {
        var parts: [String] = []
        parts.append(mounted.isEmpty ? "No vault mounted"
                     : "Watching \(mounted.map(\.displayName).joined(separator: ", "))")
        if let r = store.scanReport {
            parts.append("last pass \(Self.relative(r.finishedAt))")
        } else {
            parts.append("no pass yet")
        }
        if let next = store.nextScanAt, !mounted.isEmpty {
            parts.append("next in \(Self.until(next))")
        }
        parts.append(store.autoQuarantine ? "acting on hits automatically" : "report only")
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

    static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Last pass details

struct LastScanCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last pass").font(.system(size: 14, weight: .semibold))
                Spacer()
                LinkButton("Indicator source", color: p.label3, hoverColor: p.label,
                           font: .system(size: 12, weight: .medium)) {
                    NSWorkspace.shared.open(URL(string: PolinRiderIndicators.source)!)
                }
            }
            if let r = store.scanReport {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading, spacing: 10) {
                    stat("Mode", r.mode)
                    stat("Started", ScannerView.when.string(from: r.startedAt))
                    stat("Took", Self.ms(r.duration))
                    stat("Files read", "\(r.filesScanned)")
                    stat("Repositories", "\(r.reposSeen)")
                    stat("Indicators", PolinRiderIndicators.version)
                }
                if !r.orgs.isEmpty {
                    Divider().overlay(p.sep2)
                    ForEach(r.orgs, id: \.self) { o in
                        HStack(spacing: 8) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(p.orange)
                                .frame(width: 16)
                            Text(o.name).font(.system(size: 12.5, weight: .medium))
                            Text("\(plural(o.repos, "repository")) · \(plural(o.files, "file")) read · \(o.findings == 0 ? "clean" : plural(o.findings, "hit"))")
                                .font(.system(size: 12.5))
                                .foregroundStyle(o.findings == 0 ? p.label2 : p.redText)
                            Spacer()
                        }
                    }
                }
            } else {
                Text("No pass yet.").font(.system(size: 12.5)).foregroundStyle(p.label2)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(p.card, radius: 12)
        .padding(.bottom, 8)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(p.label3)
            Text(value).font(.system(size: 12.5).monospacedDigit())
        }
    }

    static func ms(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int(t * 1000)) ms" : String(format: "%.1f s", t)
    }
}

// MARK: - Rows

struct ScanFindingRow: View {
    @Environment(\.palette) private var p
    let finding: ScanFinding
    let onFix: () -> Void

    private var color: Color { finding.severity == .critical ? p.red : p.amber }
    private var symbol: String {
        finding.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
    private var fixTitle: String? {
        switch finding.fix {
        case .clean: "Clean"
        case .quarantine: "Quarantine"
        case .dropDependency: "Remove Dependency"
        case .dropGitignoreLine: "Remove Line"
        case .manual: nil
        }
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
            HStack(spacing: 10) {
                LinkButton("Reveal", color: p.label2, hoverColor: p.label,
                           font: .system(size: 12.5, weight: .medium)) {
                    NSWorkspace.shared.selectFile(finding.absolutePath, inFileViewerRootedAtPath: "")
                }
                if let fixTitle {
                    PillButton(title: fixTitle, role: finding.severity == .critical ? .destructive : .accent,
                               height: 30, hpad: 14, font: .system(size: 12.5, weight: .medium), action: onFix)
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}

struct QuarantineRow: View {
    @Environment(\.palette) private var p
    let item: QuarantineItem
    let restore: () -> Void
    let purge: () -> Void

    /// How long is left to restore this. Recomputed on every store refresh.
    private var expiry: String {
        let left = Int(AppStore.quarantineTTL - Date().timeIntervalSince(item.date))
        if left <= 0 { return "purging now" }
        if left < 60 { return "purges in \(left)s — restore now or it is gone" }
        return "purges in \(plural(left / 60 + 1, "minute"))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.kind == .cleaned ? "scissors" : "archivebox.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(p.accent)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.indicator).font(.system(size: 13.5, weight: .medium))
                Text("\(item.orgName)/\(item.originalPath)")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(p.label2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(detailLine(ScannerView.when.string(from: item.date),
                                item.kind == .cleaned ? "original of a cleaned file" : "moved whole",
                                "\(item.bytes) bytes",
                                item.sha256.isEmpty ? nil : "sha256 \(item.sha256.prefix(12))"))
                    .font(.system(size: 12))
                    .foregroundStyle(p.label3)
                Text(expiry)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.amberText)
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                LinkButton("Restore", color: p.label2, hoverColor: p.label,
                           font: .system(size: 12.5, weight: .medium), action: restore)
                LinkButton("Purge", color: p.label3, hoverColor: p.redText,
                           font: .system(size: 12.5, weight: .medium), action: purge)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}

struct ActionRow: View {
    @Environment(\.palette) private var p
    let action: ActionEvent

    private var symbol: String {
        switch action.kind {
        case .cleaned: "scissors"
        case .quarantined: "archivebox.fill"
        case .restored: "arrow.uturn.backward"
        case .purged: "trash"
        case .manual: "hand.raised.fill"
        }
    }
    private var color: Color {
        switch action.kind {
        case .cleaned, .quarantined: p.green
        case .restored: p.accent
        case .purged: p.label3
        case .manual: p.amber
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(action.kind.rawValue.capitalized) — \(action.indicator)")
                    .font(.system(size: 13, weight: .medium))
                Text("\(action.orgName)/\(action.path)")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(p.label2)
                    .lineLimit(1).truncationMode(.middle)
                Text(action.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(p.label3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(ScannerView.when.string(from: action.date))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(p.label3)
                .fixedSize()
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}

struct ScanEventRow: View {
    @Environment(\.palette) private var p
    let event: ScanEvent

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: event.hits == 0 ? "checkmark.circle" : "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(event.hits == 0 ? p.label3 : p.red)
                .frame(width: 24)
            Text(event.mode.capitalized).font(.system(size: 13, weight: .medium)).frame(width: 110, alignment: .leading)
            Text(event.orgs.isEmpty ? "no vault mounted" : event.orgs.joined(separator: ", "))
                .font(.system(size: 12.5)).foregroundStyle(p.label2)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(event.files) files · \(event.repos) repos · \(event.hits == 0 ? "clean" : plural(event.hits, "hit")) · \(LastScanCard.ms(event.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(event.hits == 0 ? p.label3 : p.redText)
                .fixedSize()
            Text(ScannerView.when.string(from: event.date))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(p.label3)
                .fixedSize()
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}
