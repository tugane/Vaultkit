import SwiftUI
import TuganeDesign

/// UC1/UC4: create an organization end to end: Secure Enclave key, encrypted
/// vault, git identity routing, then hand back the public key to register.
struct AddOrgSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    @State private var name = ""            // folder slug, e.g. "acme"
    @State private var displayName = ""
    @State private var authorName = ""
    @State private var email = ""
    @State private var passphrase = ""
    @State private var confirm = ""

    private var slug: String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
    private var volumeName: String {
        displayName.isEmpty ? slug.capitalized
            : displayName.filter { $0.isLetter || $0.isNumber }
    }
    private var passphraseOK: Bool { passphrase.count >= 8 && passphrase == confirm }
    private var ready: Bool {
        !slug.isEmpty && !authorName.isEmpty && email.contains("@")
            && passphraseOK && store.creatingOrg == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Mascot(symbol: "plus.rectangle.on.folder", tint: p.accent)
                    .frame(width: 26, height: 26)
                Text("Add an organization").font(.system(size: 15, weight: .bold))
            }

            Text("Creates a Touch ID-gated key in the Secure Enclave, an encrypted vault at ~/work/\(slug.isEmpty ? "<name>" : slug), and the git rules that bind them together.")
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)

            HStack(spacing: 12) {
                field("Folder name", "acme", $name)
                field("Display name", "Acme Inc", $displayName)
            }
            HStack(spacing: 12) {
                field("Your name", "Ada Lovelace", $authorName)
                field("Email for this org", "you@acme.com", $email)
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Vault passphrase")
                HStack(spacing: 12) {
                    SecureField("at least 8 characters", text: $passphrase)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                    SecureField("confirm", text: $confirm)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                }
                Text("Store it in a password manager that is not on this Mac. There is no recovery: lose it and the vault's contents are gone.")
                    .font(.system(size: 12))
                    .foregroundStyle(!confirm.isEmpty && passphrase != confirm ? p.redText : p.label3)
                    .lineSpacing(2)
            }

            if let step = store.creatingOrg {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 12.5)).foregroundStyle(p.label2)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                PillButton(title: "Cancel", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: "Create", role: .accent, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) {
                    let pass = passphrase
                    passphrase = ""; confirm = ""      // release the visible buffers
                    Task {
                        let ok = await store.createOrganization(
                            name: slug, displayName: displayName.isEmpty ? slug.capitalized : displayName,
                            authorName: authorName, email: email,
                            volumeName: volumeName, passphrase: pass
                        )
                        if ok { dismiss() }
                    }
                }
                .disabled(!ready)
                .opacity(ready ? 1 : 0.5)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(p.sheet)
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(label)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .autocorrectionDisabled()
        }
    }
}

/// Shown after a successful creation: the one thing still to do by hand.
struct NewKeySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let org: String
    let publicKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Mascot(symbol: "checkmark.seal.fill", tint: p.green)
                    .frame(width: 26, height: 26)
                Text("\(org) is ready").font(.system(size: 15, weight: .bold))
            }
            Text("The vault is mounted and git is routed. Register this public key on that organization's forge: once as an authentication key, and again as a signing key where the forge separates them.")
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
            ScrollView {
                Text(publicKey)
                    .font(.system(size: 11.5).monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 74)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.well))
            HStack(spacing: 10) {
                PillButton(title: "Copy Key", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                }
                Spacer()
                PillButton(title: "Done", role: .accent, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(p.sheet)
    }
}
