import Foundation

enum VaultError: LocalizedError {
    case volumeNotFound(String)
    case unlockFailed(String)
    case busy(holders: [VaultHolder])
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .volumeNotFound(let name):
            "No APFS volume named \"\(name)\" exists. Create the vault first."
        case .unlockFailed(let detail):
            "Unlock failed: \(detail)"
        case .busy(let holders):
            holders.isEmpty
                ? "The vault is busy, likely Spotlight indexing or an antivirus scan (root processes). It usually frees up within a minute."
                : "The vault is held open by: \(holders.map(\.label).joined(separator: ", "))."
        case .commandFailed(let detail):
            detail
        }
    }
}

/// A process keeping a vault mounted. lsof truncates command names to nine
/// characters unless told otherwise, which turned Docker's helper into
/// "com.docke", so the full name is asked for and kept.
struct VaultHolder: Equatable, Identifiable, Sendable {
    var pid: Int32
    var command: String
    var user: String
    /// Owned by whoever is running this app. Anything else (root's Spotlight,
    /// an antivirus) can only be stopped by its owner, so it is named and
    /// never signalled.
    var isMine: Bool

    var id: Int32 { pid }
    var label: String { "\(command) (pid \(pid))" }
}

/// Real VaultServing backed by `diskutil apfs`, encoding the behaviors proven
/// by the manual work-on/work-off scripts:
///  - guard the placeholder dir (chmod 000 when not mounted, 700 while mounted)
///  - fail closed: a cancelled/failed unlock re-closes the guard
///  - unlocked-but-unmounted (cached keys, e.g. via TM snapshots) is NOT at
///    rest: surfaced as .unlocked, and eject drops the keys
///  - non-canonical mounts (Finder's /Volumes/<Name>) are moved to the org path
///  - eject dissent: name user-level holders via lsof at the real mount point;
///    when lsof sees nothing, infer a root-level holder, back off and retry
final class DiskUtilVaultService: VaultServing, @unchecked Sendable {
    private let runner: any SystemCommandRunning
    private let mountTable: @Sendable () -> [String: String]
    private let diskutil = "/usr/sbin/diskutil"

    /// `mountTable` maps device paths ("/dev/disk3s9") to mount points. The
    /// default reads the kernel; tests inject a fixed one.
    init(runner: any SystemCommandRunning = ProcessRunner(),
         mountTable: @escaping @Sendable () -> [String: String] = DiskUtilVaultService.kernelMountTable) {
        self.runner = runner
        self.mountTable = mountTable
    }

    /// The kernel's own mount table, one syscall. Needed because
    /// `diskutil apfs list -plist` omits MountPoint for a volume mounted
    /// anywhere but /Volumes. Exactly where every vault lives: while its
    /// text output and `diskutil info` both report it. Snapshot mounts carry
    /// a "…@/dev/diskN" source and so never collide with the bare device key.
    static func kernelMountTable() -> [String: String] {
        var buf: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo(&buf, MNT_NOWAIT)      // buffer is libc-owned; never freed
        guard let buf, n > 0 else { return [:] }
        var table: [String: String] = [:]
        for i in 0..<Int(n) {
            var fs = buf[i]
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let on = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            table[from] = on
        }
        return table
    }

    // MARK: volume inventory

    struct VolumeInfo {
        let deviceIdentifier: String   // "disk3s7"
        let name: String               // "Acme"
        let locked: Bool               // false while keys are cached, even if unmounted
        let mountPoint: String?        // nil when not mounted
    }

    func listVolumes() async throws -> [VolumeInfo] {
        let r = try await runner.run(diskutil, ["apfs", "list", "-plist"])
        guard r.status == 0, let data = r.stdout.data(using: .utf8) else {
            throw VaultError.commandFailed("diskutil apfs list failed: \(r.stderr)")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else {
            throw VaultError.commandFailed("Unexpected diskutil plist shape")
        }
        let mounts = mountTable()
        var volumes: [VolumeInfo] = []
        for container in containers {
            for vol in container["Volumes"] as? [[String: Any]] ?? [] {
                guard let dev = vol["DeviceIdentifier"] as? String,
                      let name = vol["Name"] as? String else { continue }
                // The kernel fills in what the plist leaves out (see above).
                let mountPoint = (vol["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? mounts["/dev/\(dev)"]
                // A mounted volume is necessarily unlocked. Otherwise "Locked"
                // is authoritative when present, and only FileVault volumes
                // can be locked at all.
                let locked = mountPoint != nil ? false
                    : ((vol["Locked"] as? Bool) ?? ((vol["FileVault"] as? Bool) ?? false))
                volumes.append(VolumeInfo(
                    deviceIdentifier: dev,
                    name: name,
                    locked: locked,
                    mountPoint: mountPoint
                ))
            }
        }
        return volumes
    }

    private func derive(_ vol: VolumeInfo, canonical: String) -> VaultState {
        if let mp = vol.mountPoint { return mp == canonical ? .mounted : .misplaced }
        return vol.locked ? .locked : .unlocked
    }

    /// Bulk state lookup: one `diskutil apfs list` for all orgs.
    func states(for orgs: [Organization]) async -> [String: VaultState] {
        guard let vols = try? await listVolumes() else { return [:] }
        var result: [String: VaultState] = [:]
        for org in orgs {
            let vol = vols.first { $0.name.lowercased() == org.name.lowercased() }
            result[org.name] = vol.map { derive($0, canonical: expand(org.folderPath)) } ?? VaultState.none
        }
        return result
    }

    private func volume(for org: Organization) async throws -> VolumeInfo {
        let all = try await listVolumes()
        guard let match = all.first(where: { $0.name.lowercased() == org.name.lowercased() }) else {
            throw VaultError.volumeNotFound(org.name)
        }
        return match
    }

    // MARK: VaultServing

    func state(of org: Organization) async throws -> VaultState {
        guard let vol = try? await volume(for: org) else { return .none }
        return derive(vol, canonical: expand(org.folderPath))
    }

    func createVault(for org: Organization) async throws {
        throw VaultError.commandFailed("Use createVault(for:volumeName:passphrase:).")
    }

    /// The Mac's main APFS container: the one holding the system Data volume.
    func primaryContainer() async throws -> String {
        let r = try await runner.run(diskutil, ["apfs", "list", "-plist"])
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else {
            throw VaultError.commandFailed("Could not read the APFS container list.")
        }
        for c in containers {
            let volumes = c["Volumes"] as? [[String: Any]] ?? []
            let isSystem = volumes.contains { ($0["MountPoint"] as? String) == "/System/Volumes/Data" }
            if isSystem, let ref = c["ContainerReference"] as? String { return ref }
        }
        guard let first = containers.first?["ContainerReference"] as? String else {
            throw VaultError.commandFailed("No APFS container found.")
        }
        return first
    }

    /// Create the org's encrypted volume and mount it at its canonical path.
    /// The passphrase transits app memory once, piped to -stdinpassphrase, and
    /// is never persisted (documented I1 deviation. See data-flow.md).
    func createVault(for org: Organization, volumeName: String, passphrase: String) async throws {
        let existing = (try? await listVolumes()) ?? []
        guard !existing.contains(where: { $0.name.lowercased() == volumeName.lowercased() }) else {
            throw VaultError.commandFailed("A volume named \"\(volumeName)\" already exists.")
        }
        let container = try await primaryContainer()
        let mountPoint = expand(org.folderPath)
        openGuard(at: mountPoint)

        let r = try await runner.run(
            diskutil,
            ["apfs", "addVolume", container, "APFS", volumeName,
             "-stdinpassphrase", "-mountpoint", mountPoint],
            stdin: passphrase
        )
        // diskutil prints failures to stdout and can still exit 0, so confirm
        // against the real state rather than trusting the status code.
        let created = (try? await listVolumes())?.contains {
            $0.name.lowercased() == volumeName.lowercased() && $0.mountPoint == mountPoint
        } ?? false
        guard created else {
            closeGuard(at: mountPoint)   // fail closed (I4)
            let detail = [r.stderr, r.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "diskutil did not create the volume"
            throw VaultError.commandFailed(detail)
        }
    }

    func mount(_ org: Organization, passphrase: String) async throws {
        let vol = try await volume(for: org)
        let canonical = expand(org.folderPath)

        if let mp = vol.mountPoint {
            if mp == canonical { return } // already where it belongs
            // Mounted at a non-canonical path (e.g. Finder's /Volumes/<Name>):
            // move it, or the org's includeIf/direnv config never activates.
            let u = try await runner.run(diskutil, ["unmount", mp])
            guard u.status == 0 else { throw VaultError.busy(holders: await holders(at: mp)) }
        }

        openGuard(at: canonical)

        // When keys are cached (unlocked-but-unmounted: TM snapshots, or the
        // unmount above) a plain mount needs no passphrase. Only try it in that
        // state: on a locked volume it can only fail (or prompt interactively).
        if !vol.locked {
            let m = try await runner.run(diskutil, ["mount", "-mountPoint", canonical, vol.deviceIdentifier])
            if m.status == 0 { repairMountedRoot(at: canonical); return }
        }

        let r = try await runner.run(
            diskutil,
            ["apfs", "unlockVolume", vol.deviceIdentifier, "-stdinpassphrase", "-mountpoint", canonical],
            stdin: passphrase
        )
        guard r.status == 0 else {
            closeGuard(at: canonical) // fail closed (I4)
            // diskutil writes error prose to stdout, not stderr
            let detail = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "unknown diskutil failure"
            throw VaultError.unlockFailed(detail)
        }
        repairMountedRoot(at: canonical)
    }

    func eject(_ org: Organization) async throws {
        let vol = try await volume(for: org)
        let canonical = expand(org.folderPath)

        guard let mountPoint = vol.mountPoint else {
            // Not mounted, but cached keys mean the data is NOT at rest.
            // Lock to drop them; only then is the eject honest.
            if !vol.locked {
                let r = try await runner.run(diskutil, ["apfs", "lockVolume", vol.deviceIdentifier])
                guard r.status == 0 else {
                    throw VaultError.commandFailed("Volume is unlocked and could not be locked: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
                }
            }
            closeGuard(at: canonical)
            try await ensureLocked(vol.deviceIdentifier)
            return
        }

        var r = try await runner.run(diskutil, ["apfs", "lockVolume", vol.deviceIdentifier])
        if r.status != 0 {
            let held = await holders(at: mountPoint)
            if !held.isEmpty {
                throw VaultError.busy(holders: held)
            }
            // No user-level holders: root process (Spotlight/AV). Back off, retry once.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            r = try await runner.run(diskutil, ["apfs", "lockVolume", vol.deviceIdentifier])
            if r.status != 0 {
                r = try await runner.run(diskutil, ["unmount", mountPoint])
                if r.status == 0 {
                    // Unmount alone can leave keys cached: best-effort lock.
                    _ = try? await runner.run(diskutil, ["apfs", "lockVolume", vol.deviceIdentifier])
                }
            }
            guard r.status == 0 else { throw VaultError.busy(holders: []) }
        }
        closeGuard(at: canonical)
        try await ensureLocked(vol.deviceIdentifier)
    }

    /// diskutil lockVolume can report success while a mounted Time Machine
    /// snapshot still references the volume's keys. The volume silently stays
    /// unlocked. Verify, evict snapshot mounts, relock, and only then believe it.
    private func ensureLocked(_ device: String) async throws {
        if await isLocked(device) { return }
        let m = try await runner.run("/sbin/mount", [])
        for line in m.stdout.split(separator: "\n") where line.contains("@/dev/\(device) on ") {
            if let start = line.range(of: " on "), let end = line.range(of: " (apfs") {
                let snapshotPath = String(line[start.upperBound..<end.lowerBound])
                _ = try? await runner.run(diskutil, ["unmount", snapshotPath])
            }
        }
        _ = try? await runner.run(diskutil, ["apfs", "lockVolume", device])
        guard await isLocked(device) else {
            throw VaultError.commandFailed("The volume still reports unlocked after locking. A Time Machine snapshot or other system service is holding its keys. Try again in a minute.")
        }
    }

    private func isLocked(_ device: String) async -> Bool {
        guard let vols = try? await listVolumes() else { return false }
        return vols.first { $0.deviceIdentifier == device }?.locked ?? false
    }

    /// Destroy the org's volume and everything in it (UC8). Refuses while
    /// mounted: the caller ejects first, so dissenters get named rather than
    /// force-unmounted. diskutil can exit 0 on failure, so the volume list is
    /// re-read and the deletion is only believed once the volume is gone.
    func deleteVault(for org: Organization) async throws {
        let vol = try await volume(for: org)
        if let mp = vol.mountPoint {
            throw VaultError.commandFailed("The vault is still mounted at \(mp). Eject it first.")
        }
        let r = try await runner.run(diskutil, ["apfs", "deleteVolume", vol.deviceIdentifier])
        let remaining = (try? await listVolumes()) ?? []
        if remaining.contains(where: { $0.deviceIdentifier == vol.deviceIdentifier }) {
            let detail = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "diskutil did not remove the volume"
            throw VaultError.commandFailed(detail)
        }
    }

    func dissenters(for org: Organization) async throws -> [VaultHolder] {
        let path = (try? await volume(for: org))?.mountPoint ?? expand(org.folderPath)
        return await holders(at: path)
    }

    func holders(at path: String) async -> [VaultHolder] {
        // lsof exits non-zero when it finds nothing; parse whatever came back.
        // +c 0 keeps full command names, and -F prints one field per line, so
        // a command containing spaces cannot be split into the wrong columns.
        guard let r = try? await runner.run("/usr/sbin/lsof", ["+c", "0", "-F", "pcLu", path])
        else { return [] }
        return Self.parseHolders(r.stdout)
    }

    /// lsof -F output: one field per line, the first character naming it.
    /// A "p" line starts a new process, so it flushes the previous one.
    static func parseHolders(_ text: String, currentUID: uid_t = getuid()) -> [VaultHolder] {
        var out: [VaultHolder] = []
        var pid: Int32?
        var command = ""
        var user = ""
        var uid: uid_t?
        func flush() {
            guard let pid, !out.contains(where: { $0.pid == pid }) else { return }
            out.append(VaultHolder(pid: pid, command: command.isEmpty ? "unknown" : command,
                                   user: user, isMine: uid == currentUID))
        }
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": flush(); pid = Int32(value); command = ""; user = ""; uid = nil
            case "c": command = value
            case "L": user = value
            case "u": uid = uid_t(value)
            default: break
            }
        }
        flush()
        return out
    }

    /// Which holders this app may signal at all. Its own process must never be
    /// on the list: it would take the app down in the middle of an eject.
    static func signalable(_ holders: [VaultHolder], selfPID: Int32 = getpid()) -> [VaultHolder] {
        holders.filter { $0.isMine && $0.pid > 1 && $0.pid != selfPID }
    }

    /// Ask the holders to quit, returning the ones actually signalled.
    /// SIGTERM by default: a process that is asked gets to flush its buffers
    /// and save. SIGKILL can do neither, so forcing is a separate decision
    /// taken above this line, never an automatic escalation.
    @discardableResult
    func askToQuit(_ holders: [VaultHolder], force: Bool = false) -> [VaultHolder] {
        let targets = Self.signalable(holders)
        for holder in targets { kill(holder.pid, force ? SIGKILL : SIGTERM) }
        return targets
    }

    // MARK: placeholder guard
    //
    // The guard exists to make the *placeholder* unwritable while a vault is
    // locked, so nothing lands on the bare disk to be shadowed at mount time.
    // It must never touch a mounted volume: chmod follows the path, so closing
    // the guard over a live mount rewrites the volume ROOT's permissions, and
    // that mode is stored inside the volume. Every future mount comes back
    // unreadable. diskutil can report a successful lock while the volume is
    // still mounted, so "we just locked it" is not evidence enough; check.

    /// True when `path` is itself a mount point (not the bare placeholder).
    func isMountPoint(_ path: String) -> Bool { Self.isMountPoint(path) }

    static func isMountPoint(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        // "/" is its own parent, so the device comparison below can't see it.
        if (path as NSString).standardizingPath == "/" { return true }
        let parent = (path as NSString).deletingLastPathComponent
        guard let here = try? fm.attributesOfItem(atPath: path),
              let up = try? fm.attributesOfItem(atPath: parent) else { return false }
        // A different device number than the parent ⇒ a filesystem is mounted here.
        return (here[.systemNumber] as? Int) != (up[.systemNumber] as? Int)
    }

    // MARK: guard drift
    //
    // A guard goes stale whenever a vault is put at rest by something other
    // than this app: an eject from Finder, work-off, a reboot. The placeholder
    // comes back at the 700 it was opened to for the mount, writable, so
    // anything saved there lands on the plain disk and is shadowed at the next
    // mount. Nothing in the app is running at that moment to close it, so the
    // store repairs it on its next refresh.

    enum GuardRepair: Equatable {
        case closed
        case alreadyClosed
        /// A live volume sits on the path. chmod follows it and would rewrite
        /// the volume root, whose mode is stored inside the volume.
        case skippedMounted
        /// Plaintext is already trapped there. Closing the guard would hide it
        /// from the rescue the "Files trapped" finding is asking for.
        case skippedOccupied
        /// Changed moments ago: most likely a mount in progress, by this app or
        /// by work-on, which opens the guard and then waits on a passphrase.
        case skippedRecent
        case missing
    }

    /// How long a guard must have sat unchanged before it counts as drift
    /// rather than a mount in progress. work-on opens the guard and then
    /// prompts, so the window is as long as a person takes to type.
    static let guardGrace: TimeInterval = 120

    /// Finder writes this into any folder it shows. It is not user data, and
    /// counting it as trapped would leave every guard Finder looked at open.
    static let finderMetadata: Set<String> = [".DS_Store"]

    /// Close a placeholder guard that has drifted open. Every condition is read
    /// from the filesystem at the moment of acting, never from the app's cached
    /// vault state, because that cached state is precisely what may be stale.
    /// An explicit Fix press passes `grace: 0, requireEmpty: false`; the
    /// mount-point test is never skippable.
    static func recloseGuard(at path: String, now: Date = Date(),
                             grace: TimeInterval = guardGrace,
                             requireEmpty: Bool = true) -> GuardRepair {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .missing }
        guard !isMountPoint(path) else { return .skippedMounted }
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? NSNumber else { return .missing }
        if mode.intValue == 0 { return .alreadyClosed }
        if requireEmpty {
            let items = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if items.contains(where: { !finderMetadata.contains($0) }) { return .skippedOccupied }
        }
        if grace > 0 {
            // ctime, not mtime: chmod updates it, so a guard opened for a mount
            // looks recent even though nothing inside it changed.
            var st = stat()
            if stat(path, &st) == 0 {
                let changed = Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec))
                if now.timeIntervalSince(changed) < grace { return .skippedRecent }
            }
        }
        // Once more, immediately before acting. This narrows the window rather
        // than closing it (there is no atomic chmod-unless-mounted), and a root
        // left at 000 by that microsecond race is repaired on the next mount by
        // repairMountedRoot. It is still the one mistake worth checking twice.
        guard !isMountPoint(path) else { return .skippedMounted }
        do { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path) } catch { return .missing }
        return .closed
    }

    private func openGuard(at path: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    /// Repair a volume root left at 0o000 by an earlier mis-aimed guard, so a
    /// vault damaged by older builds becomes usable again on next mount.
    private func repairMountedRoot(at path: String) {
        let fm = FileManager.default
        guard isMountPoint(path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue == 0 else { return }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private func closeGuard(at path: String) {
        guard !isMountPoint(path) else { return }   // never lock out a live volume
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
