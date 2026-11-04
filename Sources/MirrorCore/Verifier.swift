import Foundation

public struct VerifyResult: Equatable, Sendable {
    public var differences: Int
    public var audit: AuditResult
    /// The rclone checks found no differences. Says nothing about uploads.
    public var checksClean: Bool
    /// Files the size check found on both sides, so a whole-set check is the set's file count.
    public var matchingFiles = 0
    /// What the checks named as different, relative to what was checked. May be shorter than
    /// `differences`, so its being empty says nothing.
    public var differingPaths: [String] = []
    /// Asked to be hashed, but evicted, so left unproven. Only the Quick check skips these.
    public var skippedFreed: [String] = []
    /// What a deep check's hash list held. Nil when it compared everything, as on a cloud destination.
    public var hashedPaths: Set<String>?
    /// Evicted files a deep check left out of its sample, so never hashed.
    public var unhashedFreed: [String] = []
    /// The only value that may drive "Backed Up": clean checks and nothing pending, refused or missing.
    public var backedUp: Bool {
        checksClean && audit.pending.isEmpty && audit.refused.isEmpty && audit.missing.isEmpty
    }
    public init(differences: Int, audit: AuditResult, checksClean: Bool? = nil) {
        self.differences = differences; self.audit = audit; self.checksClean = checksClean ?? (differences == 0)
    }
}

public enum VerifyError: Error, Equatable { case checkDidNotComplete(RcloneResult.Outcome), mirrorUnreadable(String) }

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

    /// `auditWholeMirror` is for the daily pass: every file is audited, not just those copied.
    /// `hashCopied` is false when a deep check follows and will hash them anyway.
    public func quick(source: URL, destination: String, profile: DestinationProfile, context: RcloneContext,
                      filter: URL, copied: [String], oneWay: Bool, logDir: URL,
                      auditWholeMirror: Bool = false, hashCopied: Bool = true) async throws -> VerifyResult {
        let size = try await run(CheckRequest(
            source: source, destination: destination, filterFile: filter, filesFrom: nil, sizeOnly: true,
            oneWay: oneWay, cryptCheck: false, context: context, logFile: logDir.appendingPathComponent("quick-size.log")).applying(profile))
        var differences = size.differences
        var differing = size.flagged
        let root = URL(fileURLWithPath: destination)
        // One read decides each file, as iCloud can evict between two.
        var toHash: [String] = [], skipped: [String] = []
        for path in copied {
            if audits(profile), isDataless(root.appendingPathComponent(path)) { skipped.append(path) } else { toHash.append(path) }
        }
        if hashCopied, !toHash.isEmpty {
            let list = try writeList(toHash, to: logDir.appendingPathComponent("quick-copied.list"))
            let hash = try await run(CheckRequest(
                source: source, destination: destination, filterFile: filter, filesFrom: list, sizeOnly: false,
                oneWay: oneWay, cryptCheck: profile.encrypted, context: context,
                logFile: logDir.appendingPathComponent("quick-hash.log")).applying(profile))
            differences += hash.differences
            differing += hash.flagged
        }
        var audit = AuditResult(pending: [], refused: [])
        if audits(profile) {
            // A missing mirror here means nothing was copied: the size check above already compared it.
            // Rclone names a link `x.rclonelink`, but a local mirror holds it as `x`.
            let paths = auditWholeMirror ? Self.files(under: root) ?? []
                : copied.map { $0.hasSuffix(Self.linkSuffix) ? String($0.dropLast(Self.linkSuffix.count)) : $0 }
            audit = try await runAudit(paths.map { root.appendingPathComponent($0) })
        }
        var result = VerifyResult(differences: differences, audit: audit)
        result.matchingFiles = size.matching
        result.differingPaths = differing
        result.skippedFreed = skipped
        return result
    }

    /// Re-reads files already known to be pending or refused.
    public func audit(_ urls: [URL]) async throws -> AuditResult { try await runAudit(urls) }

    /// Off the cooperative pool, like the audit it belongs with.
    public func ubiquity(of url: URL) async -> Bool? {
        let auditor = self.auditor
        return await withCheckedContinuation { continuation in
            Self.auditQueue.async { continuation.resume(returning: auditor.ubiquity(of: url)) }
        }
    }

    /// True when iCloud has evicted this file, so hashing it would download it.
    public func isFreed(_ url: URL) -> Bool { isDataless(url) }

    /// `oneWay` is for a held set, whose mirror keeps extras on purpose.
    public func deep(source: URL, destination: String, profile: DestinationProfile, context: RcloneContext,
                     filter: URL, sampleFreed: Int, logDir: URL, oneWay: Bool = false) async throws -> VerifyResult {
        guard audits(profile) else {
            let check = try await run(CheckRequest(
                source: source, destination: destination, filterFile: filter, filesFrom: nil, sizeOnly: false,
                oneWay: oneWay, cryptCheck: profile.encrypted, context: context,
                logFile: logDir.appendingPathComponent("deep.log")).applying(profile))
            var result = VerifyResult(differences: check.differences, audit: AuditResult(pending: [], refused: []),
                                      checksClean: check.differences == 0)
            result.differingPaths = check.flagged
            return result
        }
        let root = URL(fileURLWithPath: destination)
        // A missing or unreadable mirror must never look like an empty, passing one.
        guard let all = Self.files(under: root) else { throw VerifyError.mirrorUnreadable(destination) }
        // Same filtered size-only check as Quick, so a file missing from the mirror fails Deep too.
        let size = try await run(CheckRequest(
            source: source, destination: destination, filterFile: filter, filesFrom: nil, sizeOnly: true,
            oneWay: oneWay, cryptCheck: false, context: context, logFile: logDir.appendingPathComponent("deep-size.log")).applying(profile))
        var differences = size.differences
        var differing = size.flagged
        var present: [String] = [], freed: [String] = []
        for rel in all {
            if isDataless(root.appendingPathComponent(rel)) { freed.append(rel) } else { present.append(rel) }
        }
        let sampled = Array(freed.shuffled().prefix(max(0, sampleFreed)))
        let list = present + sampled
        if !list.isEmpty {
            // No filter alongside a file list: rclone cannot combine them.
            let hash = try await run(CheckRequest(
                source: source, destination: destination, filterFile: nil,
                filesFrom: try writeList(list, to: logDir.appendingPathComponent("deep.list")),
                sizeOnly: false, oneWay: oneWay, cryptCheck: profile.encrypted, context: context,
                logFile: logDir.appendingPathComponent("deep.log")).applying(profile))
            differences += hash.differences
            differing += hash.flagged
        }
        let audit = try await runAudit((present + freed).map { root.appendingPathComponent($0) })
        var result = VerifyResult(differences: differences, audit: audit)
        result.differingPaths = differing
        result.hashedPaths = Set(list)
        result.unhashedFreed = Array(Set(freed).subtracting(sampled)).sorted()
        return result
    }

    private static let linkSuffix = ".rclonelink"
    private static let auditQueue = DispatchQueue(label: "mirror.upload-audit", qos: .utility)

    /// Audits read resource values from disk, so they run on a dispatch queue, never the cooperative
    /// pool, in batches with a cancellation check between each.
    private func runAudit(_ urls: [URL]) async throws -> AuditResult {
        var total = AuditResult(pending: [], refused: [])
        let auditor = self.auditor
        var i = 0
        while i < urls.count {
            try Task.checkCancellation()
            let batch = Array(urls[i..<min(i + 200, urls.count)])
            let r: AuditResult = await withCheckedContinuation { cont in
                Self.auditQueue.async { cont.resume(returning: auditor.audit(batch)) }
            }
            total.pending += r.pending; total.refused += r.refused; total.missing += r.missing
            i += 200
        }
        return total
    }

    private func run(_ r: CheckRequest) async throws -> LogSummary {
        let res = try await rclone.check(r)
        guard res.outcome == .success else { throw VerifyError.checkDidNotComplete(res.outcome) }
        return res.summary
    }

    private func writeList(_ paths: [String], to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (paths.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Relative paths of every non-directory entry (symlinks included, not followed).
    /// `nil` when the root is missing, not a directory, or unreadable.
    static func files(under root: URL) -> [String]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil,
              let e = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var out: [String] = []
        for case let rel as String in e {
            var st = stat()
            guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) != S_IFDIR { out.append(rel) }
        }
        return out
    }
}
