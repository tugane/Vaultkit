import SwiftUI
import TuganeDesign

// MARK: - Dashboard: hero, organizations, then a strip of health tiles
//
// The organizations are where every action on this page lives, so they come
// straight after the statement they illustrate, and the whole grid must be on
// screen at the minimum window size (640pt) without scrolling. The page used
// to spend 228pt on a score card and an "at a glance" list between the two,
// most of which restated the headline, the cards and the sidebar badges.

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    @AppStorage("vk.theme") private var themeRaw = Theme.dark.rawValue

    private var theme: Theme { Theme(rawValue: themeRaw) ?? .dark }
    private var exposed: Int { store.exposedOrgs.count }

    private var indicators: Int { store.compromiseIndicators }

    // One line each. The forced break made every headline two lines tall,
    // which was part of what pushed the organizations below the fold.
    private var headline: String {
        if indicators > 0 { return "Compromise indicators found." }
        return exposed == 0 ? "Everything is at rest." : "\(plural(exposed, "vault")) exposed right now."
    }

    private var subtitle: String {
        if indicators > 0 {
            return "The scanner matched \(plural(indicators, "PolinRider indicator")) in a mounted vault. Treat every credential present during a build there as exposed, and do not open that folder in an editor until it is clean."
        }
        return exposed == 0
            ? "All organization data is ciphertext. Mount a vault when you're ready to work. Every unlock, commit and push asks for your touch."
            : "Exposed vaults are readable by anything running on this Mac. Secure what you're not actively using."
    }

    /// "Secure All" with one exposed vault describes a batch that is not
    /// happening; name the vault instead.
    private var secureTitle: String {
        exposed == 1 ? "Secure \(store.exposedOrgs[0].displayName)" : "Secure All"
    }

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Dashboard") {
                IconButton(symbol: theme == .dark ? "sun.max" : "moon",
                           help: "Switch to \(theme.toggleLabel.lowercased()) mode") {
                    themeRaw = theme.toggled.rawValue
                }
                if store.doctorRunning {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Re-run checks") {
                        Task { await store.runDoctor() }
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    SectionLabel("Organizations")
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.organizations) { org in
                            OrgCard(org: org)
                        }
                    }

                    HealthStrip()
                        .padding(.top, 20)
                }
                // Measured on the real window, the page ended 1pt inside the
                // 640pt minimum; these two paddings buy it ten.
                .padding(.horizontal, 40).padding(.top, 4).padding(.bottom, 14)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.system(size: 40, weight: .bold))
                .tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 12)
            HStack(spacing: 12) {
                if indicators > 0 {
                    PillButton(title: "Open Scanner", role: .destructive, height: 38, hpad: 22,
                               font: .system(size: 14, weight: .semibold)) {
                        store.selection = .scanner
                    }
                }
                if exposed > 0 {
                    PillButton(title: secureTitle, role: indicators > 0 ? .neutral : .accent,
                               height: 38, hpad: 22,
                               font: .system(size: 14, weight: .semibold)) {
                        Task { await store.secureAll() }
                    }
                }
                if !store.cloneableOrgs.isEmpty {
                    PillButton(title: "Clone a Repository",
                               role: exposed > 0 ? .neutral : .accent,
                               height: 38, hpad: exposed > 0 ? 18 : 22,
                               font: .system(size: 14, weight: exposed > 0 ? .medium : .semibold)) {
                        store.openClone()
                    }
                }
            }
            .padding(.top, 20)
        }
    }
}

// MARK: health strip

/// Posture, signing and the scanner as three tiles, each opening the page it
/// summarises. Only what was unique to the old score card and "at a glance"
/// list survives: the exposed and at-rest counts were already the headline
/// and the cards, and "Doctor: 2 findings" was the same two findings the
/// posture line counted.
struct HealthStrip: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    private var score: Int { store.postureScore }
    private var postureColor: Color { score >= 85 ? p.green : score >= 60 ? p.amber : p.red }
    private var postureText: Color { score >= 85 ? p.greenText : score >= 60 ? p.amberText : p.redText }

    private var postureLine: String {
        let indicators = store.compromiseIndicators
        if indicators > 0 { return "\(plural(indicators, "indicator")) found" }
        let criticals = store.findings.filter { $0.severity == .critical }.count
        let warnings = store.findings.filter { $0.severity == .warning }.count
        if criticals > 0 { return "\(plural(criticals, "critical issue")) to fix" }
        if warnings > 0 { return plural(warnings, "warning") }
        if !store.findings.isEmpty { return plural(store.findings.count, "note") }
        return "all checks passing"
    }

    private var signing: Int { store.organizations.filter(\.signingEnabled).count }
    private var orgCount: Int { store.organizations.count }

    private var scannerLine: String {
        guard let report = store.scanReport else { return "no pass yet" }
        return store.scanFindings.isEmpty
            ? "clean · \(ScannerView.relative(report.finishedAt))"
            : "\(plural(store.scanFindings.count, "finding")) to review"
    }

    var body: some View {
        HStack(spacing: 14) {
            // The score's arithmetic is the lever the ring never showed: 80 is
            // exactly two warnings, and hovering says so.
            HealthTile(title: "Posture", value: postureLine, valueColor: postureText,
                       help: "100, less 25 for each critical issue, 10 for each warning and 3 for each note. Opens the Doctor.") {
                ScoreRing(score: score, color: postureColor)
            } action: { store.selection = .doctor }

            HealthTile(title: "Signing", value: "\(signing) of \(plural(orgCount, "org"))",
                       valueColor: signing == orgCount ? p.greenText : p.amberText,
                       help: "Organizations whose commits are signed with their enclave key. Opens Organizations.") {
                // The signature symbol is far wider than it is tall; at the
                // magnifier's size it touched both sides of its circle.
                glyph("signature", p.accent, size: 12)
            } action: { store.selection = .organizations }

            HealthTile(title: "Scanner", value: scannerLine,
                       valueColor: store.scanFindings.isEmpty ? p.label2 : p.redText,
                       help: "Opens the Scanner.") {
                glyph("magnifyingglass", store.scanFindings.isEmpty ? p.label3 : p.red, size: 15)
            } action: { store.selection = .scanner }
        }
    }

    private func glyph(_ symbol: String, _ color: Color, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color.opacity(0.12)))
    }
}

struct HealthTile<Visual: View>: View {
    let title: String
    let value: String
    let valueColor: Color
    let help: String
    @ViewBuilder var visual: Visual
    let action: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                visual.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.label)
                    Text(value)
                        .font(.system(size: 12.5))
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverFill(p.card, p.cardHover, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .help(help)
    }
}

/// The posture ring at tile size: the page keeps its one piece of visual
/// identity without the 96pt the full ring took.
struct ScoreRing: View {
    let score: Int
    let color: Color
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45 * p.glowStrength), radius: 4)
                .animation(.easeOut(duration: 0.6), value: score)
            Text("\(score)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .contentTransition(.numericText())
        }
    }
}

// MARK: organization card

struct OrgCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    let org: Organization

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: org.vault.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(org.vault.color(p))
                    .frame(width: 30, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    // Identity sits beside the name, and an org whose identity
                    // is set per repository simply shows none. The dedicated row
                    // this replaces fell back to the folder path, so one card in
                    // the grid answered "where" while the others answered "who".
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(org.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !org.gitEmail.isEmpty {
                            Text(org.gitEmail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(p.label2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(org.vault.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(org.vault.textColor(p))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                // Drop chips before ever wrapping them when buttons need room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        chip("key.fill", org.keyLabel)
                        chip("signature", org.signingEnabled ? "signing" : "unsigned")
                    }
                    chip("signature", org.signingEnabled ? "signing" : "unsigned")
                    Color.clear.frame(width: 1, height: 1)
                }
                Spacer(minLength: 8)
                if store.busyOrgs.contains(org.name) {
                    ProgressView().controlSize(.small)
                } else {
                    // One pill, the action this vault most needs; the rest are
                    // text links, so pills never truncate. On an exposed vault
                    // that is the way back to rest: the page's headline asks
                    // for it, so the card should not make it the quietest thing
                    // on it while offering Clone, which adds exposure.
                    HStack(spacing: 10) {
                        switch org.vault {
                        case .locked:
                            pill("Mount", .accent) { store.mountTarget = org }
                        case .mounted:
                            link("Clone") { store.openClone(preferring: org) }
                            pill("Eject", .accent) { Task { await store.eject(org) } }
                        case .unlocked:
                            link("Mount") { Task { await store.relocate(org) } }
                            link("Clone") { store.openClone(preferring: org) }
                            pill("Secure", .accent) { Task { await store.eject(org) } }
                        case .misplaced:
                            pill("Relocate", .destructive) { Task { await store.relocate(org) } }
                        case .none:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }

    private func pill(_ title: String, _ role: PillRole, action: @escaping () -> Void) -> some View {
        PillButton(title: title, role: role, height: 30, hpad: 14,
                   font: .system(size: 12.5, weight: .medium), action: action)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        LinkButton(title, color: p.label2, hoverColor: p.label,
                   font: .system(size: 12.5, weight: .medium), action: action)
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 12))
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(p.btn))
        .foregroundStyle(p.label2)
    }
}

// MARK: - Doctor

struct DoctorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Doctor") {
                if store.doctorRunning {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Run checks") {
                        Task { await store.runDoctor() }
                    }
                }
            }
            if store.findings.isEmpty {
                EmptyState(
                    symbol: "checkmark.seal.fill",
                    title: "All checks passing",
                    message: "No drift detected between your configuration and its security guarantees."
                )
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.findings) { finding in
                            FindingRow(finding: finding)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
                }
            }
        }
    }
}

struct FindingRow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    let finding: DoctorFinding

    private var severityColor: Color {
        switch finding.severity {
        case .critical: p.red
        case .warning: p.amber
        case .info: p.accent
        }
    }

    private var severityIcon: String {
        switch finding.severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: severityIcon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(severityColor)
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(finding.checkName).font(.system(size: 13.5, weight: .medium))
                Text(finding.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.label2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let remediation = finding.remediation {
                    Text(remediation)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(p.label3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if finding.autoFixable {
                PillButton(title: "Fix", role: .accent, height: 30, hpad: 14,
                           font: .system(size: 12.5, weight: .medium)) {
                    Task { await store.applyFix(finding) }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }
}
