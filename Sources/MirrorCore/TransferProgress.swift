import Foundation

public struct TransferProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case scanning, transferring, verifying, waitingForICloud }
    public var pair: PairID
    public var phase: Phase
    public var bytesDone: Int64
    /// Nil when no reliable total exists. Never a guess.
    public var bytesTotal: Int64?
    public var filesDone: Int
    public var filesTotal: Int?
    public var bytesPerSecond: Double?
    public var eta: TimeInterval?
    /// True when `eta` is derived (iCloud file counts) rather than reported by rclone.
    public var etaIsEstimate: Bool
    public var updated: Date

    public init(pair: PairID, phase: Phase, bytesDone: Int64 = 0, bytesTotal: Int64? = nil, filesDone: Int = 0,
                filesTotal: Int? = nil, bytesPerSecond: Double? = nil, eta: TimeInterval? = nil,
                etaIsEstimate: Bool = false, updated: Date) {
        self.pair = pair; self.phase = phase; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.filesDone = filesDone; self.filesTotal = filesTotal; self.bytesPerSecond = bytesPerSecond
        self.eta = eta; self.etaIsEstimate = etaIsEstimate; self.updated = updated
    }

    /// 0...1 when a total is known, else nil (show an indeterminate bar).
    public var fraction: Double? {
        if let t = bytesTotal, t > 0 { return min(max(Double(bytesDone) / Double(t), 0), 1) }
        if bytesTotal == nil, let t = filesTotal, t > 0 { return min(max(Double(filesDone) / Double(t), 0), 1) }
        return nil
    }

    /// From an rclone stats line. Missing or zero totals stay nil; rclone's own ETA is used as given.
    public init(pair: PairID, stats s: RcloneStats, now: Date) {
        let transferring = s.bytesTotal != nil || s.filesTotal != nil
        self.init(pair: pair, phase: transferring ? .transferring : .scanning,
                  bytesDone: s.bytes, bytesTotal: s.bytesTotal, filesDone: s.filesDone, filesTotal: s.filesTotal,
                  bytesPerSecond: s.speed, eta: ETAGuard.sanitize(eta: s.eta, rate: s.speed), etaIsEstimate: false, updated: now)
    }

    /// iCloud has no byte-accurate upload figure, so progress counts files and the ETA is marked an estimate.
    /// `filesPerSecond` comes from a `RateEstimator` fed with the done-count.
    public static func iCloud(pair: PairID, filesDone: Int, filesTotal: Int?, filesPerSecond: Double?,
                              now: Date) -> TransferProgress {
        var eta: TimeInterval?
        if let total = filesTotal, let r = filesPerSecond, r > 0, total >= filesDone {
            let e = Double(total - filesDone) / r
            eta = e <= ETAGuard.maximumETA ? e : nil   // a files-per-second rate has no byte floor
        }
        return TransferProgress(pair: pair, phase: .waitingForICloud, filesDone: filesDone, filesTotal: filesTotal,
                                eta: eta, etaIsEstimate: true, updated: now)
    }
}

/// One small JSON file per pair under `<root>/progress/`, written by the agent and read by the app.
public struct ProgressStore: Sendable {
    public static let minInterval: TimeInterval = 2
    public static let staleAfter: TimeInterval = 30
    let dir: URL

    public init(root: URL) { dir = root.appendingPathComponent("progress", isDirectory: true) }

    private func url(_ p: PairID) -> URL { dir.appendingPathComponent("\(p.set.uuidString)-\(p.destination.uuidString).json") }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// Writes at most once per two seconds per pair (by `updated`); a phase change always goes through.
    public func write(_ progress: TransferProgress) throws {
        let (enc, dec) = Self.coder()
        let file = url(progress.pair)
        if let old = (try? Data(contentsOf: file)).flatMap({ try? dec.decode(TransferProgress.self, from: $0) }),
           old.phase == progress.phase {
            let gap = progress.updated.timeIntervalSince(old.updated)
            if gap >= 0 && gap < Self.minInterval { return }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try enc.encode(progress).write(to: file, options: .atomic)
    }

    public func clear(_ pair: PairID) throws {
        let file = url(pair)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Entries updated within the last 30 seconds. An older one belongs to a killed agent and shows nothing.
    public func all(now: Date) throws -> [TransferProgress] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let (_, dec) = Self.coder()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let p = (try? Data(contentsOf: f)).flatMap({ try? dec.decode(TransferProgress.self, from: $0) }) else { return nil }
            return abs(now.timeIntervalSince(p.updated)) <= Self.staleAfter ? p : nil
        }
    }
}
