import Foundation

enum VaultError: LocalizedError {
    case volumeNotFound(String)
    case unlockFailed(String)
    case busy(holders: [String])
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .volumeNotFound(let name):
            "No APFS volume named \"\(name)\" exists. Create the vault first."
        case .unlockFailed(let detail):
            "Unlock failed: \(detail)"
        case .busy(let holders):
            holders.isEmpty
                ? "The vault is busy — likely Spotlight indexing or an antivirus scan (root processes). It usually frees up within a minute."
                : "The vault is held open by: \(holders.joined(separator: ", ")). Close them (or cd out) and retry."
        case .commandFailed(let detail):
            detail
        }
    }
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
    private let diskutil = "/usr/sbin/diskutil"

    init(runner: any SystemCommandRunning = ProcessRunner()) {
        self.runner = runner
    }

    // MARK: volume inventory

    struct VolumeInfo {
        let deviceIdentifier: String   // "disk3s7"
        let name: String               // "WeCreate"
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
        var volumes: [VolumeInfo] = []
        for container in containers {
            for vol in container["Volumes"] as? [[String: Any]] ?? [] {
                guard let dev = vol["DeviceIdentifier"] as? String,
                      let name = vol["Name"] as? String else { continue }
                let mountPoint = (vol["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                // "Locked" is authoritative when present; otherwise a mounted
                // volume is necessarily unlocked, and only FileVault volumes
                // can be locked at all.
                let locked = (vol["Locked"] as? Bool)
                    ?? (mountPoint == nil && ((vol["FileVault"] as? Bool) ?? false))
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

    /// The Mac's main APFS container — the one holding the system Data volume.
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
    /// is never persisted (documented I1 deviation — see data-flow.md).
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

        // When keys are cached (unlocked-but-unmounted — TM snapshots, or the
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
            // Not mounted — but cached keys mean the data is NOT at rest.
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
                    // Unmount alone can leave keys cached — best-effort lock.
                    _ = try? await runner.run(diskutil, ["apfs", "lockVolume", vol.deviceIdentifier])
                }
            }
            guard r.status == 0 else { throw VaultError.busy(holders: []) }
        }
        closeGuard(at: canonical)
        try await ensureLocked(vol.deviceIdentifier)
    }

    /// diskutil lockVolume can report success while a mounted Time Machine
    /// snapshot still references the volume's keys — the volume silently stays
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
            throw VaultError.commandFailed("The volume still reports unlocked after locking — a Time Machine snapshot or other system service is holding its keys. Try again in a minute.")
        }
    }

    private func isLocked(_ device: String) async -> Bool {
        guard let vols = try? await listVolumes() else { return false }
        return vols.first { $0.deviceIdentifier == device }?.locked ?? false
    }

    func dissenters(for org: Organization) async throws -> [String] {
        let path = (try? await volume(for: org))?.mountPoint ?? expand(org.folderPath)
        return await holders(at: path)
    }

    private func holders(at path: String) async -> [String] {
        // lsof exits non-zero when it finds nothing; parse whatever came back.
        guard let r = try? await runner.run("/usr/sbin/lsof", [path]) else { return [] }
        return r.stdout
            .split(separator: "\n")
            .dropFirst() // header
            .compactMap { line -> String? in
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 2 else { return nil }
                return "\(cols[0]) (pid \(cols[1]))"
            }
            .reduce(into: [String]()) { acc, item in if !acc.contains(item) { acc.append(item) } }
    }

    // MARK: placeholder guard
    //
    // The guard exists to make the *placeholder* unwritable while a vault is
    // locked, so nothing lands on the bare disk to be shadowed at mount time.
    // It must never touch a mounted volume: chmod follows the path, so closing
    // the guard over a live mount rewrites the volume ROOT's permissions, and
    // that mode is stored inside the volume — every future mount comes back
    // unreadable. diskutil can report a successful lock while the volume is
    // still mounted, so "we just locked it" is not evidence enough; check.

    /// True when `path` is itself a mount point (not the bare placeholder).
    func isMountPoint(_ path: String) -> Bool {
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
