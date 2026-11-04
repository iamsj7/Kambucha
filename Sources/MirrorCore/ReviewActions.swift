import Foundation

/// What the owner may do with each kind of review item.
public enum ReviewActions {
    /// The anchored rule for exactly this file, or nil when this choice has none.
    public static func rule(for item: ReviewItem, include: Bool) -> UserRule? {
        if include && item.kind == .refusedByICloud { return nil }
        return UserRule(pattern: "/" + FilterBuilder.escape(item.path), action: include ? .include : .exclude)
    }
}
