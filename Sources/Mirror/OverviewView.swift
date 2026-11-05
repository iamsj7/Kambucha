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

/// One set's review items, for the list of all of them.
struct ReviewGroup: Identifiable {
    var id: UUID
    var name: String
    var entries: [ReviewEntry]

    /// In the order the sets first appear.
    static func grouped(_ entries: [ReviewEntry]) -> [ReviewGroup] {
        var out: [ReviewGroup] = []
        var index: [UUID: Int] = [:]
        for e in entries {
            if let i = index[e.setID] { out[i].entries.append(e); continue }
            index[e.setID] = out.count
            out.append(ReviewGroup(id: e.setID, name: e.setName, entries: [e]))
        }
        return out
    }

    /// Review items are rows with buttons, so the Overview builds only the first.
    static let overviewLimit = 25

    /// An item past the limit must not have to wait for earlier ones to be decided.
    static func needsShowAll(count: Int) -> Bool { count > overviewLimit }
}

/// A destination as the Overview says it. `standing` picks the row and the summary line, and `status` words it.
struct OverviewDestination: Identifiable {
    var destination: Destination
    var standing: DestinationStanding
    var status: DestinationStatus
    var id: UUID { destination.id }
}

extension AppModel {
    /// Before the first read of the mounted drives no drive is called away, as the status files aren't either.
    var overviewDestinations: [OverviewDestination] {
        let away = volumeCache.hasLoaded ? ExternalVolume.disconnected(destinations, in: volumeCache.volumes) : []
        return destinations.map { d in
            let health = StatusSummary.destinationHealth(d.id, sets: sets, states: states)
            let status = destinationStatus(d)
            let standing = DestinationStanding(health, driveAway: away.contains(d.id), warned: status.symbol == "exclamationmark.triangle")
            // A drive's status stops at "Not connected", which wouldn't say why it's listed.
            let worded = standing == .attention && away.contains(d.id) ? DestinationStatus(health) : status
            return OverviewDestination(destination: d, standing: standing, status: worded)
        }
    }
}

struct OverviewView: View {
    @Bindable var model: AppModel
    var select: (SidebarItem) -> Void
    @State private var showingAllReview = false

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
            let prompts = OverviewPrompts.lines(hasSets: !model.rows.isEmpty, hasDestinations: !model.destinations.isEmpty)
            if !prompts.isEmpty {
                Section {
                    ForEach(prompts, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
            if !health.attention.isEmpty {
                Section("Needs Attention") {
                    ForEach(health.attention) { item in
                        Button { SetPaneMemory.openOnStatus(); select(.set(item.id)) } label: { AttentionRow(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
            let destinations = model.overviewDestinations
            let troubled = destinations.filter { $0.standing == .attention }
            if !troubled.isEmpty {
                Section("Destinations Needing Attention") {
                    ForEach(troubled) { row in
                        let s = row.status
                        Button { select(.destination(row.id)) } label: {
                            LabeledContent {
                                Text(s.text).foregroundStyle(.secondary)
                            } label: {
                                Label(row.destination.name, systemImage: s.symbol)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.destination.name), \(s.text)")
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
            let entries = model.reviewEntries
            if !entries.isEmpty {
                Section {
                    ForEach(entries.prefix(ReviewGroup.overviewLimit)) { ReviewItemRow(entry: $0, model: model) }
                    if ReviewGroup.needsShowAll(count: entries.count) {
                        Button("Show All…") { showingAllReview = true }
                            .accessibilityHint("Lists every item to review, by set")
                    }
                } header: {
                    Text("Items to Review")
                } footer: {
                    Text(entries.count > ReviewGroup.overviewLimit
                         ? "Showing \(ReviewGroup.overviewLimit) of \(entries.count.formatted()). These files sit outside your current rules. Nothing blocks your backup while they wait."
                         : "These files sit outside your current rules. Nothing blocks your backup while they wait.")
                }
            }
            if let line = health.countLine {
                Section {
                    Label(summaryText(line, health), systemImage: health.allBackedUp ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(.secondary)
                    if let line = DestinationSummary.line(destinations.map(\.standing)) {
                        Label(line, systemImage: "externaldrive").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .sheet(isPresented: $showingAllReview) { ReviewAllSheet(model: model) }
    }

    private func summaryText(_ line: String, _ health: HealthSummary) -> String {
        guard let last = health.lastBackup else { return line }
        return "\(line), last backup \(last.formatted(.relative(presentation: .named)))"
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

/// Every item to review, by set. A List, so only the rows on screen are built.
struct ReviewAllSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entries = model.reviewEntries
        VStack(spacing: 0) {
            List {
                ForEach(ReviewGroup.grouped(entries)) { group in
                    Section(group.name) {
                        ForEach(group.entries) { ReviewItemRow(entry: $0, model: model) }
                    }
                }
            }
            Divider()
            HStack {
                Text(entries.count == 1 ? "1 item" : "\(entries.count.formatted()) items").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .onChange(of: entries.isEmpty) { _, empty in if empty { dismiss() } }
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
