// Proof-only code. Compiled only with -DMIRROR_PROBES (scripts/build-app.sh --proofs).
#if MIRROR_PROBES
import CoreServices
import Foundation
import UserNotifications

/// Gate 1 and gate 4 proofs. Not part of the engine.
enum Probe {
    static let iCloud = NSString(string: "~/Library/Mobile Documents/com~apple~CloudDocs").expandingTildeInPath
    static let documents = NSString(string: "~/Documents").expandingTildeInPath

    static func log(_ line: String) {
        let dir = NSString(string: "~/Library/Logs/Mirror").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/probe.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print(line)
    }

    static func canList(_ path: String) -> String {
        do {
            let n = try FileManager.default.contentsOfDirectory(atPath: path).count
            return "OK (\(n) entries)"
        } catch { return "FAIL (\(error.localizedDescription))" }
    }

    static func rcloneList() -> String {
        // Never derive the executable path from argv: resolve it from the enclosing bundle.
        let rclone = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rclone)
        p.arguments = ["lsd", iCloud, "--max-depth", "1"]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return "FAIL (spawn: \(error.localizedDescription))" }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            return "OK (\(String(decoding: o, as: UTF8.self).split(separator: "\n").count) dirs)"
        }
        return "FAIL (exit \(p.terminationStatus): \(String(decoding: e, as: UTF8.self).prefix(200)))"
    }

    static func notification() async -> String {
        // UNUserNotificationCenter traps when the process has no bundle identifier.
        guard Bundle.main.bundleIdentifier != nil else {
            return "FAIL (no bundle identifier: agent is a bare executable; fallback is launching `Mirror --notify <problem-id>`)"
        }
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            guard granted else { return "FAIL (authorization denied)" }
            let c = UNMutableNotificationContent()
            c.title = "Mirror probe"; c.body = "Notification from MirrorAgent"
            try await center.add(UNNotificationRequest(identifier: "probe", content: c, trigger: nil))
            return "OK (posted)"
        } catch { return "FAIL (\(error.localizedDescription))" }
    }

    static func run() async {
        log("probe start pid=\(getpid()) bundleID=\(Bundle.main.bundleIdentifier ?? "none") bundle=\(Bundle.main.bundleURL.path)")
        log("list iCloud Drive: \(canList(iCloud))")
        log("list ~/Documents: \(canList(documents))")
        log("rclone lsd iCloud: \(rcloneList())")
        log("notification: \(await notification())")
        log("probe end")
    }

    // MARK: Gate 4

    final class Box: @unchecked Sendable {
        var historyDone = false
    }

    /// `--probe-events <dir> [sinceID]`
    static func events(dir: String, since: UInt64?) {
        let start = FSEventsGetCurrentEventId()
        guard let since else {
            print("no sinceID: nothing to replay")
            print("currentEventID \(start)")
            return
        }
        let box = Box()
        let t0 = Date()
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count {
                if flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    box.historyDone = true
                    continue
                }
                print("event \(ids[i]) flags=0x\(String(flags[i], radix: 16)) \(arr[i] as! String)")
            }
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, cb, &ctx, [dir] as CFArray, since, 0.1, flags) else {
            print("FAIL: could not create stream"); exit(1)
        }
        let q = DispatchQueue(label: "probe.events")
        FSEventStreamSetDispatchQueue(stream, q)
        FSEventStreamStart(stream)
        let deadline = Date().addingTimeInterval(30)
        while !box.historyDone && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        print("historyDone=\(box.historyDone) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        print("currentEventID \(start)")
    }

    /// `--probe-uploaded <dir> [maxSeconds]`: polls ubiquitousItemIsUploaded for every file under dir.
    /// Exit 0 when all uploaded, 1 on timeout.
    static func uploaded(dir: String, maxSeconds: Double) -> Int32 {
        let deadline = Date().addingTimeInterval(maxSeconds)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey]
        while true {
            var total = 0, pending = 0
            let en = FileManager.default.enumerator(at: URL(fileURLWithPath: dir),
                                                    includingPropertiesForKeys: Array(keys))
            while let u = en?.nextObject() as? URL {
                guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                total += 1
                if v.ubiquitousItemIsUploaded != true { pending += 1 }
            }
            print("files=\(total) notUploaded=\(pending)")
            if total > 0 && pending == 0 { return 0 }
            if Date() > deadline { return 1 }
            Thread.sleep(forTimeInterval: 5)
        }
    }

    /// `--probe-blocks <file>`: physical device offsets at several file offsets (F_LOG2PHYS_EXT).
    /// Identical offsets in two files mean shared blocks.
    static func blocks(path: String) -> Int32 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { print("\(path): open failed errno=\(errno)"); return 1 }
        defer { close(fd) }
        var st = stat(); fstat(fd, &st)
        let size = Int64(st.st_size)
        let step: Int64 = 16 * 1024 * 1024
        var out: [String] = []
        var failed = false
        var off: Int64 = 0
        while off < size {
            var l = log2phys(l2p_flags: 0, l2p_contigbytes: 0, l2p_devoffset: off)
            if fcntl(fd, F_LOG2PHYS_EXT, &l) == -1 { out.append("\(off):err\(errno)"); failed = true }
            else { out.append("\(off):\(l.l2p_devoffset)") }
            off += step
        }
        print(out.joined(separator: " "))
        return failed || out.isEmpty ? 1 : 0
    }

    /// `--probe-ubiq <path>...`: ubiquity keys read on the item itself (no symlink following).
    static func ubiq(paths: [String]) {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                      .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey,
                                      .ubiquitousItemDownloadingStatusKey]
        for p in paths {
            let u = URL(fileURLWithPath: p)
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { print("\(p): resourceValues failed"); continue }
            print("\(p): symlink=\(v.isSymbolicLink.map(String.init) ?? "nil") isUbiquitous=\(v.isUbiquitousItem.map(String.init) ?? "nil") uploaded=\(v.ubiquitousItemIsUploaded.map(String.init) ?? "nil") uploading=\(v.ubiquitousItemIsUploading.map(String.init) ?? "nil") err=\(v.ubiquitousItemUploadingError.map { "\($0)" } ?? "nil") dl=\(v.ubiquitousItemDownloadingStatus?.rawValue ?? "nil")")
        }
    }
}
#endif
