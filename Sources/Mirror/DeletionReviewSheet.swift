import SwiftUI
import MirrorCore

/// Lists the files a held backup would delete. Allow Once launches the agent with the reviewed count.
struct DeletionReviewSheet: View {
    let model: AppModel
    @State private var review: DeletionReview
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, setID: UUID) {
        self.model = model
        let set = model.set(setID) ?? BackupSet(name: "Unknown", source: URL(fileURLWithPath: "/"))
        _review = State(initialValue: DeletionReview(set: set, provider: model.services.dryRun))
    }

    init(model: AppModel, review: DeletionReview) {
        self.model = model
        _review = State(initialValue: review)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(headline).font(.title2.weight(.semibold))
            } icon: { Image(systemName: "pause.circle").font(.title2) }
            Text("These files are gone from \"\(review.set.name)\" but still in the backup. Allow Once removes them from the backup too. Keep Holding leaves them there, and new and changed files keep backing up.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = review.loadError {
                ContentUnavailableView("List Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !review.isLoaded {
                ProgressView("Checking what would be deleted…").frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(review.files, id: \.self) { path in
                    Label { Text(path).lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: "doc") }
                        .accessibilityLabel("Would delete \(path)")
                }
                .frame(minHeight: 180)
                .accessibilityLabel("Files that would be deleted")
            }

            HStack {
                Spacer()
                Button("Keep Holding") { model.keepHolding(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Leaves the deletions on hold")
                Button("Allow Once", role: .destructive) {
                    if let args = review.allowOnceArguments { model.allowOnce(arguments: args); dismiss() }
                }
                .disabled(review.allowOnceArguments == nil)
                .accessibilityHint("Deletes these \(review.count) files from the backup, one time only")
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
        .task { await review.load() }
    }

    private var headline: String {
        review.isLoaded ? "\(review.count.formatted()) \(review.count == 1 ? "deletion" : "deletions") held" : "Deletions held"
    }
}
