import Foundation
import Security
import CryptoKit

// MARK: - Where licence state lives
//
// Not UserDefaults: a plist a user can edit is a licence a user can edit, and
// deleting the app would silently hand out a fresh trial. The login keychain
// survives reinstalls and is ACL'd to this signed application.

protocol SecretStoring: Sendable {
    func read(_ account: String) -> Data?
    func write(_ data: Data, to account: String)
    func delete(_ account: String)
}

struct KeychainStore: SecretStoring {
    /// Distinct from any service the rest of the app uses: this holds licence
    /// state, never anything of the user's.
    static let service = "com.tugane.Vaultkit.licence"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func write(_ data: Data, to account: String) {
        let q = query(account)
        // kSecAttrAccessibleAfterFirstUnlock, not WhenUnlocked: the menu-bar
        // extra and the launch-time refresh both run before anyone touches the
        // keyboard, and a licence check that fails on a locked screen would
        // paywall a Mac that simply had not been used yet today.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// In-memory double for the tests.
final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init(_ seed: [String: Data] = [:]) { items = seed }

    func read(_ account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }
    func write(_ data: Data, to account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account] = data
    }
    func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }
}

// MARK: - Which Mac this is

enum MachineFingerprint {
    /// A stable, opaque, one-way identifier for this Mac, used only to count
    /// seats. PRIVACY.md promises the hardware UUID itself is never sent, so it
    /// is hashed with a fixed salt before it leaves this function, and the raw
    /// value is not returned to any caller.
    static var current: String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 5, tv_nsec: 0)
        // gethostuuid rather than IOKit: no framework to link, and it is denied
        // only under the app sandbox, which Vaultkit deliberately does not use.
        guard gethostuuid(&bytes, &wait) == 0 else { return "unknown-machine" }

        var hasher = SHA256()
        hasher.update(data: Data("vaultkit.seat.v1".utf8))
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The name the user gave this Mac, so a seat is recognisable in their
    /// account page. Sent once, at activation (PRIVACY.md).
    static var label: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "A Mac" : name
    }
}

// MARK: - Verifying what the service said

/// The service signs every entitlement with the Vaultkit release key. The app
/// carries only the public half, so a cached entitlement cannot be forged by
/// editing it, and a man in the middle cannot mint one by terminating TLS.
struct SignedEnvelope: Codable, Equatable {
    let payload: String      // base64 of the entitlement JSON
    let signature: String    // base64 Ed25519 over the UTF-8 bytes of `payload`

    /// Verifies, then decodes. Returns nil on any failure: a bad signature and
    /// a malformed payload are the same answer to the caller, which is "no".
    func open(with publicKeyBase64: String = Licensing.signingPublicKey) -> Entitlement? {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: signature),
              key.isValidSignature(signature, for: Data(payload.utf8)),
              let json = Data(base64Encoded: payload)
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Entitlement.self, from: json)
    }
}
