import Foundation

/// Preview acceptance lives on the set (`acceptedFingerprint`), so the agent can read it from `sets.json`
/// and refuse to back up a set whose preview was never accepted (spec section 9). Plain JSON, no secrets.
extension BackupSet {
    /// What the owner accepts in the preview: stacks, switches and rules. A rename, a pause, the destinations
    /// and the archive period are not part of it.
    public var previewFingerprint: String {
        let rules = self.rules.map { "\($0.action.rawValue):\($0.pattern)" }.joined(separator: "\n")
        return ["presets=" + presets.sorted().joined(separator: ","), "secrets=\(backupSecrets)",
                "git=\(backupGit)", rules].joined(separator: "|")
    }

    public var isPreviewAccepted: Bool { acceptedFingerprint == previewFingerprint }

    public mutating func acceptPreview() { acceptedFingerprint = previewFingerprint }
}
