import Foundation

// MARK: - Offboarding (UC8)
//
// Removal is layered so the reversible part is the default. Removing the git
// rules alone leaves the vault and the key intact: add the organization back
// and both are picked up as they were. Destroying the vault and deleting the
// enclave identity are opt-in, separately, and the vault needs its name typed.

extension GitConfigService {

    /// Drop every includeIf block that routes to the org's config file: the
    /// ~/work/<org>/ rule and any /Volumes/<Name>/ fallback, then delete the
    /// file. Everything else in ~/.gitconfig is preserved byte for byte.
    func removeOrganization(_ org: Organization) throws {
        let path = "\(home)/.gitconfig"
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let kept = Self.strippingIncludes(pointingTo: "~/.gitconfig-\(org.name)", from: text)
            if kept != text {
                try kept.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let perOrg = "\(home)/.gitconfig-\(org.name)"
        if FileManager.default.fileExists(atPath: perOrg) {
            try FileManager.default.removeItem(atPath: perOrg)
        }
    }

    /// Pure: remove `[includeIf …]` sections whose `path` is `target`.
    static func strippingIncludes(pointingTo target: String, from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("[includeIf ") else {
                out.append(line); i += 1; continue
            }
            // Gather the section: header plus lines until the next header.
            var j = i + 1
            while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("[") { j += 1 }
            let section = lines[i..<j]
            let routesHere = section.dropFirst().contains { raw in
                let t = raw.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("path") else { return false }
                let value = t.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
                return value == target
            }
            if !routesHere { out += section }
            i = j
        }
        return out.joined(separator: "\n")
    }
}

extension EnclaveKeyService {

    /// `sc_auth delete-ctk-identity` addresses identities by public-key hash,
    /// so resolve the label first.
    func identityHash(label: String) async -> String? {
        guard let r = try? await runner.run("/usr/sbin/sc_auth", ["list-ctk-identities"]) else { return nil }
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // Key Type / Hash / Prot / Label …
            if cols.count >= 4, cols[3] == label[...] { return String(cols[1]) }
        }
        return nil
    }

    /// Remove the identity from the Secure Enclave. Verified against the
    /// listing afterwards rather than trusting the exit status.
    func deleteIdentity(label: String) async throws {
        guard let hash = await identityHash(label: label) else { return }   // already gone
        let r = try await runner.run("/usr/sbin/sc_auth", ["delete-ctk-identity", "-h", hash])
        guard await !labels().contains(label) else {
            let detail = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "sc_auth still lists the identity"
            throw OrgCreationError.step("Deleting the Secure Enclave key", detail)
        }
    }

    /// The reference handle and its public half. Useless without the enclave,
    /// but no reason to leave them around.
    func removeReferenceKey(at path: String) throws {
        let fm = FileManager.default
        for p in [path, path + ".pub"] where fm.fileExists(atPath: p) {
            try fm.removeItem(atPath: p)
        }
    }
}
