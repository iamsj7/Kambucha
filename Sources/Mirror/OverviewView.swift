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

            Section("Backup Sets") {
                if model.rows.isEmpty {
                    Text("Add a folder to start backing it up.").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    Button { select(.set(row.id)) } label: { SetSummaryRow(row: row, model: model) }
                        .buttonStyle(.plain)
                }
            }

            Section("Destinations") {
                if model.destinations.isEmpty {
                    Text("Add a place to keep your backups.").foregroundStyle(.secondary)
                }
                ForEach(model.destinations) { d in
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

            Section {
                let entries = model.reviewEntries
                if entries.isEmpty {
                    Label("Nothing to review", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(entries) { ReviewItemRow(entry: $0, model: model) }
            } header: {
                Text("Items to Review")
            } footer: {
                Text("These files sit outside your current rules. Nothing blocks your backup while they wait.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
    }

    private var canBackUp: Bool {
        switch model.status {
        case .notConfigured, .paused, .running: false
        default: true
        }
    }
}

struct SetSummaryRow: View {
    let row: SetRow
    let model: AppModel
    var body: some View {
        let p = StatusPresentation(row.status)
        let set = model.set(row.id)
        let last = set.flatMap { s in s.destinationIDs.compactMap { model.states[PairID(set: s.id, destination: $0)]?.lastFinished }.max() }
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.status.shortText)
                if let last { Text(last.formatted(.relative(presentation: .named))).font(.caption) }
            }
            .foregroundStyle(.secondary)
        } label: {
            Label(row.name, systemImage: p.symbol)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(p.title)" + (last.map { ", last backed up \($0.formatted(.relative(presentation: .named)))" } ?? ""))
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
