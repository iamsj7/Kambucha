import Foundation

/// What the owner may do with each kind of review item. A file iCloud freed and Mirror is still verifying is
/// not a decision: no rule may ever be made for it, since excluding it would drop a real file from the backup.
public enum ReviewActions {
    public static let downloadingReason = "iCloud is downloading this file so Mirror can verify it"

    public static func canChangeRules(_ kind: ReviewItem.Kind) -> Bool { kind != .unprovenFreed }
    public static func showsInFinder(_ kind: ReviewItem.Kind) -> Bool { kind == .unprovenFreed }

    /// The anchored rule for exactly this file, or nil when this kind (or this choice) has none.
    public static func rule(for item: ReviewItem, include: Bool) -> UserRule? {
        guard canChangeRules(item.kind) else { return nil }
        if include && item.kind == .refusedByICloud { return nil }
        return UserRule(pattern: "/" + FilterBuilder.escape(item.path), action: include ? .include : .exclude)
    }

    public static func waitingText(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Waiting for iCloud to download \(count.formatted()) \(count == 1 ? "file" : "files") to verify"
    }
}
