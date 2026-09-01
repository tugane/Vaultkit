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
        // Deliberately not automated: volume creation sets the passphrase, which
        // must never transit the app (I1). The wizard hands the user a terminal
        // command using -passprompt instead.
        throw VaultError.commandFailed("Vault creation is guided, not automated — see UC4.")
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
            if m.status == 0 { return }
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

    private func openGuard(at path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private func closeGuard(at path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
