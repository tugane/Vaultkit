import SwiftUI
import TuganeDesign

// MARK: - Dashboard: posture ring + org status cards

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    @AppStorage("vk.theme") private var themeRaw = Theme.dark.rawValue

    private var theme: Theme { Theme(rawValue: themeRaw) ?? .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    ScoreCard(score: store.postureScore, findings: store.findings)
                    SummaryCard()
                }
                Text("Organizations")
                    .font(.title3.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    ForEach(store.organizations) { org in
                        OrgCard(org: org)
                    }
                }
            }
            .padding(24)
        }
        .background(p.content)
        .navigationTitle("Dashboard")
        .toolbar {
            Button {
                if let first = store.organizations.first(where: { $0.vault == .mounted || $0.vault == .unlocked }) {
                    store.cloneTarget = first
                }
            } label: {
                Label("Clone", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(!store.organizations.contains { $0.vault == .mounted || $0.vault == .unlocked })
            .help("Clone a repository into a vault (mounts it first if needed)")

            // Auger's signature: the theme is the app's own, toggled in-app.
            Button {
                themeRaw = theme.toggled.rawValue
            } label: {
                Label(theme.toggleLabel, systemImage: theme == .dark ? "sun.max" : "moon")
            }
            .help("Switch to \(theme.toggleLabel.lowercased()) mode")

            if store.doctorRunning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.runDoctor() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

struct ScoreCard: View {
    let score: Int
    let findings: [DoctorFinding]
    @Environment(\.palette) private var p

    private var color: Color {
        score >= 85 ? p.green : score >= 60 ? p.amber : p.red
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.45), radius: 10)
                    .animation(.easeOut(duration: 0.6), value: score)
                VStack(spacing: 0) {
                    Text("\(score)")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("posture")
                        .font(.caption)
                        .foregroundStyle(p.label3)
                }
            }
            .frame(width: 140, height: 140)

            let criticals = findings.filter { $0.severity == .critical }.count
            let warnings = findings.filter { $0.severity == .warning }.count
            Text(criticals > 0 ? "\(criticals) critical to fix"
                 : warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")"
                 : !findings.isEmpty ? "\(findings.count) informational note\(findings.count == 1 ? "" : "s")"
                 : "All checks passing")
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(20)
        .frame(width: 200)
        .card(p.card, radius: 16)
    }
}

struct SummaryCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("At a glance", systemImage: "eye")
                .font(.headline)
            summaryRow("lock.fill", p.green,
                       "\(store.organizations.filter { $0.vault == .locked }.count) vault(s) at rest")
            summaryRow("lock.open.fill", .orange,
                       "\(store.organizations.filter { $0.vault == .mounted }.count) mounted · exposed")
            summaryRow("signature", p.accent,
                       "\(store.organizations.filter(\.signingEnabled).count)/\(store.organizations.count) orgs signing commits")
            summaryRow("stethoscope", p.label3,
                       store.findings.isEmpty ? "Doctor: no findings" : "Doctor: \(store.findings.count) finding(s)")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(p.card, radius: 16)
    }

    private func summaryRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text).font(.callout)
        }
    }
}

struct OrgCard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    let org: Organization

    private var stateColor: Color {
        switch org.vault {
        case .mounted: .orange
        case .locked: p.green
        case .unlocked: p.amber
        case .misplaced: p.red
        case .none: p.label3
        }
    }

    private var stateText: String {
        switch org.vault {
        case .mounted: "Mounted · exposed"
        case .locked: "Locked · at rest"
        case .unlocked: "Unlocked · not at rest"
        case .misplaced: "Mounted · wrong location"
        case .none: "No vault"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: org.vault == .locked ? "lock.fill" : org.vault == .none ? "questionmark.square.dashed" : "lock.open.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(stateColor.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(org.displayName).font(.headline)
                    Text(stateText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(stateColor)
                }
                Spacer()
            }
            Text(org.gitEmail.isEmpty ? org.folderPath : org.gitEmail)
                .font(.caption)
                .foregroundStyle(p.label3)
                .lineLimit(1)
            HStack(spacing: 6) {
                // Drop chips before ever wrapping them when buttons need room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        chip("key.fill", org.keyLabel)
                        chip("signature", org.signingEnabled ? "signing" : "unsigned")
                    }
                    chip("signature", org.signingEnabled ? "signing" : "unsigned")
                    Color.clear.frame(width: 1, height: 1)
                }
                Spacer()
                if store.busyOrgs.contains(org.name) {
                    ProgressView().controlSize(.small)
                } else {
                    switch org.vault {
                    case .locked:
                        pill("Mount", .accent) { store.mountTarget = org }
                    case .mounted:
                        pill("Clone…", .accent) { store.cloneTarget = org }
                        pill("Eject", .neutral) { Task { await store.eject(org) } }
                    case .unlocked:
                        pill("Clone…", .accent) { store.cloneTarget = org }
                        pill("Mount", .neutral) { Task { await store.relocate(org) } }
                        pill("Secure", .neutral) { Task { await store.eject(org) } }
                    case .misplaced:
                        pill("Relocate", .destructive) { Task { await store.relocate(org) } }
                    case .none:
                        EmptyView()
                    }
                }
            }
        }
        .padding(16)
        .hoverFill(p.card, p.cardHover, radius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pill(_ title: String, _ role: PillRole, action: @escaping () -> Void) -> some View {
        PillButton(title, role: role, height: 26, hpad: 12,
                   font: .system(size: 12.5, weight: .medium), action: action)
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(p.btn))
            .foregroundStyle(p.label2)
    }
}

// MARK: - Doctor

struct DoctorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    @State private var running = false

    var body: some View {
        Group {
            if store.findings.isEmpty {
                ContentUnavailableView(
                    "All checks passing",
                    systemImage: "checkmark.seal.fill",
                    description: Text("No drift detected between your configuration and its security guarantees.")
                )
            } else {
                List(store.findings) { finding in
                    FindingRow(finding: finding)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(p.content)
        .navigationTitle("Doctor")
        .toolbar {
            Button {
                running = true
                Task { await store.runDoctor(); running = false }
            } label: {
                Label(running ? "Scanning…" : "Run checks", systemImage: "arrow.clockwise")
            }
            .disabled(running)
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.checkName).font(.headline)
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(p.label2)
                    .fixedSize(horizontal: false, vertical: true)
                if let remediation = finding.remediation {
                    Text(remediation)
                        .font(.caption.monospaced())
                        .foregroundStyle(p.label3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if finding.autoFixable {
                PillButton("Fix", role: .accent, height: 26, hpad: 12,
                           font: .system(size: 12.5, weight: .medium)) {
                    Task { await store.applyFix(finding) }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
