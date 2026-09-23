import SwiftUI
import TuganeDesign

/// The few decisions that are the user's to make rather than the app's, and the
/// record of what the guards below have done unattended.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p

    /// A shorter hold can purge things that are still restorable, and the
    /// purge is permanent. Non-nil → the confirmation is up.
    @State private var pendingHold: TimeInterval?
    @AppStorage("vk.theme") private var themeRaw = Theme.dark.rawValue

    private var theme: Theme { Theme(rawValue: themeRaw) ?? .dark }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings") {
                if !store.rewriteAttempts.isEmpty || !store.autoSecureEvents.isEmpty {
                    IconButton(symbol: "trash", help: "Clear the records below") {
                        store.rewriteGuard.forgetAttempts()
                        store.rewriteAttempts = []
                        store.autoSecureEvents = []
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Vaults").padding(.bottom, 10)
                    autoSecureToggle
                    if store.autoSecure.enabled { autoSecureDetail }
                    if !store.autoSecureEvents.isEmpty { autoSecureRecord }

                    SectionLabel("History").padding(.top, 26).padding(.bottom, 10)
                    guardToggle
                    if store.blockRewrites { rewriteExemptions; consequences }
                    if !store.unguardedRepos.isEmpty { conflicts }
                    if !store.rewriteAttempts.isEmpty { refusals }

                    SectionLabel("Scanner").padding(.top, 26).padding(.bottom, 10)
                    quarantineToggle
                    quarantineHold
                    scanExclusions

                    SectionLabel("Notifications").padding(.top, 26).padding(.bottom, 10)
                    notificationChoices

                    SectionLabel("Appearance").padding(.top, 26).padding(.bottom, 10)
                    appearance

                    SectionLabel("Licence").padding(.top, 26).padding(.bottom, 10)
                    licence
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
        .alert("Purge held originals now?", isPresented: showingHoldWarning) {
            Button("Cancel", role: .cancel) { pendingHold = nil }
            Button("Shorten and purge", role: .destructive) {
                if let pendingHold { store.quarantineHold = pendingHold }
                pendingHold = nil
            }
        } message: {
            Text("\(plural(store.quarantineAtRisk(under: pendingHold ?? 0), "quarantined original")) would be older than the new hold and purged on the next sweep. That cannot be undone \u{2014} restore anything you still want first.")
        }
    }

    private var showingHoldWarning: Binding<Bool> {
        Binding(get: { pendingHold != nil }, set: { if !$0 { pendingHold = nil } })
    }

    // MARK: vaults

    private var autoSecureToggle: some View {
        Row(on: store.autoSecure.enabled,
            title: "Secure vaults automatically",
            detail: "An organization's code is only ciphertext while its vault is at rest, and a vault nobody ejects is never at rest. This puts them back by itself.") {
            store.autoSecure.enabled.toggle()
        }
    }

    private var autoSecureDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Field("Secure after") {
                Choices(values: AutoSecurePolicy.idleChoices,
                        selected: store.autoSecure.idleMinutes,
                        label: { $0 < 60 ? "\($0)m" : "\($0 / 60)h" }) {
                    store.autoSecure.idleMinutes = $0
                }
            }

            Field("Also when") {
                VStack(alignment: .leading, spacing: 7) {
                    SubToggle(on: store.autoSecure.onScreenLock, title: "the screen locks") {
                        store.autoSecure.onScreenLock.toggle()
                    }
                    SubToggle(on: store.autoSecure.onSleep, title: "the Mac sleeps") {
                        store.autoSecure.onSleep.toggle()
                    }
                    SubToggle(on: store.autoSecure.onQuit, title: "Vaultkit quits") {
                        store.autoSecure.onQuit.toggle()
                    }
                }
            }

            if store.organizations.count > 1 {
                Field("Never secure") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(store.organizations) { org in
                            SubToggle(on: store.autoSecure.exempt.contains(org.name),
                                      title: org.displayName) {
                                if store.autoSecure.exempt.contains(org.name) {
                                    store.autoSecure.exempt.remove(org.name)
                                } else {
                                    store.autoSecure.exempt.insert(org.name)
                                }
                            }
                        }
                    }
                }
            }

            Note(symbol: "info.circle", tint: p.label3,
                 text: "Re-mounting needs the passphrase again, so a vault secured while you were away costs you one unlock. A vault something is still using is left mounted and named rather than forced shut. Sleep is best effort: macOS does not always allow enough time, and anything left open is picked up on the next idle check.")
        }
    }

    private var autoSecureRecord: some View {
        Record(title: "Secured",
               caption: "What Vaultkit closed on its own, and what it could not.",
               rows: store.autoSecureEvents.prefix(15).map { event in
            switch event.outcome {
            case .secured:
                return Record.Row(id: event.id, symbol: "lock.fill", tint: p.green,
                                  title: event.org, detail: "secured because \(event.trigger.label)", at: event.at)
            case .held(let holders):
                return Record.Row(id: event.id, symbol: "lock.open.trianglebadge.exclamationmark", tint: p.amber,
                                  title: event.org,
                                  detail: holders.isEmpty ? "still in use, left mounted"
                                                          : "held by \(holders.prefix(2).joined(separator: ", ")), left mounted",
                                  at: event.at)
            case .failed(let why):
                return Record.Row(id: event.id, symbol: "exclamationmark.triangle.fill", tint: p.red,
                                  title: event.org, detail: why, at: event.at)
            }
        })
    }

    // MARK: history

    private var guardToggle: some View {
        Row(on: store.blockRewrites,
            title: "Block history rewriting in vaults",
            detail: "Amend, rebase and anything else that replaces a commit is refused inside a mounted vault, and the attempt is recorded. Replacing a commit that is already signed is how an altered one is made to look ordinary, and it erases the mismatch the Doctor reports.") {
            store.blockRewrites.toggle()
        }
    }

    @ViewBuilder
    private var rewriteExemptions: some View {
        if store.organizations.count > 1 {
            Field("Except in") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.organizations) { org in
                        SubToggle(on: store.rewriteExempt.contains(org.name), title: org.displayName) {
                            if store.rewriteExempt.contains(org.name) {
                                store.rewriteExempt.remove(org.name)
                            } else {
                                store.rewriteExempt.insert(org.name)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Said plainly, because it is real friction and finding out by having a
    /// rebase fail mid-flight is a worse way to learn it.
    private var consequences: some View {
        Note(symbol: "info.circle", tint: p.label3,
             text: "Your own rebases and amends are refused too, including rewording the last commit and git pull --rebase. New commits, branches, merges and fetches are untouched. This stops you and it stops a script that runs git; it does not stop something that can write to .git directly, which is why every attempt is recorded rather than only blocked.")
    }

    private var conflicts: some View {
        Note(symbol: "exclamationmark.triangle.fill", tint: p.amber,
             text: "\(plural(store.unguardedRepos.count, "repository", "repositories")) already had a reference-transaction hook from another tool, so \(store.unguardedRepos.count == 1 ? "it is" : "they are") not guarded: \(store.unguardedRepos.joined(separator: ", ")). Vaultkit never overwrites a hook it did not write.")
    }

    private var refusals: some View {
        Record(title: "Refused",
               caption: "Every rewrite the guard turned down. An attempt you did not make is worth reading the Doctor's signature findings over.",
               rows: store.rewriteAttempts.prefix(15).map {
            Record.Row(id: $0.id, symbol: "arrow.uturn.backward.circle.fill", tint: p.amber,
                       title: "\($0.repo) · \($0.branch)",
                       detail: "\($0.oldOID.prefix(7)) would have become \($0.newOID.prefix(7))",
                       at: $0.at)
        })
    }

    // MARK: appearance

    private var appearance: some View {
        Field("Theme") {
            Choices(values: [Theme.dark, .light], selected: theme, label: \.toggleLabel) {
                themeRaw = $0.rawValue
            }
        }
        .padding(.top, 2)
    }

    // MARK: licence

    @ViewBuilder
    private var licence: some View {
        VStack(alignment: .leading, spacing: 0) {
            Field("Status") {
                Text(store.license.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .padding(.top, 1)
            }

            // The offline budget is the part that was invisible: a licence can
            // lapse purely from not reaching the service, and until now the
            // only warning was it going red.
            if case .licensed(let entitlement) = store.license {
                Field("Checked") {
                    Text(offlineLine(entitlement))
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.label2)
                        .padding(.top, 1)
                }
                Field("Renews") {
                    Text(Self.day.string(from: entitlement.periodEnd))
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.label2)
                        .padding(.top, 1)
                }
                Field("This Mac") {
                    Text("\(MachineFingerprint.label) · one of \(plural(Licensing.seats, "seat"))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.label2)
                        .padding(.top, 1)
                }
            }

            Field("") {
                HStack(spacing: 8) {
                    if store.licenseChecking {
                        ProgressView().controlSize(.small).frame(height: 26)
                    } else {
                        PillButton(title: "Check Now", role: .neutral) {
                            Task { await store.refreshLicense(force: true) }
                        }
                    }
                    PillButton(title: store.license.isFull ? "Manage Licence" : "Enter a Licence Key",
                               role: .neutral) { store.showActivation = true }
                }
            }
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// "Verified 3 days ago · works offline for another 18".
    private func offlineLine(_ e: Entitlement) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: e.issuedAt, to: Date()).day ?? 0)
        let left = max(0, Licensing.maxOfflineDays - days)
        let verified = days == 0 ? "Verified today" : "Verified \(plural(days, "day")) ago"
        return left == 0 ? "\(verified) · offline budget spent"
                         : "\(verified) · works offline for another \(plural(left, "day"))"
    }

    // MARK: scanner exclusions

    @ViewBuilder
    private var scanExclusions: some View {
        if !store.organizations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.organizations) { org in
                    Field(org.displayName) {
                        ExclusionField(paths: org.scanExclusions) { paths in
                            Task { await store.setScanExclusions(paths, for: org) }
                        }
                    }
                }
                Note(symbol: "info.circle", tint: p.label3,
                     text: "Directories the Scanner skips, relative to the vault root, separated by commas \u{2014} press Return to apply. Matched a segment at a time, so vendor skips vendor and everything under it and never vendor-utils. Build output and node_modules are already skipped everywhere. Excluding a directory means nothing in it is watched for indicators, so keep the list short.")
            }
            .padding(.top, 10)
        }
    }

    // MARK: notifications

    private var notificationChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            Field("Tell me about") {
                VStack(alignment: .leading, spacing: 7) {
                    SubToggle(on: store.notifications.scannerHits, title: "compromise indicators found") {
                        store.notifications.scannerHits.toggle()
                    }
                    SubToggle(on: store.notifications.rewriteRefusals, title: "refused history rewrites") {
                        store.notifications.rewriteRefusals.toggle()
                    }
                    SubToggle(on: store.notifications.autoSecure, title: "vaults secured, and vaults that would not close") {
                        store.notifications.autoSecure.toggle()
                    }
                }
            }
            Note(symbol: "info.circle", tint: p.label3,
                 text: "Per event, because macOS only offers one switch for the whole app: silencing a chatty Scanner there would also silence the rewrite alarm, which is the one that might mean somebody else is on this Mac. A finding is announced when it first appears and when something is done about it, never once per pass.")
        }
        .padding(.top, 2)
    }

    // MARK: scanner

    private var quarantineHold: some View {
        VStack(alignment: .leading, spacing: 0) {
            Field("Hold originals") {
                Choices(values: QuarantineHold.choices,
                        selected: store.quarantineHold,
                        label: QuarantineHold.short) { chosen in
                    // Lengthening is always safe. Shortening can delete
                    // something still restorable, so it asks.
                    if chosen < store.quarantineHold, store.quarantineAtRisk(under: chosen) > 0 {
                        pendingHold = chosen
                    } else {
                        store.quarantineHold = chosen
                    }
                }
            }
            Note(symbol: "info.circle", tint: p.label3,
                 text: "A quarantined file is moved inside the vault, not deleted, and restoring it is the only way to get it back. After \(QuarantineHold.label(store.quarantineHold)) the original is purged for good. Held bytes stay encrypted at rest and count against the vault's space until then.")
        }
        .padding(.top, 10)
    }

    private var quarantineToggle: some View {
        Row(on: store.autoQuarantine,
            title: "Act on critical hits without asking",
            detail: "An appended loader is cut back to the legitimate config and a malicious artifact is moved to quarantine the moment it is found. Warnings are never actioned on their own.") {
            store.autoQuarantine.toggle()
        }
    }
}

// MARK: - pieces

/// A switch with the reasoning next to it. Every setting here changes what the
/// app will refuse to do, so none of them ship as a bare label.
private struct Row: View {
    let on: Bool
    let title: String
    let detail: String
    let toggle: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 13) {
                CheckBox(on: on).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(p.label2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .card(p.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }
}

/// A labelled sub-control, indented under the switch that enables it.
private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .frame(width: 104, alignment: .leading)
                .padding(.top, 2)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
    }
}

private struct SubToggle: View {
    let on: Bool
    let title: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 9) {
                CheckBox(on: on)
                Text(title).font(.system(size: 12.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
    }
}

/// A one-of-N picker as pills, for values short enough to show them all.
private struct Choices<Value: Hashable>: View {
    let values: [Value]
    let selected: Value
    let label: (Value) -> String
    let pick: (Value) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Button { pick(value) } label: {
                    Text(label(value))
                        .font(.system(size: 12, weight: value == selected ? .semibold : .regular))
                        .foregroundStyle(value == selected ? .white : p.label2)
                        .frame(width: 42, height: 26)
                        .card(value == selected ? p.accent : p.btn, radius: 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverPointer()
            }
        }
    }
}

/// Comma-separated paths, applied on Return. Deliberately not a live binding:
/// every commit re-runs a full scan of that vault.
private struct ExclusionField: View {
    let paths: [String]
    let commit: ([String]) -> Void
    @State private var text = ""
    @Environment(\.palette) private var p

    var body: some View {
        TextField("drizzle, vendor", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .card(p.well, radius: 7)
            .frame(maxWidth: 340)
            .onSubmit { commit(text.components(separatedBy: ",")) }
            .onAppear { text = paths.joined(separator: ", ") }
            .onChange(of: paths) { _, new in text = new.joined(separator: ", ") }
    }
}

private struct Note: View {
    let symbol: String
    let tint: Color
    let text: String
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(tint).padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
    }
}

/// A short list of what a guard did unattended. An automatic action nobody can
/// review is indistinguishable from a bug.
private struct Record: View {
    struct Row: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let at: Date
    }

    let title: String
    let caption: String
    let rows: [Row]
    @Environment(\.palette) private var p

    private var relative: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title).padding(.top, 22).padding(.bottom, 2)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(p.label3)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol).font(.system(size: 13)).foregroundStyle(row.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.system(size: 12.5, weight: .medium))
                        Text("\(row.detail) · \(relative.localizedString(for: row.at, relativeTo: Date()))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.label3)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .card(p.card, radius: 10)
            }
        }
    }
}
