import Foundation

public enum DeletionDecision: Equatable { case proceed(maxDelete: Int), hold(count: Int) }

/// Decides whether a sync pass that would delete files should be held for review (spec section 10).
public struct DeletionGate {
    /// Files under any `.git` directory are excluded from the hold decision.
    private static let extraDeleteMargin = 10

    public static func decide(deletions: [String], totalFiles: Int, policy: DeletionPolicy,
                              allowOnce: Bool) -> DeletionDecision {
        let nonGit = deletions.reduce(into: 0) { count, path in
            if !isUnderGit(path) { count += 1 }
        }
        let overPercent = Double(nonGit) > Double(totalFiles) * policy.percent / 100
        let overMinimum = nonGit >= policy.minFiles && overPercent
        let overAbsolute = nonGit > policy.absoluteMax
        if !allowOnce && (overMinimum || overAbsolute) {
            return .hold(count: deletions.count)
        }
        return .proceed(maxDelete: deletions.count + extraDeleteMargin)
    }

    private static func isUnderGit(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains(".git")
    }
}
