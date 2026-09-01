import SwiftUI

// MARK: - Dashboard: posture ring + org status cards

struct DashboardView: View {
    @EnvironmentObject var store: AppStore

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
        .navigationTitle("Dashboard")
        .toolbar {
            Button {
                Task { await store.runDoctor() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

struct ScoreCard: View {
    let score: Int
    let findings: [DoctorFinding]

    private var color: Color {
        score >= 85 ? .green : score >= 60 ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: score)
                VStack(spacing: 0) {
                    Text("\(score)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("posture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 130)

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
        .cardStyle()
    }
}

struct SummaryCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("At a glance", systemImage: "eye")
                .font(.headline)
            summaryRow("lock.fill", .green,
                       "\(store.organizations.filter { $0.vault == .locked }.count) vault(s) at rest")
            summaryRow("lock.open.fill", .orange,
                       "\(store.organizations.filter { $0.vault == .mounted }.count) mounted · exposed")
            summaryRow("signature", .blue,
                       "\(store.organizations.filter(\.signingEnabled).count)/\(store.organizations.count) orgs signing commits")
            summaryRow("stethoscope", .secondary,
                       store.findings.isEmpty ? "Doctor: no findings" : "Doctor: \(store.findings.count) finding(s)")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
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
    let org: Organization

    private var stateColor: Color {
        switch org.vault {
        case .mounted: .orange
        case .locked: .green
        case .unlocked: .yellow
        case .misplaced: .red
        case .none: .secondary
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                chip("key.fill", org.keyLabel)
                chip("signature", org.signingEnabled ? "signing" : "unsigned")
                Spacer()
                switch org.vault {
                case .locked:
                    Button("Mount") { store.mountTarget = org }
                        .controlSize(.small)
                case .mounted:
                    Button("Eject") { Task { await store.eject(org) } }
                        .controlSize(.small)
                case .unlocked:
                    Button("Secure") { Task { await store.eject(org) } }
                        .controlSize(.small)
                case .misplaced:
                    Button("Relocate") { Task { await store.relocate(org) } }
                        .controlSize(.small)
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .cardStyle()
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Doctor

struct DoctorView: View {
    @EnvironmentObject var store: AppStore
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
            }
        }
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
    let finding: DoctorFinding

    private var severityColor: Color {
        switch finding.severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let remediation = finding.remediation {
                    Text(remediation)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if finding.autoFixable {
                Button("Fix") {
                    Task { await store.applyFix(finding) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Shared card styling

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}
