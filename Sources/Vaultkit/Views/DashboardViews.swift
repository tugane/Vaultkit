import SwiftUI
import TuganeDesign

// MARK: - Dashboard: hero + posture ring + org status cards

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    @AppStorage("vk.theme") private var themeRaw = Theme.dark.rawValue

    private var theme: Theme { Theme(rawValue: themeRaw) ?? .dark }
    private var exposed: Int { store.exposedOrgs.count }

    private var headline: String {
        exposed == 0
            ? "Everything is\nat rest."
            : "\(plural(exposed, "vault")) exposed\nright now."
    }

    private var subtitle: String {
        exposed == 0
            ? "All organization data is ciphertext. Mount a vault when you're ready to work — every unlock, commit and push asks for your touch."
            : "Exposed vaults are readable by anything running on this Mac. Secure what you're not actively using."
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Dashboard") {
                IconButton(symbol: "plus", help: "Add an organization") {
                    store.showAddOrg = true
                }
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
                    // Hero: statement, subtitle, pill row (Auger's Home scale).
                    VStack(alignment: .leading, spacing: 0) {
                        Text(headline)
                            .font(.system(size: 40, weight: .bold))
                            .tracking(-1)
                            .lineSpacing(2)
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(p.label2)
                            .lineSpacing(3)
                            .frame(maxWidth: 460, alignment: .leading)
                            .padding(.top, 16)
                        HStack(spacing: 12) {
                            if exposed > 0 {
                                PillButton(title: "Secure All", role: .accent, height: 38, hpad: 22,
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
                        .padding(.top, 26)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                        GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ScoreCard(score: store.postureScore, findings: store.findings)
                        SummaryCard()
                    }
                    .padding(.top, 48)

                    SectionLabel("Organizations")
                        .padding(.top, 34)
                        .padding(.bottom, 12)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                        GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(store.organizations) { org in
                            OrgCard(org: org)
                        }
                    }
                }
                .padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .background(alignment: .topTrailing) {
            // Auger's corner glow, dialed back in light where it would smear.
            RadialGradient(
                colors: [p.accent.opacity(0.55 * p.glowStrength),
                         p.accent.opacity(0.16 * p.glowStrength),
                         .clear],
                center: .topTrailing, startRadius: 30, endRadius: 620
            )
            .frame(width: 780, height: 680)
            .blur(radius: 36)
            .allowsHitTesting(false)
        }
    }
}

struct ScoreCard: View {
    let score: Int
    let findings: [DoctorFinding]
    @Environment(\.palette) private var p

    private var ringColor: Color {
        score >= 85 ? p.green : score >= 60 ? p.amber : p.red
    }
    private var textColor: Color {
        score >= 85 ? p.greenText : score >= 60 ? p.amberText : p.redText
    }

    private var statusLine: String {
        let criticals = findings.filter { $0.severity == .critical }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        if criticals > 0 { return "\(plural(criticals, "critical issue")) to fix" }
        if warnings > 0 { return plural(warnings, "warning") }
        if !findings.isEmpty { return plural(findings.count, "informational note") }
        return "All checks passing"
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.15), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(ringColor.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: ringColor.opacity(0.45 * p.glowStrength), radius: 10)
                    .animation(.easeOut(duration: 0.6), value: score)
                Text("\(score)")
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .tracking(-0.7)
                    .contentTransition(.numericText())
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 7) {
                Text("Posture").font(.system(size: 14, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(textColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(p.card, radius: 12)
    }
}

struct SummaryCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("At a glance").font(.system(size: 14, weight: .semibold))
            summaryRow("lock.fill", p.green,
                       "\(plural(store.organizations.filter { $0.vault == .locked }.count, "vault")) at rest")
            summaryRow("lock.open.fill", p.orange,
                       "\(plural(store.exposedOrgs.count, "vault")) exposed")
            summaryRow("signature", p.accent,
                       "\(store.organizations.filter(\.signingEnabled).count)/\(store.organizations.count) orgs signing commits")
            summaryRow("stethoscope", p.label3,
                       store.findings.isEmpty ? "Doctor: no findings"
                                              : "Doctor: \(plural(store.findings.count, "finding"))")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(p.card, radius: 12)
    }

    private func summaryRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text).font(.system(size: 13))
        }
    }
}

struct OrgCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    let org: Organization

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: org.vault.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(org.vault.color(p))
                    .frame(width: 34, height: 38)
                VStack(alignment: .leading, spacing: 7) {
                    Text(org.displayName).font(.system(size: 14, weight: .semibold))
                    Text(org.vault.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(org.vault.textColor(p))
                }
                Spacer(minLength: 0)
            }
            Text(org.gitEmail.isEmpty ? org.folderPath : org.gitEmail)
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineLimit(1)
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
                    // One pill = the primary action; secondary actions are text
                    // links, so pills never truncate.
                    HStack(spacing: 10) {
                        switch org.vault {
                        case .locked:
                            pill("Mount", .accent) { store.mountTarget = org }
                        case .mounted:
                            link("Eject") { Task { await store.eject(org) } }
                            pill("Clone…", .accent) { store.cloneTarget = org }
                        case .unlocked:
                            link("Mount") { Task { await store.relocate(org) } }
                            link("Secure") { Task { await store.eject(org) } }
                            pill("Clone…", .accent) { store.cloneTarget = org }
                        case .misplaced:
                            pill("Relocate", .destructive) { Task { await store.relocate(org) } }
                        case .none:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
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
