import Foundation

/// The four panes of a set's page, in the order the picker shows them.
public enum SetPane: String, CaseIterable, Sendable {
    case status, included, destinations, safety

    public var title: String {
        switch self {
        case .status: "Status"
        case .included: "What's Included"
        case .destinations: "Destinations"
        case .safety: "Safety"
        }
    }
}

/// A notice that needs the owner, so it shows on every pane, not just the one it belongs to.
public enum SetBanner: Equatable, Sendable {
    case nameConflict, previewNeeded
}

public enum SetBanners {
    /// Same on every pane: the owner can't miss one by being on another tab.
    public static func visible(nameConflict: Bool, previewAccepted: Bool, on pane: SetPane) -> [SetBanner] {
        var out: [SetBanner] = []
        if nameConflict { out.append(.nameConflict) }
        if !previewAccepted { out.append(.previewNeeded) }
        return out
    }
}

public enum RuleFilter {
    /// Below this many rules the whole list fits, so no filter field is offered.
    public static let threshold = 10

    public static func offersFilter(ruleCount: Int) -> Bool { ruleCount > threshold }

    /// Ids of the rules to show, in their stored order (the first match wins, so a filter never reorders).
    /// Rules still being typed (empty pattern) and the `keep` ids (the row being edited) always stay, so
    /// a new rule can't be filtered away and an edit can't make its own row vanish under the cursor.
    public static func visibleIDs(_ rules: [UserRule], query: String, keep: Set<UUID> = []) -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard offersFilter(ruleCount: rules.count), !q.isEmpty else { return rules.map(\.id) }
        return rules.filter {
            keep.contains($0.id)
                || $0.pattern.trimmingCharacters(in: .whitespaces).isEmpty
                || $0.pattern.localizedStandardContains(q)
        }.map(\.id)
    }

    /// "24 rules", or "3 of 24 rules" while filtering.
    public static func countText(total: Int, shown: Int) -> String {
        let noun = total == 1 ? "rule" : "rules"
        return shown == total ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}
