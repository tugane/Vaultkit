import SwiftUI
import TuganeDesign

// MARK: - The strip above the content
//
// A healthy licence says nothing at all. The banner appears in the last week
// of a trial, when a payment is failing, and when a licence has lapsed, and it
// always says what still works — a security tool that hides the state of your
// vaults behind a sales pitch would be a worse product than no product.

struct LicenseBanner: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        if store.license.deservesABanner {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(p.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if case .licensed = store.license {
                    PillButton(title: "Update Billing", role: .accent, height: 28, hpad: 14,
                               radius: 7, font: .system(size: 12.5, weight: .semibold)) {
                        NSWorkspace.shared.open(Licensing.accountURL)
                    }
                } else {
                    PillButton(title: "Enter Key", role: .neutral, height: 28, hpad: 14,
                               radius: 7, font: .system(size: 12.5, weight: .medium)) {
                        store.showActivation = true
                    }
                    PillButton(title: "Subscribe", role: .accent, height: 28, hpad: 14,
                               radius: 7, font: .system(size: 12.5, weight: .semibold)) {
                        NSWorkspace.shared.open(Licensing.purchaseURL)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(tint.opacity(p.isDark ? 0.13 : 0.09))
            .overlay(alignment: .bottom) { Rectangle().fill(p.sep).frame(height: 1) }
        }
    }

    private var symbol: String {
        switch store.license {
        case .trial: "clock.badge.exclamationmark"
        case .licensed: "creditcard.trianglebadge.exclamationmark"
        default: "lock"
        }
    }

    private var tint: Color {
        switch store.license {
        case .trial(let d): d <= 3 ? p.orange : p.amber
        default: p.red
        }
    }

    private var headline: String {
        switch store.license {
        case .trial(let d): d == 1 ? "Last day of the trial" : "\(d) days left in the trial"
        case .licensed: "A payment on this subscription is failing"
        case .trialExpired: "The trial is over"
        case .lapsed: "The subscription has lapsed"
        case .unknown: ""
        }
    }

    private var detail: String {
        switch store.license {
        case .trial:
            "Every feature is on until then. After that, mounting and ejecting your vaults keep working; the Scanner, Activity, adding organizations and cloning need a subscription."
        case .licensed(let e):
            "Stripe will keep retrying until \(Self.day.string(from: e.periodEnd)). Update the card to avoid an interruption."
        case .trialExpired, .lapsed:
            "Your vaults, keys and git routing are untouched and still yours: mounting, ejecting and removing organizations all still work here, and work without Vaultkit at all."
        case .unknown: ""
        }
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - A page you cannot see yet

struct LockedPage: View {
    let feature: Feature
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 18) {
            Mascot(symbol: "lock.shield", tint: p.accent)
                .frame(width: 48, height: 48)

            Text(feature.label)
                .font(.system(size: 19, weight: .bold))

            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(p.label2)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 460)

            HStack(spacing: 10) {
                PillButton(title: "Enter a Licence Key", role: .neutral) { store.showActivation = true }
                PillButton(title: "Subscribe", role: .accent) {
                    NSWorkspace.shared.open(Licensing.purchaseURL)
                }
            }
            .padding(.top, 4)

            Text(store.license.summary)
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        switch feature {
        case .scanner:
            "The Scanner watches every mounted vault for the PolinRider indicator set and for the behavioural shapes that carry no fixed strings. It needs a subscription. Nothing has been disabled on disk: it is simply not running."
        case .activity:
            "Activity lists processes handed their code on the command line, downloads piped into a shell, and third-party login items. It needs a subscription."
        case .addOrganization:
            "Creating an organization provisions a Secure Enclave key, an encrypted vault and the git routing that binds them. It needs a subscription. The organizations you already have keep working."
        case .clone:
            "Cloning into a vault binds the URL, the key and the destination together and refuses a host that is not already pinned. It needs a subscription."
        }
    }
}

// MARK: - The paywall, raised by reaching for something gated

struct PaywallSheet: View {
    let feature: Feature
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Mascot(symbol: "lock.shield", tint: p.accent)
                    .frame(width: 26, height: 26)
                Text("\(feature.label) needs a subscription")
                    .font(.system(size: 15, weight: .bold))
            }

            Text(store.license == .trialExpired
                 ? "The 14-day trial has ended."
                 : "This subscription is no longer current.")
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)

            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("What a subscription covers")
                ForEach(Feature.allCases, id: \.self) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(p.green)
                            .frame(width: 14)
                        Text(f.label).font(.system(size: 12.5)).foregroundStyle(p.label)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p.green)
                        .frame(width: 14)
                    Text("Up to \(Licensing.seats) Macs, and every update for the year")
                        .font(.system(size: 12.5)).foregroundStyle(p.label)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.well))

            Text("Mounting, ejecting and removing your organizations are not on that list, and never will be: your vaults and keys stay reachable whether or not you subscribe.")
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                PillButton(title: "Not Now", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: "Enter Key", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) {
                    dismiss()
                    store.showActivation = true
                }
                PillButton(title: "Subscribe", role: .accent, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) {
                    NSWorkspace.shared.open(Licensing.purchaseURL)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(p.sheet)
    }
}

// MARK: - Entering a key

struct ActivationSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    @State private var key = ""
    @State private var failure: String?

    private var ready: Bool {
        LicenseService.looksLikeAKey(LicenseService.normalise(key)) && !store.activating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Mascot(symbol: "key.horizontal", tint: p.accent)
                    .frame(width: 26, height: 26)
                Text("Activate Vaultkit").font(.system(size: 15, weight: .bold))
            }

            if case .licensed(let e) = store.license {
                activeLicence(e)
            } else {
                entry
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(p.sheet)
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste the key from your receipt. It reads VK-XXXX-XXXX-XXXX-XXXX and covers up to \(Licensing.seats) Macs.")
                .font(.system(size: 12.5))
                .foregroundStyle(p.label2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Licence key")
                TextField("VK-", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13).monospaced())
                    .autocorrectionDisabled()
                    .onSubmit { if ready { activate() } }
                Text("Activating sends the key, a one-way fingerprint of this Mac and its name to the licensing service. Nothing else leaves your Mac. See PRIVACY.md.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.label3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                LinkButton("Buy a licence", color: p.accent, hoverColor: p.accentHover) {
                    NSWorkspace.shared.open(Licensing.purchaseURL)
                }
                Spacer()
                if store.activating { ProgressView().controlSize(.small) }
                PillButton(title: "Cancel", role: .neutral, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) { dismiss() }
                PillButton(title: "Activate", role: .accent, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) { activate() }
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.5)
            }
        }
    }

    private func activeLicence(_ e: Entitlement) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                row("Key", e.maskedKey)
                row("Billed to", e.email)
                row("Plan", e.plan.capitalized)
                row("Renews", LicenseBanner.day.string(from: e.periodEnd))
                row("This Mac", MachineFingerprint.label)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.well))

            Text("Deactivating frees this Mac's seat so the key can be used on another. Your vaults, keys and git routing are not touched.")
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                LinkButton("Manage subscription", color: p.accent, hoverColor: p.accentHover) {
                    NSWorkspace.shared.open(Licensing.accountURL)
                }
                Spacer()
                PillButton(title: "Deactivate This Mac", role: .destructive, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .medium)) {
                    Task { await store.deactivateThisMac(); dismiss() }
                }
                PillButton(title: "Done", role: .accent, height: 32, hpad: 18,
                           radius: 8, font: .system(size: 13, weight: .semibold)) { dismiss() }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 12.5)).foregroundStyle(p.label)
            Spacer(minLength: 0)
        }
    }

    private func activate() {
        failure = nil
        let entered = key
        Task {
            if await store.activate(key: entered) {
                dismiss()
            } else {
                failure = store.lastError
                store.lastError = nil     // shown here, not in the app-wide alert
            }
        }
    }
}

// MARK: - The sidebar's footer line

struct LicenseFooter: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    var body: some View {
        Button { store.showActivation = true } label: {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(store.license.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(p.label3)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PointerButtonStyle())
    }

    private var dot: Color {
        switch store.license {
        case .licensed(let e): e.status == .pastDue ? p.amber : p.green
        case .trial(let d): d <= 3 ? p.orange : p.amber
        case .trialExpired, .lapsed: p.red
        case .unknown: p.label3
        }
    }
}
