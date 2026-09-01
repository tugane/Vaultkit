import SwiftUI
import TuganeDesign

/// App-wide observable state. Derived from the system via services (I2);
/// this object only caches.
@MainActor
final class AppStore: ObservableObject {
    @Published var organizations: [Organization] = []
    @Published var findings: [DoctorFinding] = []
    @Published var selection: SidebarItem? = .dashboard
    @Published var lastError: String?
    @Published var mountTarget: Organization?    // non-nil → passphrase sheet is up
    @Published var cloneTarget: Organization?    // non-nil → clone sheet is up
    @Published var busyOrgs: Set<String> = []    // orgs with an action in flight
    @Published var doctorRunning = false

    let vaults = DiskUtilVaultService()
    let doctor = DoctorService()
    let git = GitService()

    init() {
        // Populate at launch regardless of which scene shows first — the
        // menu-bar extra must not depend on the main window ever opening.
        Task { await runDoctor() }

        // Mount/eject can happen outside the app (work-on/work-off, Finder,
        // Disk Utility) — refresh on the system's own mount notifications so
        // the cards never show stale vault state.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }

        // NSWorkspace only notices /Volumes-scope mounts — canonical-path mounts
        // (diskutil -mountpoint ~/work/<org>, i.e. work-on and our own) bypass
        // it. A light poll keeps the cards honest; refresh is one diskutil call.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Vaults whose data is readable right now, by any definition.
    var exposedOrgs: [Organization] {
        organizations.filter { $0.vault == .mounted || $0.vault == .unlocked || $0.vault == .misplaced }
    }

    var cloneableOrgs: [Organization] {
        organizations.filter { $0.vault == .mounted || $0.vault == .unlocked }
    }

    /// 100 minus weighted findings: critical −25, warning −10, info −3.
    var postureScore: Int {
        let penalty = findings.reduce(0) { acc, f in
            acc + (f.severity == .critical ? 25 : f.severity == .warning ? 10 : 3)
        }
        return max(0, 100 - penalty)
    }

    func runDoctor() async {
        doctorRunning = true
        await refresh()
        findings = await doctor.runAllChecks(orgs: organizations)
        doctorRunning = false
    }

    func applyFix(_ finding: DoctorFinding) async {
        await doctor.applyFix(for: finding, orgs: organizations)
        await runDoctor()
    }

    func refresh() async {
        var orgs = OrgDiscovery.discover()
        let states = await vaults.states(for: orgs)   // one diskutil call for all orgs
        for i in orgs.indices {
            orgs[i].vault = states[orgs[i].name] ?? .none
        }
        organizations = orgs
    }

    /// Move a misplaced (e.g. Finder-mounted) volume to its canonical path,
    /// or mount an unlocked one — passphrase-free while keys are cached.
    /// Falls back to the sheet if the keys drop mid-way.
    func relocate(_ org: Organization) async {
        busyOrgs.insert(org.name)
        do {
            try await vaults.mount(org, passphrase: "")
        } catch {
            mountTarget = org
        }
        await runDoctor()
        busyOrgs.remove(org.name)
    }

    /// Clone into the org's vault with the org's key (Touch ID prompt),
    /// mounting first when the keys are cached. Returns true on success.
    func clone(url: String, into org: Organization) async -> Bool {
        busyOrgs.insert(org.name)
        defer { busyOrgs.remove(org.name) }
        do {
            var target = org
            if target.vault == .unlocked {
                try await vaults.mount(target, passphrase: "")
                target.vault = .mounted
            }
            let name = try await git.clone(url: url, into: target)
            lastError = "Cloned \(name) into \(org.folderPath) with \(org.keyLabel)."
            await runDoctor()
            return true
        } catch {
            lastError = error.localizedDescription
            await runDoctor()   // a failed attempt may still have mounted the vault
            return false
        }
    }

    func mount(_ org: Organization, passphrase: String) async {
        busyOrgs.insert(org.name)
        do {
            try await vaults.mount(org, passphrase: passphrase)
        } catch {
            lastError = error.localizedDescription
        }
        await runDoctor()   // mutations refresh findings too
        busyOrgs.remove(org.name)
    }

    func eject(_ org: Organization) async {
        busyOrgs.insert(org.name)
        do {
            try await vaults.eject(org)
        } catch {
            lastError = error.localizedDescription
        }
        await runDoctor()
        busyOrgs.remove(org.name)
    }

    /// Put every exposed vault at rest (mounted, unlocked, or misplaced).
    func secureAll() async {
        for org in exposedOrgs {
            await eject(org)
        }
    }

    func openClone(preferring org: Organization? = nil) {
        cloneTarget = org ?? cloneableOrgs.first
    }
}

// MARK: - Vault state presentation (one place, palette-driven)

extension VaultState {
    /// Fill/icon colour — vivid.
    func color(_ p: Palette) -> Color {
        switch self {
        case .none: p.label3
        case .locked: p.green
        case .mounted: p.orange
        case .unlocked: p.amber
        case .misplaced: p.red
        }
    }

    /// Text colour — darkened in light mode so captions stay legible.
    func textColor(_ p: Palette) -> Color {
        switch self {
        case .none: p.label3
        case .locked: p.greenText
        case .mounted: p.orangeText
        case .unlocked: p.amberText
        case .misplaced: p.redText
        }
    }

    var icon: String {
        switch self {
        case .none: "questionmark.square.dashed"
        case .locked: "lock.fill"
        case .mounted: "lock.open.fill"
        case .unlocked: "lock.open.trianglebadge.exclamationmark"
        case .misplaced: "arrow.triangle.2.circlepath"
        }
    }

    var label: String {
        switch self {
        case .none: "No vault"
        case .locked: "Locked · at rest"
        case .mounted: "Mounted · exposed"
        case .unlocked: "Unlocked · not at rest"
        case .misplaced: "Mounted · wrong location"
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case organizations = "Organizations"
    case vaults = "Vaults"
    case doctor = "Doctor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "gauge"
        case .organizations: "person.2.badge.key"
        case .vaults: "lock.square.stack"
        case .doctor: "stethoscope"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 232)
                .background(p.sidebar)
            Divider().overlay(p.sep2)
            Group {
                switch store.selection ?? .dashboard {
                case .dashboard: DashboardView()
                case .organizations: OrganizationsView()
                case .vaults: VaultsView()
                case .doctor: DoctorView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.content)
        }
        .ignoresSafeArea(.container, edges: .top)
        .alert("Vaultkit", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .sheet(item: $store.mountTarget) { org in
            MountSheet(org: org)
        }
        .sheet(item: $store.cloneTarget) { org in
            CloneSheet(org: org)
        }
        .tint(p.accent)
    }
}

// MARK: - Page chrome (Auger: title lives in the content, not a toolbar band)

struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }
}

/// Round icon button used in page headers (Auger's rescan affordance).
struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(p.label2)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? p.btnHover : p.btn))
                .contentShape(Circle())
        }
        .buttonStyle(.pointer)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Palette-driven empty state (ContentUnavailableView renders system greys).
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 12) {
            Mascot(symbol: symbol, tint: p.label3)
                .frame(width: 54, height: 54)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            // Space reserved for the OS traffic lights.
            Color.clear.frame(height: 54)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHead("Posture")
                    row(.dashboard, chip: nil)
                    row(.doctor, chip: store.findings.isEmpty ? nil : "\(store.findings.count)")

                    sectionHead("Manage")
                    row(.organizations, chip: "\(store.organizations.count)")
                    row(.vaults, chip: store.exposedOrgs.isEmpty ? nil : "\(store.exposedOrgs.count) open")
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 12) {
                Divider().overlay(p.sep)
                Text("Vaultkit 0.1\n\(plural(store.organizations.count, "organization")) · \(plural(store.exposedOrgs.count, "vault")) exposed")
                    .font(.system(size: 12))
                    .foregroundStyle(p.label3)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
        }
    }

    private func sectionHead(_ text: String) -> some View {
        SectionLabel(text)
            .padding(.top, 18).padding(.bottom, 8).padding(.horizontal, 16)
    }

    private func row(_ item: SidebarItem, chip: String?) -> some View {
        NavRow(
            symbol: item.icon,
            label: item.rawValue,
            chip: chip,
            active: (store.selection ?? .dashboard) == item
        ) { store.selection = item }
    }
}

/// Spacious nav row: accent-tinted glyph, roomy height, trailing chip.
private struct NavRow: View {
    let symbol: String
    let label: String
    var chip: String?
    let active: Bool
    let action: () -> Void
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? Color.white : p.accent)
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.white : p.label)
                Spacer(minLength: 6)
                if let chip {
                    Text(chip)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(active ? Color.white : p.label3)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? p.accent : (hovering ? p.btn : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .onHover { hovering = $0 }
    }
}

// MARK: - Vaults

struct VaultsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Vaults") {
                IconButton(symbol: "arrow.clockwise", help: "Re-read vault state") {
                    Task { await store.refresh() }
                }
            }
            if store.organizations.isEmpty {
                EmptyState(
                    symbol: "lock.square.stack",
                    title: "No organizations found",
                    message: "Vaultkit derives organizations from ~/.gitconfig includeIf blocks for ~/work/<org>/ folders."
                )
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.organizations) { org in
                            VaultRow(org: org)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
                }
            }
        }
    }
}

struct VaultRow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p
    let org: Organization

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: org.vault.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(org.vault.color(p))
                .frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(org.displayName)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                // The identity line is the one element that may give way: it
                // middle-truncates so the head and tail of the path both stay
                // readable, rather than wrapping the row to two lines.
                Text("\(org.folderPath) · \(org.gitEmail)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.label2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Text(org.vault.label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(org.vault.textColor(p))
                .lineLimit(1)
                .fixedSize()
            actionButtons
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverFill(p.card, p.cardHover, radius: 12)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if store.busyOrgs.contains(org.name) {
            ProgressView().controlSize(.small).frame(width: 60)
        } else {
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

    private func pill(_ title: String, _ role: PillRole, action: @escaping () -> Void) -> some View {
        PillButton(title: title, role: role, height: 30, hpad: 14,
                   font: .system(size: 12.5, weight: .medium), action: action)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        LinkButton(title, color: p.label2, hoverColor: p.label,
                   font: .system(size: 12.5, weight: .medium), action: action)
    }
}

// MARK: - Sheets

struct MountSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let org: Organization
    @State private var passphrase = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Mascot(symbol: "lock.open", tint: p.accent)
                    .frame(width: 26, height: 26)
                Text("Unlock \(org.displayName)")
                    .font(.system(size: 15, weight: .bold))
            }
            Text("Mounting exposes this organization's data until you eject. The passphrase is passed straight to diskutil and never stored.")
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
            SecureField("Vault passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit(submit)
            HStack(spacing: 10) {
                Spacer()
                PillButton(title: "Cancel", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: working ? "Unlocking…" : "Mount", role: .accent, height: 32,
                           hpad: 18, radius: 8, font: .system(size: 13, weight: .semibold)) { submit() }
                    .disabled(passphrase.isEmpty || working)
                    .opacity(passphrase.isEmpty || working ? 0.5 : 1)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(p.sheet)
    }

    private func submit() {
        guard !passphrase.isEmpty else { return }
        working = true
        let phrase = passphrase
        passphrase = "" // release the visible buffer immediately
        Task {
            await store.mount(org, passphrase: phrase)
            working = false
            dismiss()
        }
    }
}

struct CloneSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let org: Organization                    // preselection (card that opened us)
    @State private var selectedName = ""
    @State private var url = ""
    @State private var working = false

    private var selected: Organization? {
        store.cloneableOrgs.first { $0.name == selectedName }
    }
    private var host: String? { GitService.host(of: url) }
    private var pinned: Bool { host.map(GitService.isPinned) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Mascot(symbol: "square.and.arrow.down.on.square", tint: p.accent)
                    .frame(width: 26, height: 26)
                Text("Clone a repository")
                    .font(.system(size: 15, weight: .bold))
            }
            // Multiple vaults can be mounted — the destination is an explicit choice.
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Into")
                Picker("", selection: $selectedName) {
                    ForEach(store.cloneableOrgs) { o in
                        Text("\(o.displayName)  (\(o.folderPath))\(o.vault == .unlocked ? "  — will mount first" : "")")
                            .tag(o.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 13))
            }
            if let selected {
                Text("Authenticates with \(selected.keyLabel) — expect a Touch ID prompt.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.label2)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Repository")
                TextField("git@host:org/repo.git", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .onSubmit(submit)
            }
            if let host, !url.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: pinned ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text(pinned ? "\(host) — host key pinned & verified"
                                : "\(host) is NOT in known_hosts — verify and pin it before cloning")
                        .font(.system(size: 12.5))
                }
                .foregroundStyle(pinned ? p.greenText : p.redText)
            }
            HStack(spacing: 10) {
                Spacer()
                PillButton(title: "Cancel", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: working ? "Cloning…" : "Clone", role: .accent, height: 32,
                           hpad: 18, radius: 8, font: .system(size: 13, weight: .semibold)) { submit() }
                    .disabled(url.isEmpty || !pinned || working || selected == nil)
                    .opacity(url.isEmpty || !pinned || working || selected == nil ? 0.5 : 1)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(p.sheet)
        .onAppear { selectedName = org.name }
    }

    private func submit() {
        guard let selected, !url.isEmpty, pinned, !working else { return }
        working = true
        Task {
            let ok = await store.clone(url: url, into: selected)
            working = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Organizations panel

struct OrganizationsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Organizations") { EmptyView() }
            if store.organizations.isEmpty {
                EmptyState(
                    symbol: "person.2.badge.key",
                    title: "No organizations found",
                    message: "Add an includeIf block for ~/work/<org>/ to ~/.gitconfig and Vaultkit will pick it up."
                )
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.organizations) { org in
                            HStack(spacing: 16) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(p.accent)
                                    .frame(width: 34, height: 38)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(org.displayName)
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("\(org.gitEmail) · key \(org.keyLabel) · signing \(org.signingEnabled ? "on" : "off")")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(p.label2)
                                }
                                Spacer(minLength: 0)
                                Text(org.vault.label)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(org.vault.textColor(p))
                            }
                            .padding(.horizontal, 22).padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hoverFill(p.card, p.cardHover, radius: 12)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
                }
            }
        }
    }
}

/// Menu-bar extra: the fastest path to mount/eject without the main window.
struct MenuBarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.organizations.isEmpty {
            Text("No organizations found")
            Divider()
        }
        ForEach(store.organizations) { org in
            switch org.vault {
            case .mounted:
                Button("Eject \(org.displayName)  (mounted)") {
                    Task { await store.eject(org) }
                }
            case .locked:
                Button("Mount \(org.displayName)…") {
                    store.selection = .vaults
                    store.mountTarget = org
                    NSApp.activate(ignoringOtherApps: true)
                }
            case .unlocked:
                Button("Secure \(org.displayName)  (unlocked!)") {
                    Task { await store.eject(org) }
                }
            case .misplaced:
                Button("Relocate \(org.displayName)  (wrong location)") {
                    Task { await store.relocate(org) }
                }
            case .none:
                Text("\(org.displayName) — no vault")
            }
        }
        Divider()
        Button("Refresh") { Task { await store.refresh() } }
        Button("Open Vaultkit") { NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
