import SwiftUI
import TuganeDesign

/// UC8: offboard an organization. The default is reversible — only the git
/// routing goes. Destroying the vault or the enclave key is opt-in, and the
/// vault needs its name typed back.
struct RemoveOrgSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let org: Organization

    @State private var deleteVault = false
    @State private var deleteKey = false
    @State private var typed = ""

    private var hasVault: Bool { org.vault != .none }
    private var confirmed: Bool { !deleteVault || typed == org.name }
    private var ready: Bool { confirmed && store.removingOrg == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Mascot(symbol: "person.crop.circle.badge.minus", tint: p.red)
                    .frame(width: 26, height: 26)
                Text("Remove \(org.displayName)").font(.system(size: 15, weight: .bold))
            }

            Text("Removes the git rules that route \(org.folderPath) to this identity. The vault and its Secure Enclave key are kept unless you choose otherwise — add the organization again later and both are picked up as they were.")
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)

            VStack(alignment: .leading, spacing: 12) {
                if hasVault {
                    option(on: $deleteVault,
                           title: "Delete the encrypted vault and everything in it",
                           detail: "Currently \(org.vault.label.lowercased()). It is ejected first if needed. There is no recovery.",
                           danger: true)
                }
                option(on: $deleteKey,
                       title: "Delete the Secure Enclave key",
                       detail: "Removes \(org.keyLabel) from the enclave and ~/.ssh/\(org.keyFileName). The public key registered on the forge is yours to delete.",
                       danger: false)
            }

            if deleteVault {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Type \(org.name) to confirm the vault deletion")
                    TextField(org.name, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13).monospaced())
                        .autocorrectionDisabled()
                }
            }

            if let step = store.removingOrg {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 12.5)).foregroundStyle(p.label2)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                PillButton(title: "Cancel", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: deleteVault ? "Remove and Delete Vault" : "Remove",
                           role: .destructive, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) {
                    Task {
                        let ok = await store.removeOrganization(org, deleteVault: deleteVault, deleteKey: deleteKey)
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

    private func option(on: Binding<Bool>, title: String, detail: String, danger: Bool) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                CheckBox(on: on.wrappedValue).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(danger && on.wrappedValue ? p.redText : p.label)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(p.label3)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
    }
}

/// What was done, and the two things no app can do for you.
struct ReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let receipt: RemovalReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Mascot(symbol: "checkmark.seal.fill", tint: p.green)
                    .frame(width: 26, height: 26)
                Text("\(receipt.org) removed").font(.system(size: 15, weight: .bold))
            }
            list("Done", receipt.done, "checkmark", p.greenText)
            if !receipt.todo.isEmpty {
                list("Still yours to do", receipt.todo, "arrow.right", p.amberText)
            }
            HStack {
                Spacer()
                PillButton(title: "Done", role: .accent, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(p.sheet)
    }

    private func list(_ title: String, _ items: [String], _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                        .padding(.top, 2)
                    Text(item)
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.label2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
