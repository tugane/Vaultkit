import SwiftUI
import TuganeDesign

/// The few decisions that are the user's to make rather than the app's, and the
/// record of what the guards below have done unattended.
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.palette) private var p


    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings") {
                if !store.rewriteAttempts.isEmpty {
                    IconButton(symbol: "trash", help: "Clear the record of refused rewrites") {
                        store.rewriteGuard.forgetAttempts()
                        store.rewriteAttempts = []
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("History").padding(.bottom, 10)
                    guardToggle
                    if store.blockRewrites { rewriteExemptions; consequences }
                    if !store.unguardedRepos.isEmpty { conflicts }
                    if !store.rewriteAttempts.isEmpty { refusals }

                    SectionLabel("Scanner").padding(.top, 26).padding(.bottom, 10)
                    quarantineToggle


                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
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

    // MARK: scanner

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
/// Comma-separated paths, applied on Return. Deliberately not a live binding:
/// every commit re-runs a full scan of that vault.
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
