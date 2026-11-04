import SwiftUI
import AppKit
import MirrorCore

enum DrillOutcome: Equatable { case passed, badKit, couldntTell }

struct DrillCandidate: Equatable { var relativePath: String; var original: URL }

extension DrillOutcome {
    /// `nil` means the owner cancelled. A Kit that can't be read, or that doesn't open the backup, is
    /// a bad Kit. Anything else (network, sign-in, the agent) means the drill couldn't tell, so it
    /// isn't reported as a failed Kit.
    static func classify(_ result: Result<Bool, any Error>) -> DrillOutcome? {
        switch result {
        case .success(let passed): return passed ? .passed : .badKit
        case .failure(let error):
            switch error {
            case is CancellationError: return nil
            case is RecoveryKitError: return .badKit
            case RemoteSetupError.kitDoesNotMatchDestination, RemoteSetupError.kitDoesNotOpenBackup: return .badKit
            default: return .couldntTell
            }
        }
    }
}

@MainActor @Observable
final class DrillModel {
    typealias Runner = @Sendable (Destination, String, String, URL) async throws -> Bool
    typealias Candidates = (Destination) async -> DrillCandidate?
    enum Phase: Equatable { case idle, running, finished(DrillOutcome), nothingToTest }

    let destinations: [Destination]
    var selected: UUID?
    /// Held in memory only while the sheet is open, and cleared once a drill finishes.
    var kitText = ""
    private(set) var phase: Phase = .idle
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let sets: [BackupSet]
    @ObservationIgnored private let candidate: Candidates
    @ObservationIgnored private let run: Runner

    init(destinations: [Destination], sets: [BackupSet] = [], store: ConfigStore = ConfigStore(root: MirrorPaths.support),
         candidate: @escaping Candidates, run: @escaping Runner) {
        self.destinations = destinations; self.store = store; self.candidate = candidate; self.run = run
        self.sets = sets.isEmpty ? ((try? store.loadSets()) ?? []) : sets
        selected = destinations.first?.id
    }

    var destination: Destination? { destinations.first { $0.id == selected } }
    var canStart: Bool { phase != .running && destination != nil && !kitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func start() async {
        guard let dest = destination else { return }
        phase = .running
        // A Kit that doesn't parse is refused here, before the agent is spawned.
        guard (try? RecoveryKit(parsing: kitText)) != nil else { kitText = ""; phase = .finished(.badKit); return }
        guard let file = await candidate(dest) else { phase = .nothingToTest; return }
        let text = kitText
        let result: Result<Bool, any Error>
        do { result = .success(try await run(dest, text, file.relativePath, file.original)) }
        catch { result = .failure(error) }
        kitText = ""
        guard let outcome = DrillOutcome.classify(result) else { phase = .idle; return }
        if outcome == .passed { recordPass(for: dest) }
        phase = .finished(outcome)
    }

    func reset() { phase = .idle }

    /// Called when the sheet closes, however it closes: the pasted Kit must not outlive it.
    func discard() { kitText = ""; phase = .idle }

    #if DEBUG
    func setPhaseForSnapshot(_ p: Phase) { phase = p }
    #endif

    private func recordPass(for dest: Destination) {
        for set in sets where set.destinationIDs.contains(dest.id) {
            let pair = PairID(set: set.id, destination: dest.id)
            var state = (try? store.state(for: pair)) ?? SetState()
            state.lastDrill = now()
            try? store.save(state, for: pair)
        }
    }
}

enum DrillFilePicker {
    /// Lists the set's backed-up files, relative to its source, or nil if it can't.
    typealias Lister = @Sendable (BackupSet) async -> [String]?

    /// A small, plain file of the first set that uses the destination, one that has been backed up and
    /// hasn't changed since. The candidates come from rclone itself, run with the set's real filter, so
    /// every rule (paths, classes, includes) is applied exactly as a backup applies it. Secrets, `.git`
    /// and hidden files are then removed separately, so no user include can bring one back. Any failure
    /// means nothing suitable (nil), which the sheet shows as "Nothing to test", never as a bad Kit.
    static func candidate(sets: [BackupSet], store: ConfigStore = ConfigStore(root: MirrorPaths.support),
                          list: @escaping Lister = rcloneLister(binary: bundledRclone)) -> (Destination) async -> DrillCandidate? {
        { dest in
            for set in sets where set.destinationIDs.contains(dest.id) {
                let finished = (try? store.state(for: PairID(set: set.id, destination: dest.id)))?.lastFinished
                if let c = await pick(in: set, finishedBefore: finished, list: list) { return c }
            }
            return nil
        }
    }

    static var bundledRclone: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rclone") }

    /// `rclone lsf -R --files-only --max-depth 3 --filter-from <set filter> --config /dev/null <source>`.
    /// Needs no secrets and runs under a hard time limit.
    static func rcloneLister(binary: URL, timeout: TimeInterval = 20) -> Lister {
        { set in
            guard let presets = try? PresetCatalog.all() else { return nil }
            let lines = FilterBuilder(presets: presets).lines(for: set, projects: [], scope: nil)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-drill-\(UUID().uuidString)", isDirectory: true)
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return nil }
            defer { try? FileManager.default.removeItem(at: dir) }
            let filter = dir.appendingPathComponent("drill.filter")
            guard (try? FilterBuilder(presets: presets).write(lines, to: filter)) != nil else { return nil }
            guard let r = await BoundedProcess.output(binary, ["lsf", "-R", "--files-only", "--max-depth", "3",
                                                               "--filter-from", filter.path, "--config", "/dev/null", set.source.path],
                                                      timeout: timeout), r.code == 0 else { return nil }
            return String(decoding: r.output, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }

    private static let plainExtensions: Set<String> = ["txt", "md", "rtf", "csv", "json", "yaml", "yml", "xml", "html", "swift", "py", "js", "ts"]

    /// Hidden anywhere in the path (covers `.git`, `.env`, `.DS_Store`) or any component that is a secret pattern.
    static func isForbidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { part in
            part.hasPrefix(".") || PresetCatalog.secretPatterns.contains { fnmatch($0, String(part), FNM_CASEFOLD) == 0 }
        }
    }

    static func pick(in set: BackupSet, finishedBefore finished: Date?, list: Lister) async -> DrillCandidate? {
        guard let finished, let listed = await list(set) else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let usable = listed.filter { !isForbidden($0) }.compactMap { rel -> (String, URL)? in
            let url = set.source.appendingPathComponent(rel)
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
                  let size = v.fileSize, size > 0, size <= 256 * 1024,
                  let modified = v.contentModificationDate, modified < finished.addingTimeInterval(-60),
                  !Dataless.isDataless(url) else { return nil }
            return (rel, url)
        }
        func rank(_ c: (String, URL)) -> (Int, Int, String) {
            (plainExtensions.contains(c.1.pathExtension.lowercased()) ? 0 : 1, c.0.split(separator: "/").count, c.0)
        }
        guard let best = usable.min(by: { rank($0) < rank($1) }) else { return nil }
        return DrillCandidate(relativePath: "\(MirrorPaths.mirrorPath(set))/\(best.0)", original: best.1)
    }
}

struct DrillSheet: View {
    @Bindable var model: DrillModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test Your Recovery Kit").font(.title2).bold()
            Text("Paste the whole Recovery Kit. Mirror uses only what you paste to download and open one small file, and compares it with the original. The Kit isn't saved.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.destinations.count > 1 {
                Picker("Destination", selection: $model.selected) {
                    ForEach(model.destinations) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            TextEditor(text: $model.kitText)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .disabled(model.phase == .running)
                .accessibilityLabel("Recovery Kit")
                .accessibilityHint("Paste the full text of your Recovery Kit")

            result

            HStack {
                Spacer()
                Button(closeTitle) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run Test") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private var closeTitle: String {
        if case .finished(.passed) = model.phase { "Done" } else { "Cancel" }
    }

    @ViewBuilder private var result: some View {
        switch model.phase {
        case .idle: EmptyView()
        case .running:
            HStack { ProgressView().controlSize(.small); Text("Checking your backup…") }
        case .nothingToTest:
            message("questionmark.circle", "Nothing to test yet",
                    "Mirror needs a small file in this set that has already been backed up. Try again after the next backup.")
        case .finished(.passed):
            message("checkmark.circle", "Your Recovery Kit works",
                    "Mirror downloaded a file, opened it with your Kit, and it matched the original.")
        case .finished(.badKit):
            message("xmark.octagon", "This Kit didn't open the backup",
                    "Make sure you pasted the whole Kit for this destination. If it still fails, save a new Recovery Kit now.")
        case .finished(.couldntTell):
            message("questionmark.circle", "Couldn't tell. Try again.",
                    "Mirror couldn't reach the destination, so this is neither a pass nor a fail.")
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
