import SwiftUI

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

    /// Move a misplaced (e.g. Finder-mounted) volume to its canonical path.
    /// Usually passphrase-free (keys cached); falls back to the sheet if the
    /// keys drop during the move.
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

    /// Clone into the org's mounted vault with the org's key (Touch ID prompt).
    /// Returns true on success so the sheet can dismiss.
    func clone(url: String, into org: Organization) async -> Bool {
        busyOrgs.insert(org.name)
        defer { busyOrgs.remove(org.name) }
        do {
            let name = try await git.clone(url: url, into: org)
            lastError = "Cloned \(name) into \(org.folderPath) with \(org.keyLabel)."
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $store.selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.rail)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch store.selection ?? .vaults {
            case .dashboard: DashboardView()
            case .organizations: OrganizationsView()
            case .vaults: VaultsView()
            case .doctor: DoctorView()
            }
        }
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
        // Auger's design is committed dark — the palette owns the window.
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

// MARK: - Vaults

struct VaultsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if store.organizations.isEmpty {
                ContentUnavailableView(
                    "No organizations found",
                    systemImage: "lock.square.stack",
                    description: Text("Vaultkit derives organizations from ~/.gitconfig includeIf blocks for ~/work/<org>/ folders.")
                )
            } else {
                List(store.organizations) { org in
                    VaultRow(org: org)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bg)
        .navigationTitle("Vaults")
        .toolbar {
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

struct VaultRow: View {
    @EnvironmentObject var store: AppStore
    let org: Organization

    var body: some View {
        HStack {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
                .font(.title2)
                .frame(width: 30)
            VStack(alignment: .leading) {
                Text(org.displayName).font(.headline)
                Text("\(org.folderPath) · \(org.gitEmail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor)
            actionButton
        }
        .padding(.vertical, 4)
    }

    private var stateIcon: String {
        switch org.vault {
        case .none: "questionmark.square.dashed"
        case .locked: "lock.fill"
        case .mounted: "lock.open.fill"
        case .unlocked: "lock.open.trianglebadge.exclamationmark"
        case .misplaced: "arrow.triangle.2.circlepath"
        }
    }

    private var stateColor: Color {
        switch org.vault {
        case .none: .secondary
        case .locked: Theme.green
        case .mounted: .orange
        case .unlocked: Theme.amber
        case .misplaced: Theme.red
        }
    }

    private var stateLabel: String {
        switch org.vault {
        case .none: "no vault"
        case .locked: "locked · at rest"
        case .mounted: "mounted · exposed"
        case .unlocked: "unlocked · not at rest"
        case .misplaced: "mounted · wrong location"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.busyOrgs.contains(org.name) {
            ProgressView().controlSize(.small)
        } else {
            switch org.vault {
            case .locked:
                Button("Mount") { store.mountTarget = org }
            case .mounted:
                Button("Clone…") { store.cloneTarget = org }
                Button("Eject") { Task { await store.eject(org) } }
            case .unlocked:
                // keys cached: Mount is passphrase-free; Secure drops the keys
                Button("Mount") { Task { await store.relocate(org) } }
                Button("Secure") { Task { await store.eject(org) } }
            case .misplaced:
                Button("Relocate") { Task { await store.relocate(org) } }
            case .none:
                EmptyView()
            }
        }
    }
}

struct MountSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let org: Organization
    @State private var passphrase = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Unlock \(org.displayName)", systemImage: "lock.open")
                .font(.title3.weight(.semibold))
            Text("Mounting exposes this organization's data until you eject. The passphrase is passed straight to diskutil and never stored.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Vault passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Unlocking…" : "Mount") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 420)
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
    let org: Organization                    // preselection (card that opened us)
    @State private var selectedName = ""
    @State private var url = ""
    @State private var working = false

    private var mountedOrgs: [Organization] {
        store.organizations.filter { $0.vault == .mounted }
    }
    private var selected: Organization? {
        mountedOrgs.first { $0.name == selectedName }
    }
    private var host: String? { GitService.host(of: url) }
    private var pinned: Bool { host.map(GitService.isPinned) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Clone a repository", systemImage: "square.and.arrow.down.on.square")
                .font(.title3.weight(.semibold))
            // Multiple vaults can be mounted — the destination is an explicit choice.
            Picker("Into", selection: $selectedName) {
                ForEach(mountedOrgs) { o in
                    Text("\(o.displayName)  (\(o.folderPath))").tag(o.name)
                }
            }
            .pickerStyle(.menu)
            if let selected {
                Text("Authenticates with \(selected.keyLabel) — expect a Touch ID prompt.")
                    .font(.callout)
                    .foregroundStyle(Theme.label2)
            }
            TextField("git@host:org/repo.git", text: $url)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(submit)
            if let host, !url.isEmpty {
                Label(
                    pinned ? "\(host) — host key pinned & verified" : "\(host) is NOT in known_hosts — verify and pin it before cloning",
                    systemImage: pinned ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(pinned ? Theme.green : Theme.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(working ? "Cloning…" : "Clone") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url.isEmpty || !pinned || working || selected == nil)
            }
        }
        .padding(24)
        .frame(width: 470)
        .background(Theme.bg2)
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

    var body: some View {
        List(store.organizations) { org in
            VStack(alignment: .leading, spacing: 2) {
                Text(org.displayName).font(.headline)
                Text("\(org.gitEmail) · key \(org.keyLabel) · signing \(org.signingEnabled ? "on" : "off")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Organizations")
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
