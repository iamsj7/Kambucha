import Foundation
import Observation

/// Pasting a Recovery Kit to restore a destination's keys or sign-in. The agent says `kitUnproven` when the backup holds
/// nothing yet to prove the kit against; the owner is then asked, and only a yes sends it again with `acceptUnproven`
/// (the agent asks for Touch ID before using it).
@MainActor @Observable
public final class KitRestoreModel {
    public enum Phase: Equatable, Sendable { case editing, working, askingUnproven, failed(String), done }
    public private(set) var phase: Phase = .editing
    public var text = ""
    public let destination: Destination

    @ObservationIgnored private let restore: (Destination, String, Bool) async throws -> Void

    public init(destination: Destination, restore: @escaping (Destination, String, Bool) async throws -> Void) {
        self.destination = destination; self.restore = restore
    }

    public var canSubmit: Bool {
        phase != .working && phase != .askingUnproven && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func submit() async {
        guard canSubmit else { return }
        await run(acceptUnproven: false)
    }

    public func acceptUnproven() async {
        guard phase == .askingUnproven else { return }
        await run(acceptUnproven: true)
    }

    public func declineUnproven() { if phase == .askingUnproven { phase = .editing } }

    /// The kit text is held only while the sheet is open.
    public func cancel() { text = "" }

    private func run(acceptUnproven: Bool) async {
        phase = .working
        do {
            try await restore(destination, text, acceptUnproven)
            text = ""
            phase = .done
        } catch RemoteSetupError.kitUnproven where !acceptUnproven {
            phase = .askingUnproven
        } catch {
            phase = .failed(SetupFailureText.message(for: error))
        }
    }
}

/// Showing the Recovery Kit. The agent asks for Touch ID (or the password) before it reads the kit, so the sheet says so
/// first and can ask again after a refusal. The text is held in memory only while the sheet is open.
@MainActor @Observable
public final class KitRevealModel {
    public enum Phase: Equatable, Sendable { case idle, asking, shown, failed(String) }
    public private(set) var phase: Phase = .idle
    public private(set) var kitText: String?
    public let destination: Destination

    @ObservationIgnored private let fetch: (Destination) async throws -> String

    public init(destination: Destination, fetch: @escaping (Destination) async throws -> String) {
        self.destination = destination; self.fetch = fetch
    }

    public func begin() async {
        guard phase != .asking, phase != .shown else { return }
        phase = .asking
        do { kitText = try await fetch(destination); phase = .shown }
        catch is CancellationError { phase = .idle }
        catch { kitText = nil; phase = .failed(SetupFailureText.message(for: error)) }
    }

    public func clear() { kitText = nil; phase = .idle }
}
