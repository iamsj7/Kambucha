import SwiftUI
import MirrorCore

/// Lists the files a held backup would delete, one destination at a time. Allow Once for a destination launches the
/// agent with that destination's reviewed count only.
struct DeletionReviewSheet: View {
    let model: AppModel
    @State private var review: DeletionReview
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, setID: UUID) {
        self.model = model
        let set = model.set(setID) ?? BackupSet(name: "Unknown", source: URL(fileURLWithPath: "/"))
        let held = DeletionReview.heldDestinations(set: set, destinations: model.destinations, states: model.states)
        _review = State(initialValue: DeletionReview(set: set, destinations: held, provider: model.services.dryRun))
    }

    init(model: AppModel, review: DeletionReview) {
        self.model = model
        _review = State(initialValue: review)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("Deletions held").font(.title2.weight(.semibold)) } icon: { Image(systemName: "pause.circle").font(.title2) }
            Text("These files are gone from \"\(review.set.name)\" but still in the backup. Allow Once removes them from that destination's backup too. Each destination is approved on its own. Keep Holding leaves them there, and new and changed files keep backing up.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if review.entries.isEmpty {
                ContentUnavailableView("Nothing Held", systemImage: "checkmark.circle")
            }
            List {
                ForEach(review.entries) { entry in
                    Section {
                        if let error = entry.loadError {
                            Label(error, systemImage: "exclamationmark.triangle")
                        } else if !entry.isLoaded {
                            ProgressView("Checking what would be deleted…")
                        } else {
                            ForEach(entry.files, id: \.self) { path in
                                Label { Text(path).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "doc") }
                                    .accessibilityLabel("Would delete \(path)")
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(entry.destination.name): \(entry.isLoaded ? entry.count.formatted() : "…") \(entry.count == 1 ? "deletion" : "deletions")")
                            Spacer()
                            Button("Allow Once", role: .destructive) {
                                if let args = review.allowOnceArguments(for: entry.id) { model.allowOnce(arguments: args); dismiss() }
                            }
                            .disabled(review.allowOnceArguments(for: entry.id) == nil)
                            .accessibilityLabel("Allow once for \(entry.destination.name)")
                            .accessibilityHint("Deletes these \(entry.count) files from \(entry.destination.name), one time only")
                        }
                    }
                }
            }
            .frame(minHeight: 200)
            .accessibilityLabel("Files that would be deleted")

            HStack {
                Spacer()
                Button("Keep Holding") { model.keepHolding(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Leaves the deletions on hold")
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .task { await review.load() }
    }
}
