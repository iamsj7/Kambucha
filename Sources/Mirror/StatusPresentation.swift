import SwiftUI
import MirrorCore

/// Words and symbols for each status. Status is always text plus a symbol, never colour alone.
struct StatusPresentation {
    let symbol: String
    let title: String
    let detail: String?

    init(_ s: OverallStatus) {
        switch s {
        case .backedUp(let last, let files):
            symbol = "checkmark.icloud"; title = "Backed Up"
            detail = "\(files.formatted()) files, \(last.formatted(.relative(presentation: .named)))"
        case .uploading(let n):
            symbol = "arrow.clockwise.icloud"; title = "Uploading \(n.formatted()) \(n == 1 ? "file" : "files")"
            detail = nil
        case .waitingForDownload(let n):
            symbol = "exclamationmark.icloud"; title = "Files Didn't Match"
            detail = StatusSummary.recheckText(count: n)
        case .notAccepted(let n):
            symbol = "icloud.slash"; title = StatusSummary.notAcceptedText(count: n)
            detail = "Mirror will tell you if this hasn't changed after a day."
        case .unfinished:
            symbol = "icloud"; title = "Backup Not Finished"; detail = "It picks up at the next run."
        case .running:
            symbol = "arrow.clockwise.icloud"; title = "Backing Up"; detail = nil
        case .held(let n):
            symbol = "pause.circle"; title = "\(n.formatted()) \(n == 1 ? "deletion" : "deletions") held"
            detail = "New and changed files still back up. Deletions wait for your review."
        case .attention(let why):
            symbol = "exclamationmark.icloud"; title = "Needs Attention"; detail = why
        case .paused:
            symbol = "pause.circle"; title = "Paused"; detail = "Backups are turned off."
        case .notConfigured:
            symbol = "icloud"; title = "Not Set Up"; detail = "Open Mirror to choose what to back up."
        }
    }
}
