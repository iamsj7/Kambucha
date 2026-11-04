import Foundation

public struct VerifyResult: Equatable, Sendable {
    public var differences: Int
    public var audit: AuditResult
    /// True when the rclone checks found no differences. Pending uploads do not fail it; the caller
    /// must still read `audit` before showing "Backed Up" (needs nothing pending or refused).
    public var passed: Bool
    public init(differences: Int, audit: AuditResult, passed: Bool) {
        self.differences = differences; self.audit = audit; self.passed = passed
    }
}

public enum VerifyError: Error, Equatable { case checkDidNotComplete(RcloneResult.Outcome) }

public struct Verifier: Sendable {
    let rclone: any RcloneRunning
    let auditor: any UploadAuditing
    let isDataless: @Sendable (URL) -> Bool

    public init(rclone: any RcloneRunning, auditor: any UploadAuditing) {
        self.init(rclone: rclone, auditor: auditor, isDataless: Dataless.isDataless)
    }
    init(rclone: any RcloneRunning, auditor: any UploadAuditing, isDataless: @escaping @Sendable (URL) -> Bool) {
        self.rclone = rclone; self.auditor = auditor; self.isDataless = isDataless
    }

    /// Kinds whose destination is a local folder iCloud syncs. A later `externalDrive` kind is
    /// deliberately not here: it verifies like a local folder with no upload audit.
    private func audits(_ p: DestinationProfile) -> Bool { p.kind == .iCloudFolder }

    public func quick(source: URL, destination: String, profile: DestinationProfile, context: RcloneContext,
                      filter: URL, copied: [String], oneWay: Bool, logDir: URL) async throws -> VerifyResult {
        var differences = 0
        differences += try await run(CheckRequest(
            source: source, destination: destination, filterFile: filter, filesFrom: nil, sizeOnly: true,
            oneWay: oneWay, cryptCheck: false, context: context, logFile: logDir.appendingPathComponent("quick-size.log")))
        var toHash = copied
        let root = URL(fileURLWithPath: destination)
        if audits(profile) { toHash = copied.filter { !isDataless(root.appendingPathComponent($0)) } }
        if !toHash.isEmpty {
            let list = try writeList(toHash, to: logDir.appendingPathComponent("quick-copied.list"))
            differences += try await run(CheckRequest(
                source: source, destination: destination, filterFile: filter, filesFrom: list, sizeOnly: false,
                oneWay: oneWay, cryptCheck: profile.encrypted, context: context,
                logFile: logDir.appendingPathComponent("quick-hash.log")))
        }
        var audit = AuditResult(pending: [], refused: [])
        if audits(profile) { audit = auditor.audit(copied.map { root.appendingPathComponent($0) }) }
        return VerifyResult(differences: differences, audit: audit, passed: differences == 0)
    }

    public func deep(source: URL, destination: String, profile: DestinationProfile, context: RcloneContext,
                     filter: URL, sampleFreed: Int, logDir: URL) async throws -> VerifyResult {
        guard audits(profile) else {
            let d = try await run(CheckRequest(
                source: source, destination: destination, filterFile: filter, filesFrom: nil, sizeOnly: false,
                oneWay: false, cryptCheck: profile.encrypted, context: context,
                logFile: logDir.appendingPathComponent("deep.log")))
            return VerifyResult(differences: d, audit: AuditResult(pending: [], refused: []), passed: d == 0)
        }
        let root = URL(fileURLWithPath: destination)
        var present: [String] = [], freed: [String] = []
        for rel in Self.files(under: root) {
            if isDataless(root.appendingPathComponent(rel)) { freed.append(rel) } else { present.append(rel) }
        }
        let sampled = Array(freed.shuffled().prefix(max(0, sampleFreed)))
        let list = present + sampled
        var differences = 0
        if !list.isEmpty {
            // No filter alongside --files-from: rclone cannot combine them.
            differences = try await run(CheckRequest(
                source: source, destination: destination, filterFile: nil,
                filesFrom: try writeList(list, to: logDir.appendingPathComponent("deep.list")),
                sizeOnly: false, oneWay: false, cryptCheck: profile.encrypted, context: context,
                logFile: logDir.appendingPathComponent("deep.log")))
        }
        let audit = auditor.audit((present + freed).map { root.appendingPathComponent($0) })
        return VerifyResult(differences: differences, audit: audit, passed: differences == 0)
    }

    private func run(_ r: CheckRequest) async throws -> Int {
        let res = try await rclone.check(r)
        guard res.outcome == .success else { throw VerifyError.checkDidNotComplete(res.outcome) }
        return res.summary.differences
    }

    private func writeList(_ paths: [String], to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (paths.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Relative paths of every non-directory entry (symlinks included, not followed).
    static func files(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [String] = []
        for case let rel as String in e {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) != S_IFDIR { out.append(rel) }
        }
        return out
    }
}
