import SwiftUI
import AppKit
import MirrorCore

/// A review item with the set it belongs to.
struct ReviewEntry: Identifiable, Equatable {
    var id: String { "\(setID)-\(item.id)" }
    var setID: UUID
    var setName: String
    var item: ReviewItem
}

extension AppModel {
    /// Items still waiting for the owner: those with no rule for their path yet, across every set.
    var reviewEntries: [ReviewEntry] {
        var seen = Set<String>()
        var out: [ReviewEntry] = []
        for s in sets {
            let decided = Set(s.rules.map(\.pattern))
            for d in s.destinationIDs {
                for item in states[PairID(set: s.id, destination: d)]?.reviewItems ?? []
                where !decided.contains(item.rulePattern) && seen.insert("\(s.id)-\(item.id)").inserted {
                    out.append(ReviewEntry(setID: s.id, setName: s.name, item: item))
                }
            }
        }
        return out
    }

    func resolve(_ entry: ReviewEntry, include: Bool) {
        guard var s = set(entry.setID), let rule = ReviewActions.rule(for: entry.item, include: include) else { return }
        // The owner just decided this here, so a set that was accepted stays accepted. A set that never was stays unaccepted.
        let wasAccepted = s.isPreviewAccepted
        s.rules.append(rule)
        if wasAccepted { s.acceptPreview() }
        save(set: s)
        // Nothing changed on disk, so the agent would otherwise leave this until the daily pass.
        if include, wasAccepted { runSoon(s.id) }
    }
}

struct OverviewView: View {
    @Bindable var model: AppModel
    var select: (SidebarItem) -> Void

    var body: some View {
        let p = StatusPresentation(model.status)
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: p.symbol).font(.largeTitle).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.title2.weight(.semibold))
                        if let d = p.detail { Text(d).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let held = model.heldSet {
                        Button("Review Deletions") { model.allowDeletes(held.id) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Shows the files that would be deleted from the backup")
                    } else {
                        Button("Back Up Now") { model.runNow(nil) }
                            .disabled(!canBackUp)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            let health = HealthSummary(model.rows.map { SetHealth(id: $0.id, name: $0.name, status: $0.status) })
            if model.rows.isEmpty {
                Section { Text("Add a folder to start backing it up.").foregroundStyle(.secondary) }
            }
            if !health.attention.isEmpty {
                Section("Needs Attention") {
                    ForEach(health.attention) { item in
                        Button { select(.set(item.id)) } label: { AttentionRow(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
            let troubled = model.destinations.filter { needsAttention($0) }
            if !troubled.isEmpty {
                Section("Destinations Needing Attention") {
                    ForEach(troubled) { d in
                        let s = model.destinationStatus(d)
                        Button { select(.destination(d.id)) } label: {
                            LabeledContent {
                                Text(s.text).foregroundStyle(.secondary)
                            } label: {
                                Label(d.name, systemImage: s.symbol)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(d.name), \(s.text)")
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
            let entries = model.reviewEntries
            if !entries.isEmpty {
                Section {
                    ForEach(entries.prefix(Self.reviewLimit)) { ReviewItemRow(entry: $0, model: model) }
                } header: {
                    Text("Items to Review")
                } footer: {
                    Text(entries.count > Self.reviewLimit
                         ? "Showing \(Self.reviewLimit) of \(entries.count.formatted()). These files sit outside your current rules. Nothing blocks your backup while they wait."
                         : "These files sit outside your current rules. Nothing blocks your backup while they wait.")
                }
            }
            if let line = health.countLine {
                Section {
                    Label(summaryText(line, health), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    if !model.destinations.isEmpty {
                        Label(destinationLine(troubled.count), systemImage: "externaldrive").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
    }

    /// Review items are rows with buttons, so only the first are built.
    private static let reviewLimit = 25

    private func summaryText(_ line: String, _ health: HealthSummary) -> String {
        guard let last = health.lastBackup else { return line }
        return "\(line), last backup \(last.formatted(.relative(presentation: .named)))"
    }

    private func destinationLine(_ troubled: Int) -> String {
        let n = model.destinations.count
        let noun = n == 1 ? "destination" : "destinations"
        return troubled == 0 ? "\(n.formatted()) \(noun), all fine" : "\(n.formatted()) \(noun), \(troubled.formatted()) need attention"
    }

    /// The shared health check, plus the two warnings the destination screen raises on its own.
    private func needsAttention(_ d: Destination) -> Bool {
        StatusSummary.destinationHealth(d.id, sets: model.sets, states: model.states).needsAttention
            || model.destinationStatus(d).symbol == "exclamationmark.triangle"
    }

    private var canBackUp: Bool {
        switch model.status {
        case .notConfigured, .paused, .running: false
        default: true
        }
    }
}

struct AttentionRow: View {
    let item: HealthSummary.Item
    var body: some View {
        let p = StatusPresentation(item.status)
        LabeledContent {
            Text(item.status.shortText).foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(item.name, systemImage: p.symbol)
                if let d = p.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(p.title)" + (p.detail.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

struct ReviewItemRow: View {
    let entry: ReviewEntry
    let model: AppModel

    private var reason: String {
        switch entry.item.kind {
        case .trackedInExcluded: "Tracked by git, inside an excluded folder"
        case .secretInExcluded: "Looks like a secret, inside an excluded folder"
        case .refusedByICloud: "iCloud won't accept this file"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.path).lineLimit(1).truncationMode(.middle)
                Text("\(entry.setName). \(reason)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.set(entry.setID).map({ ReviewActions.canInclude(entry.item, in: $0) }) == true {
                Button("Include") { model.resolve(entry, include: true) }
                    .accessibilityLabel("Include \(entry.item.path) in the backup")
            }
            Button("Keep Excluded") { model.resolve(entry, include: false) }
                .accessibilityLabel("Keep \(entry.item.path) excluded")
        }
        .accessibilityElement(children: .contain)
    }
}
