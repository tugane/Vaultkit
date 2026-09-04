import SwiftUI
import TuganeDesign
import UserNotifications

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
    @Published var showAddOrg = false
    @Published var creatingOrg: String?          // non-nil → step label, in flight
    @Published var newKey: (org: String, key: String)?
    @Published var scanFindings: [ScanFinding] = []
    @Published var scanReport: ScannerService.Report?
    @Published var scanRunning = false
    @Published var nextScanAt: Date?
    @Published var removeTarget: Organization?   // non-nil → removal sheet is up
    @Published var removingOrg: String?          // non-nil → step label, in flight
    @Published var receipt: RemovalReceipt?
    @Published var history = ScannerHistory()
    @Published var quarantine: [QuarantineItem] = []
    @Published var activity: [ActivityItem] = []
    @Published var activityRunning = false
    @Published var activityCheckedAt: Date?
    /// Act on critical hits the moment they are found. Warnings are never
    /// auto-actioned; a fix for those is a button.
    @Published var autoQuarantine = UserDefaults.standard.object(forKey: "vk.scanner.autoQuarantine") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoQuarantine, forKey: "vk.scanner.autoQuarantine") }
    }

    /// How often mounted vaults are re-checked for changed files.
    static let scanInterval: TimeInterval = 300
    /// How long a quarantined original is held before it is purged for good.
    /// Restore is only possible inside this window.
    static let quarantineTTL: TimeInterval = 600
    private var mountedNames: Set<String> = []

    let vaults = DiskUtilVaultService()
    let scanner = ScannerService()
    let quarantineService = QuarantineService()
    let activityService = ActivityService()
    let historyStore = HistoryStore()
    let doctor = DoctorService()
    let git = GitService()
    let keys = EnclaveKeyService()
    let gitConfig = GitConfigService()

    init() {
        history = historyStore.load()

        // Populate at launch regardless of which scene shows first: the
        // menu-bar extra must not depend on the main window ever opening.
        Task { await runDoctor() }

        // Mount/eject can happen outside the app (work-on/work-off, Finder,
        // Disk Utility): refresh on the system's own mount notifications so
        // the cards never show stale vault state.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }

        // NSWorkspace only notices /Volumes-scope mounts: canonical-path mounts
        // (diskutil -mountpoint ~/work/<org>, i.e. work-on and our own) bypass
        // it. A light poll keeps the cards honest; refresh is one diskutil call.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        // The Scanner: changed files in every mounted vault, on a fixed cadence.
        // Mount/eject transitions (caught in refresh) trigger a pass as well, so
        // a freshly mounted vault never waits out the interval unwatched.
        Task { await runScan() }
        Task { await refreshActivity() }
        Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runScan()
                await self?.refreshActivity()
            }
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
    /// Scanner hits weigh the same as Doctor findings of the same severity.
    var postureScore: Int {
        let doctorPenalty = findings.reduce(0) { acc, f in
            acc + (f.severity == .critical ? 25 : f.severity == .warning ? 10 : 3)
        }
        let scanPenalty = scanFindings.reduce(0) { acc, f in
            acc + (f.severity == .critical ? 25 : 10)
        }
        return max(0, 100 - doctorPenalty - scanPenalty)
    }

    var compromiseIndicators: Int { scanFindings.filter { $0.severity == .critical }.count }

    /// Background items that stood out. Mounted vault paths go in so a process
    /// running out of a vault can be named as such.
    var flaggedActivity: Int { activity.filter { !$0.reasons.isEmpty }.count }

    func refreshActivity() async {
        guard !activityRunning else { return }
        activityRunning = true
        let paths = organizations.filter { $0.vault == .mounted }
            .map { ($0.folderPath as NSString).expandingTildeInPath }
        activity = await activityService.snapshot(vaultPaths: paths)
        activityCheckedAt = Date()
        activityRunning = false
    }

    /// One pass, then: with auto-quarantine on: act on every critical hit
    /// and re-read what was touched, so the list shows the state *after* the
    /// fixes. The history records what was found and what was done.
    func runScan(deep: Bool = false) async {
        guard !scanRunning else { return }
        scanRunning = true
        let orgs = organizations
        let (report, found) = await scanner.scan(orgs: orgs, deep: deep)
        var hits = found
        var actions: [ActionEvent] = []

        if autoQuarantine {
            for f in found where f.severity == .critical && f.fix != .manual {
                actions.append(act(on: f, in: orgs))
            }
            if !actions.isEmpty {
                hits = await scanner.scan(orgs: orgs, deep: false).1
            }
        }

        scanReport = report
        scanFindings = hits
        history.scans.insert(ScanEvent(date: report.startedAt, duration: report.duration, mode: report.mode,
                                       orgs: report.orgsScanned, repos: report.reposSeen,
                                       files: report.filesScanned, hits: found.count), at: 0)
        history.actions.insert(contentsOf: actions, at: 0)
        historyStore.save(history)
        reloadQuarantine()

        if !found.isEmpty {
            let neutralized = actions.filter { $0.kind == .cleaned || $0.kind == .quarantined }.count
            notify(title: neutralized > 0
                       ? "Vaultkit neutralized \(plural(neutralized, "PolinRider hit"))"
                       : "Vaultkit found \(plural(found.count, "PolinRider indicator"))",
                   body: found.prefix(3).map { "\($0.repo): \($0.path)" }.joined(separator: "\n"))
        }
        nextScanAt = Date().addingTimeInterval(Self.scanInterval)
        scanRunning = false
    }

    /// Apply a finding's fix and say what happened. Never throws: a failure
    /// is a `.manual` action with the reason, so the history stays complete.
    private func act(on f: ScanFinding, in orgs: [Organization]) -> ActionEvent {
        guard let org = orgs.first(where: { $0.name == f.orgName }) else {
            return ActionEvent(date: Date(), kind: .manual, orgName: f.orgName, path: f.path,
                               indicator: f.indicator, detail: "Organization no longer known.")
        }
        let root = (org.folderPath as NSString).expandingTildeInPath
        do {
            return try quarantineService.remediate(f, vaultRoot: root).0
        } catch {
            return ActionEvent(date: Date(), kind: .manual, orgName: f.orgName, path: f.path,
                               indicator: f.indicator, detail: error.localizedDescription)
        }
    }

    /// The Fix button: warnings, or criticals while auto-quarantine is off.
    func fix(_ f: ScanFinding) async {
        let action = act(on: f, in: organizations)
        history.actions.insert(action, at: 0)
        historyStore.save(history)
        if action.kind == .manual { lastError = action.detail }
        await runScan()
    }

    func reloadQuarantine() {
        quarantine = organizations.filter { $0.vault == .mounted }
            .flatMap { quarantineService.items(in: ($0.folderPath as NSString).expandingTildeInPath) }
            .sorted { $0.date > $1.date }
    }

    /// Puts the held bytes back. Deliberately does not rescan: with
    /// auto-quarantine on, the next pass will take an infected original again,
    /// and the Quarantine tab says so.
    func restore(_ item: QuarantineItem) {
        guard let org = organizations.first(where: { $0.name == item.orgName }) else { return }
        let root = (org.folderPath as NSString).expandingTildeInPath
        do {
            history.actions.insert(try quarantineService.restore(item, vaultRoot: root), at: 0)
        } catch {
            lastError = error.localizedDescription
        }
        historyStore.save(history)
        reloadQuarantine()
    }

    func purge(_ item: QuarantineItem) {
        guard let org = organizations.first(where: { $0.name == item.orgName }) else { return }
        let root = (org.folderPath as NSString).expandingTildeInPath
        do {
            history.actions.insert(try quarantineService.purge(item, vaultRoot: root), at: 0)
        } catch {
            lastError = error.localizedDescription
        }
        historyStore.save(history)
        reloadQuarantine()
    }

    /// A system notification, the way an antivirus tells you it did something.
    /// A bare `swift run` binary has no bundle to register with the
    /// notification centre and would crash on it, so it is skipped there.
    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
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

        // Any change to the set of mounted vaults is a reason to scan: a new
        // mount needs its full pass, an eject drops its findings.
        let nowMounted = Set(orgs.filter { $0.vault == .mounted }.map(\.name))
        if nowMounted != mountedNames {
            mountedNames = nowMounted
            Task { await runScan() }
        }

        // Runs on the 10-second refresh rather than the scan tick, so the hold
        // time is honoured to the second and the countdown in the UI ticks.
        reloadQuarantine()
        sweepQuarantine()
    }

    /// Purge quarantined originals past their hold time. Only reaches mounted
    /// vaults. Items in a locked vault are ciphertext and simply wait for the
    /// next mount, which is the correct outcome either way.
    func sweepQuarantine() {
        let due = QuarantineService.expired(quarantine, now: Date(), ttl: Self.quarantineTTL)
        guard !due.isEmpty else { return }
        let minutes = Int(Self.quarantineTTL / 60)
        for item in due {
            guard let org = organizations.first(where: { $0.name == item.orgName }) else { continue }
            let root = (org.folderPath as NSString).expandingTildeInPath
            guard let event = try? quarantineService.purge(
                item, vaultRoot: root,
                detail: "Purged automatically \(plural(minutes, "minute")) after quarantine.") else { continue }
            history.actions.insert(event, at: 0)
        }
        historyStore.save(history)
        reloadQuarantine()
    }

    /// Move a misplaced (e.g. Finder-mounted) volume to its canonical path,
    /// or mount an unlocked one. Passphrase-free while keys are cached.
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

    /// UC1/UC4 end to end: enclave key → encrypted vault → git routing.
    /// Every step is verified before the next runs, and a failure leaves the
    /// machine no less protected than it started (I4).
    func createOrganization(name: String, displayName: String, authorName: String,
                            email: String, volumeName: String, passphrase: String) async -> Bool {
        let org = Organization(
            name: name, displayName: displayName,
            gitAuthorName: authorName, gitEmail: email,
            forge: .custom, forgeHost: "", forgeSSHPort: nil,
            folderPath: "~/work/\(name)", keyLabel: "ssh-\(name)",
            signingEnabled: true, vault: .none
        )
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keyPath = "\(home)/.ssh/\(org.keyFileName)"

        guard !organizations.contains(where: { $0.name == name }) else {
            lastError = OrgCreationError.nameTaken(name).localizedDescription
            return false
        }
        do {
            creatingOrg = "Creating the Secure Enclave key. Touch the sensor"
            if await !keys.labels().contains(org.keyLabel) {
                try await keys.createIdentity(label: org.keyLabel)
            }

            creatingOrg = "Exporting the reference key. Touch the sensor"
            try await keys.exportReferenceKey(label: org.keyLabel, to: keyPath)

            creatingOrg = "Creating the encrypted vault"
            try await vaults.createVault(for: org, volumeName: volumeName, passphrase: passphrase)

            creatingOrg = "Writing the git rules"
            try gitConfig.writeOrgConfig(org)
            try gitConfig.addInclude(org)

            creatingOrg = nil
            await runDoctor()
            newKey = (displayName, keys.publicKey(at: keyPath) ?? "")
            return true
        } catch {
            creatingOrg = nil
            lastError = error.localizedDescription
            await runDoctor()
            return false
        }
    }

    func openClone(preferring org: Organization? = nil) {
        cloneTarget = org ?? cloneableOrgs.first
    }

    /// UC8: the reversible part first (git routing), then only what was asked
    /// for. Every destructive step is verified against the system afterwards,
    /// and a failure stops the sequence with the machine in a coherent state.
    func removeOrganization(_ org: Organization, deleteVault: Bool, deleteKey: Bool) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = (org.folderPath as NSString).expandingTildeInPath
        var done: [String] = []
        var todo: [String] = []
        busyOrgs.insert(org.name)
        defer { busyOrgs.remove(org.name); removingOrg = nil }

        do {
            if deleteVault, org.vault != .none {
                if org.vault != .locked {
                    removingOrg = "Ejecting the vault"
                    try await vaults.eject(org)
                }
                removingOrg = "Deleting the vault"
                try await vaults.deleteVault(for: org)
                done.append("Deleted the encrypted volume and its contents.")
            }

            removingOrg = "Removing the git rules"
            try gitConfig.removeOrganization(org)
            done.append("Removed the includeIf rules and ~/.gitconfig-\(org.name).")

            if deleteKey {
                removingOrg = "Deleting the Secure Enclave key"
                try await keys.deleteIdentity(label: org.keyLabel)
                try keys.removeReferenceKey(at: "\(home)/.ssh/\(org.keyFileName)")
                done.append("Deleted \(org.keyLabel) from the Secure Enclave and its reference files.")
                todo.append("Delete the public key from the organization's forge (authentication and signing keys).")
            } else if org.vault != .none || deleteVault {
                todo.append("The Secure Enclave key \(org.keyLabel) was kept.")
            }

            // The placeholder only goes when the vault did: otherwise it is
            // still that volume's mount point for work-on and friends.
            if deleteVault, !vaults.isMountPoint(folder),
               (try? FileManager.default.contentsOfDirectory(atPath: folder))?
                   .filter({ $0 != ".DS_Store" }).isEmpty ?? false {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
                try? FileManager.default.removeItem(atPath: folder)
                done.append("Removed the empty placeholder \(org.folderPath).")
            } else if !deleteVault, org.vault != .none {
                todo.append("The vault volume was kept; mount it with diskutil or add the organization again.")
            }
            todo.append("Remove any Host block for this org in ~/.ssh/config and its line in allowed_signers. Vaultkit does not write those.")

            await runDoctor()
            receipt = RemovalReceipt(org: org.displayName, done: done, todo: todo)
            return true
        } catch {
            lastError = error.localizedDescription
            await runDoctor()
            return false
        }
    }
}

// MARK: - Vault state presentation (one place, palette-driven)

extension VaultState {
    /// Fill/icon colour: vivid.
    func color(_ p: Palette) -> Color {
        switch self {
        case .none: p.label3
        case .locked: p.green
        case .mounted: p.orange
        case .unlocked: p.amber
        case .misplaced: p.red
        }
    }

    /// Text colour: darkened in light mode so captions stay legible.
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

enum SidebarItem: String, CaseIterable, Identifiable, Equatable {
    case dashboard = "Dashboard"
    case organizations = "Organizations"
    case vaults = "Vaults"
    case doctor = "Doctor"
    case scanner = "Scanner"
    case activity = "Activity"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "gauge"
        case .organizations: "person.2.badge.key"
        case .vaults: "lock.square.stack"
        case .doctor: "stethoscope"
        case .scanner: "magnifyingglass"
        case .activity: "waveform.path.ecg.rectangle"
        }
    }

    /// The page's watermark glyph: decorative, and distinct from `icon`.
    var backdropSymbol: String {
        switch self {
        case .dashboard: "shield.lefthalf.filled"
        case .organizations: "building.2.fill"
        case .vaults: "lock.square.stack.fill"
        case .doctor: "waveform.path.ecg"
        case .scanner: "magnifyingglass.circle.fill"
        case .activity: "waveform"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 264)
                .background(p.sidebar)
            Divider().overlay(p.sep2)
            let page = store.selection ?? .dashboard
            Group {
                switch page {
                case .dashboard: DashboardView()
                case .organizations: OrganizationsView()
                case .vaults: VaultsView()
                case .doctor: DoctorView()
                case .scanner: ScannerView()
                case .activity: ActivityView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Animate the content only: animating the sidebar cross-fades the
            // nav highlight and briefly lights two rows.
            .animation(.easeInOut(duration: 0.2), value: page)
            .background { PageBackdrop(symbol: page.backdropSymbol) }
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
        .sheet(isPresented: $store.showAddOrg) { AddOrgSheet() }
        .sheet(item: $store.removeTarget) { org in
            RemoveOrgSheet(org: org)
        }
        .sheet(item: $store.receipt) { receipt in
            ReceiptSheet(receipt: receipt)
        }
        .sheet(isPresented: Binding(
            get: { store.newKey != nil },
            set: { if !$0 { store.newKey = nil } }
        )) {
            if let n = store.newKey { NewKeySheet(org: n.org, publicKey: n.key) }
        }
        .tint(p.accent)
    }
}

/// Joins the parts of a subtitle, skipping any that are empty: an org with no
/// org-level email (its identity may be repo-local) must not render "· key …".
func detailLine(_ parts: String?...) -> String {
    parts.compactMap { $0 }
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .filter { !$0.isEmpty }
         .joined(separator: " · ")
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
        .padding(.bottom, 20)
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
                    row(.scanner, chip: store.scanFindings.isEmpty ? nil : "\(store.scanFindings.count)")
                    row(.activity, chip: store.flaggedActivity == 0 ? nil : "\(store.flaggedActivity)")

                    sectionHead("Manage")
                    row(.organizations, chip: "\(store.organizations.count)")
                    row(.vaults, chip: store.exposedOrgs.isEmpty ? nil : "\(store.exposedOrgs.count) open")
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 12) {
                Divider().overlay(p.sep)
                Text("Vaultkit \(VaultkitVersion.current)\n\(plural(store.organizations.count, "organization")) · \(plural(store.exposedOrgs.count, "vault")) exposed")
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
        let index = (SidebarItem.allCases.firstIndex(of: item) ?? 0) + 1
        return NavRow(
            symbol: item.icon,
            label: item.rawValue,
            chip: chip,
            active: (store.selection ?? .dashboard) == item
        ) { store.selection = item }
        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
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
                Text(detailLine(org.folderPath, org.gitEmail))
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
                    pill("Clone", .accent) { store.cloneTarget = org }
                case .unlocked:
                    link("Mount") { Task { await store.relocate(org) } }
                    link("Secure") { Task { await store.eject(org) } }
                    pill("Clone", .accent) { store.cloneTarget = org }
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
                PillButton(title: working ? "Unlocking" : "Mount", role: .accent, height: 32,
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
            // Multiple vaults can be mounted. The destination is an explicit choice.
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Into")
                Picker("", selection: $selectedName) {
                    ForEach(store.cloneableOrgs) { o in
                        Text("\(o.displayName)  (\(o.folderPath))\(o.vault == .unlocked ? "  (will mount first)" : "")")
                            .tag(o.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 13))
            }
            if let selected {
                Text("Authenticates with \(selected.keyLabel). Expect a Touch ID prompt.")
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
                    Text(pinned ? "\(host): host key pinned & verified"
                                : "\(host) is NOT in known_hosts. Verify and pin it before cloning")
                        .font(.system(size: 12.5))
                }
                .foregroundStyle(pinned ? p.greenText : p.redText)
            }
            HStack(spacing: 10) {
                Spacer()
                PillButton(title: "Cancel", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: working ? "Cloning" : "Clone", role: .accent, height: 32,
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
            PageHeader(title: "Organizations") {
                PillButton(title: "Add Organization", role: .accent, height: 32,
                           hpad: 16, font: .system(size: 13, weight: .semibold)) {
                    store.showAddOrg = true
                }
            }
            if store.organizations.isEmpty {
                VStack(spacing: 16) {
                    EmptyState(
                        symbol: "person.2.badge.key",
                        title: "No organizations yet",
                        message: "An organization is a Secure Enclave key, an encrypted vault, and the git rules binding them to one folder."
                    )
                    PillButton(title: "Add Organization", role: .accent) {
                        store.showAddOrg = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                    Text(detailLine(org.gitEmail, "key \(org.keyLabel)",
                                                    "signing \(org.signingEnabled ? "on" : "off")"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(p.label2)
                                }
                                Spacer(minLength: 0)
                                Text(org.vault.label)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(org.vault.textColor(p))
                                if store.busyOrgs.contains(org.name) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    LinkButton("Remove", color: p.label3, hoverColor: p.redText,
                                               font: .system(size: 12.5, weight: .medium)) {
                                        store.removeTarget = org
                                    }
                                }
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
                Button("Eject \(org.displayName) (mounted)") {
                    Task { await store.eject(org) }
                }
            case .locked:
                Button("Mount \(org.displayName)") {
                    store.selection = .vaults
                    store.mountTarget = org
                    NSApp.activate(ignoringOtherApps: true)
                }
            case .unlocked:
                Button("Secure \(org.displayName) (unlocked, not at rest)") {
                    Task { await store.eject(org) }
                }
            case .misplaced:
                Button("Relocate \(org.displayName) (mounted in the wrong place)") {
                    Task { await store.relocate(org) }
                }
            case .none:
                Text("\(org.displayName) (no vault)")
            }
        }
        Divider()
        if store.compromiseIndicators > 0 {
            Button("Scanner: \(plural(store.compromiseIndicators, "compromise indicator"))") {
                store.selection = .scanner
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            Text(store.scanReport == nil ? "Scanner: no pass yet"
                 : "Scanner: clean · \(ScannerView.relative(store.scanReport!.finishedAt))")
        }
        Button("Scan Now") { Task { await store.runScan() } }
        Divider()
        Button("Refresh") { Task { await store.refresh() } }
        Button("Open Vaultkit") { NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
