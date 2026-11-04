import Foundation
import Network
import Observation
import MirrorCore

/// Whole-Mac network state. Counters are sampled once a second, only between `start()` and `stop()`;
/// call them from the panel or window appearing and disappearing so a closed panel costs nothing.
@MainActor @Observable
final class NetworkStatus {
    /// Upload speed across every active interface on this Mac, not just Mirror. Nil until two samples exist.
    private(set) var uploadBytesPerSecond: Double?
    private(set) var interfaceName: String?
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var sampler: Task<Void, Never>?

    var isRunning: Bool { sampler != nil }

    func start() {
        guard sampler == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let name = path.availableInterfaces.first { path.usesInterfaceType($0.type) }?.name
            Task { @MainActor in self?.apply(name: name, expensive: path.isExpensive, constrained: path.isConstrained) }
        }
        m.start(queue: DispatchQueue(label: "mirror.network-path", qos: .utility))
        monitor = m
        sampler = Task { [weak self] in
            var estimator = RateEstimator(smoothing: 0.5)
            while !Task.isCancelled {
                let out = InterfaceCounters.sample().bytesOut
                let rate = estimator.add(bytes: out, at: Date())
                guard let self, !Task.isCancelled else { return }
                self.uploadBytesPerSecond = rate
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        sampler?.cancel(); sampler = nil
        monitor?.cancel(); monitor = nil
        uploadBytesPerSecond = nil
    }

    private func apply(name: String?, expensive: Bool, constrained: Bool) {
        guard monitor != nil else { return }   // a late callback after stop()
        interfaceName = name; isExpensive = expensive; isConstrained = constrained
    }
}
