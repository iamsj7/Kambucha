import Foundation

/// What the owner may do with each kind of review item.
public enum ReviewActions {
    /// With Secrets off, a secret stays out whatever the owner's rules say, so an Include would do nothing.
    public static func canInclude(_ item: ReviewItem, in set: BackupSet) -> Bool {
        switch item.kind {
        case .refusedByICloud: false
        case .secretInExcluded: set.backupSecrets
        case .trackedInExcluded: true
        }
    }

    /// The anchored rule for exactly this file or folder, or nil when this choice has none.
    public static func rule(for item: ReviewItem, include: Bool) -> UserRule? {
        if include && item.kind == .refusedByICloud { return nil }
        return UserRule(pattern: item.rulePattern, action: include ? .include : .exclude)
    }
}
