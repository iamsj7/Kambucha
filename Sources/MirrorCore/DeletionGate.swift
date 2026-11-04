import Foundation

public enum DeletionDecision: Equatable { case proceed(maxDelete: Int), hold(count: Int) }

/// Decides whether a sync pass that would delete files should be held for review (spec section 10).
///
/// Files under any `.git` directory are excluded from the hold decision.
public struct DeletionGate {
    /// Slack added to `maxDelete` on proceed so small drift in the live tree does not abort a pass.
    private static let extraDeleteMargin = 10

    /// `approvedDeletions` is the non-.git deletion count the owner reviewed and approved.
    /// The hold is skipped only when the current non-.git count is at or below it.
    public static func decide(deletions: [String], totalFiles: Int, policy: DeletionPolicy,
                              approvedDeletions: Int?) -> DeletionDecision {
        let nonGit = deletions.reduce(into: 0) { count, path in
            if !isUnderGit(path) { count += 1 }
        }
        let overPercent = Double(nonGit) > Double(totalFiles) * policy.percent / 100
        let overMinimum = nonGit >= policy.minFiles && overPercent
        let overAbsolute = nonGit > policy.absoluteMax
        let approved = approvedDeletions.map { nonGit <= $0 } ?? false
        if !approved && (overMinimum || overAbsolute) {
            return .hold(count: nonGit)
        }
        // An approval is exact: `--max-delete` stops at what the owner reviewed, plus uncounted `.git` churn.
        if approved, let approvedDeletions { return .proceed(maxDelete: approvedDeletions + deletions.count - nonGit) }
        return .proceed(maxDelete: deletions.count + extraDeleteMargin)
    }

    /// How many of these count toward a hold.
    public static func countable(_ deletions: [String]) -> Int { deletions.count { !isUnderGit($0) } }

    static func isUnderGit(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains(".git")
    }
}
