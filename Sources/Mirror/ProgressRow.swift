import SwiftUI
import MirrorCore

/// Words for a progress value. Pure, so the row and its VoiceOver text agree.
struct ProgressPresentation {
    let progress: TransferProgress

    var phaseText: String {
        switch progress.phase {
        case .scanning: "Looking for changes"
        case .transferring: "Backing up"
        case .verifying: "Checking"
        case .waitingForICloud: "Waiting for iCloud"
        }
    }

    var percentText: String? { progress.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } }

    var filesText: String? {
        guard progress.filesDone > 0 || progress.filesTotal != nil else { return nil }
        let done = progress.filesDone.formatted()
        return progress.filesTotal.map { "\(done) of \($0.formatted()) files" } ?? "\(done) files"
    }

    var speedText: String? {
        guard let s = progress.bytesPerSecond, s > 0 else { return nil }
        return Int64(s).formatted(.byteCount(style: .file)) + "/s"
    }

    var etaText: String? {
        guard let eta = progress.eta, eta >= 0 else { return nil }
        let d = Duration.seconds(max(1, eta.rounded()))
        let t = d.formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        return progress.etaIsEstimate ? "About \(t) left" : "\(t) left"
    }

    var detail: String { [filesText, speedText, etaText].compactMap { $0 }.joined(separator: " · ") }

    var spokenValue: String {
        var parts = [percentText.map { "\($0) done" } ?? phaseText]
        if let s = speedText { parts.append(s.replacingOccurrences(of: "/s", with: " per second")) }
        if let e = etaText { parts.append(e) }
        return parts.joined(separator: ", ")
    }
}

/// One running pair. With no reliable total the bar is indeterminate and no time is shown.
struct ProgressRow: View {
    let label: String
    let progress: TransferProgress

    var body: some View {
        let p = ProgressPresentation(progress: progress)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline).lineLimit(1)
                Spacer(minLength: 8)
                Text(p.percentText ?? p.phaseText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            if let f = progress.fraction {
                ProgressView(value: f, total: 1).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if !p.detail.isEmpty {
                Text(p.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(p.spokenValue)
    }
}

/// Upload speed for the whole Mac. Labelled as such, and separate from per-pair speed.
struct NetworkUploadRow: View {
    let network: NetworkStatus

    var body: some View {
        let speed = network.uploadBytesPerSecond.map { Int64($0).formatted(.byteCount(style: .file)) + "/s" } ?? "Measuring"
        HStack {
            Label("Network upload (whole Mac)", systemImage: "arrow.up.circle").font(.caption)
            Spacer(minLength: 8)
            Text(speed).font(.caption).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network upload, whole Mac")
        .accessibilityValue(network.uploadBytesPerSecond == nil ? "Measuring" : speed.replacingOccurrences(of: "/s", with: " per second"))
    }
}
