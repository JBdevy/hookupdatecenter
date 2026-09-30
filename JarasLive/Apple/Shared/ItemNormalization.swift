import SwiftUI
import AVFoundation
import Accelerate

enum NormalizationMode: String, CaseIterable { case lufs = "LUFS-I", rms = "RMS-I", peak = "Peak", truePeak = "True Peak" }

enum NormalizationTargetPreferences {
    static func target(for mode: NormalizationMode, defaults: UserDefaults = .standard) -> Double {
        guard let saved = defaults.object(forKey: key(mode)) as? NSNumber, saved.doubleValue.isFinite else { return -1 }
        return min(12,max(-60,saved.doubleValue))
    }
    static func remember(_ target: Double, for mode: NormalizationMode, defaults: UserDefaults = .standard) {
        guard target.isFinite, (-60...12).contains(target) else { return }
        defaults.set(target,forKey: key(mode))
    }
    static func formatted(_ target: Double) -> String { String(format: "%.2f",target) }
    private static func key(_ mode: NormalizationMode) -> String { "jaras.normalization.target." + mode.rawValue }
}

enum ItemNormalization {
    /// Read bounded chunks on a worker. Analyse the item's source interval,
    /// independent of transport and mixer effects. Never rewrite the source.
    static func measure(_ clip: AudioClip, directory: URL, mode: NormalizationMode) throws -> Double {
        guard let source = clip.audioFile else { throw ProjectError.invalid("Item has no audio file.") }
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(source.path))
        let rate = file.processingFormat.sampleRate, channels = Int(file.processingFormat.channelCount)
        let loopFirst = max(0, AVAudioFramePosition((clip.loopStart ?? 0) * rate))
        let loopEnd = min(file.length, loopFirst + AVAudioFramePosition((clip.loopLength ?? Double(file.length) / rate) * rate))
        let looping = clip.loopLength != nil
        let rawFirst = AVAudioFramePosition(clip.sourceOffset * rate)
        let first = looping && loopEnd > loopFirst ? loopFirst + ((rawFirst - loopFirst) % (loopEnd - loopFirst) + (loopEnd - loopFirst)) % (loopEnd - loopFirst) : min(file.length, rawFirst)
        let totalFrames = AVAudioFramePosition((clip.duration * clip.audioRate * rate).rounded())
        let wanted = looping ? totalFrames : min(file.length - first, totalFrames)
        guard wanted > 0, loopEnd > loopFirst, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384),
              let meter = ebur128_init(UInt32(channels), UInt(rate.rounded()), Int32(EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue)) else {
            throw ProjectError.invalid("Could not analyze this audio item.")
        }
        defer { var owned: UnsafeMutablePointer<ebur128_state>? = meter; ebur128_destroy(&owned) }
        file.framePosition = first
        var interleaved = [Float](repeating: 0, count: 16384 * channels)
        var squareSum = 0.0, frames = 0
        while frames < wanted {
            try Task.checkCancellation()
            if looping && file.framePosition >= loopEnd { file.framePosition = loopFirst }
            let available = (looping ? loopEnd : file.length) - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16384, available, wanted - Int64(frames))))
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<channels {
                var sum: Float = 0
                vDSP_svesq(data[channel], 1, &sum, vDSP_Length(count)); squareSum += Double(sum)
                for frame in 0..<count { interleaved[frame * channels + channel] = data[channel][frame] }
            }
            guard interleaved.withUnsafeBufferPointer({ ebur128_add_frames_float(meter, $0.baseAddress!, count) }) == EBUR128_SUCCESS.rawValue else {
                throw ProjectError.invalid("Could not measure audio level.")
            }
            frames += count
        }
        switch mode {
        case .rms: return 10 * log10(max(1e-20, squareSum / Double(max(1, frames * channels))))
        case .lufs:
            // A short item still needs one complete 400 ms integration block.
            if Double(frames) / rate < 0.4 {
                let silence = [Float](repeating: 0, count: (Int(ceil(rate * 0.4)) - frames) * channels)
                _ = silence.withUnsafeBufferPointer { ebur128_add_frames_float(meter, $0.baseAddress!, silence.count / channels) }
            }
            var loudness = 0.0
            guard ebur128_loudness_global(meter, &loudness) == EBUR128_SUCCESS.rawValue else { throw ProjectError.invalid("Could not measure integrated loudness.") }
            return loudness
        case .peak, .truePeak:
            var peak = 0.0
            if mode == .truePeak {
                // Flush the interpolation filter's final samples.
                let tail = [Float](repeating: 0, count: channels * 64)
                _ = tail.withUnsafeBufferPointer { ebur128_add_frames_float(meter, $0.baseAddress!, 64) }
            }
            for channel in 0..<channels {
                var value = 0.0
                if mode == .peak { _ = ebur128_sample_peak(meter, UInt32(channel), &value) }
                else { _ = ebur128_true_peak(meter, UInt32(channel), &value) }
                peak = max(peak, value)
            }
            return 20 * log10(max(1e-20, peak))
        }
    }
    static func gain(measured: Double, target: Double) -> Double {
        guard measured.isFinite, measured > -150 else { return 1 }
        return pow(10, min(24, max(-120, target - measured)) / 20)
    }
}

struct ItemNormalizationEditor: View {
    let show: ShowController
    let documents: ProjectDocuments
    let items: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var mode = NormalizationMode.peak
    @State private var target = "-1.00"
    @State private var invalid = false
    @State private var shake = 0.0
    @State private var progress = ""
    @State private var error = ""
    @State private var worker: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Normalize").font(.headline)
            Picker("Mode", selection: $mode) { ForEach(NormalizationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            HStack {
                Text("Target")
                TextField("dB", text: $target).textFieldStyle(.roundedBorder).onSubmit(apply)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalid ? Color.red : .clear))
                    .modifier(NormalizeShake(value: shake))
                Text(mode == .lufs ? "LUFS" : mode == .truePeak ? "dBTP" : "dB")
            }
            Text("Independent normalization gain: up to +24 dB").font(.caption).foregroundStyle(JarasTheme.secondary)
            if !progress.isEmpty { HStack { ProgressView().controlSize(.small); Text(progress).font(.caption).lineLimit(1) } }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { worker?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Normalize", action: apply).keyboardShortcut(.defaultAction).disabled(worker != nil)
            }
        }.padding(22).frame(width: 360).background(JarasTheme.panel)
            .onAppear { restoreTarget() }
            .onChange(of: mode) { _ in restoreTarget() }
            .onDisappear { worker?.cancel() }
    }
    private func restoreTarget() {
        target = NormalizationTargetPreferences.formatted(NormalizationTargetPreferences.target(for: mode))
        invalid = false
    }
    private func apply() {
        guard worker == nil else { return }
        let parsed = Double(target.replacingOccurrences(of: ",", with: "."))
        let value = min(12, max(-60, parsed ?? -1))
        guard let parsed, parsed.isFinite, parsed == value else {
            target = NormalizationTargetPreferences.formatted(value); invalid = true
            withAnimation(.linear(duration: 0.35)) { shake += 1 }; return
        }
        target = NormalizationTargetPreferences.formatted(value)
        invalid = false; error = ""
        guard let directory = documents.currentURL?.deletingLastPathComponent() else { return }
        let project = show.snapshot.project.id
        let clips = show.snapshot.project.songs.flatMap(\.tracks).filter { $0.kind == .standard }.flatMap(\.clips).filter { items.contains($0.id) && $0.audioFile != nil }
        guard !clips.isEmpty else { error = "No audio items selected."; return }
        let selectedMode = mode
        worker = Task {
            do {
                var gains: [UUID: Double] = [:]
                for (index, clip) in clips.enumerated() {
                    try Task.checkCancellation(); progress = "\(index + 1)/\(clips.count) · \(clip.name)"
                    let analysis = Task.detached(priority: .utility) { try ItemNormalization.measure(clip, directory: directory, mode: selectedMode) }
                    let level = try await withTaskCancellationHandler { try await analysis.value } onCancel: { analysis.cancel() }
                    gains[clip.id] = ItemNormalization.gain(measured: level, target: value)
                }
                try Task.checkCancellation()
                if show.normalizeItems(gains, project: project) {
                    NormalizationTargetPreferences.remember(value,for: selectedMode)
                    dismiss()
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            progress = ""; worker = nil
        }
    }
}
private struct NormalizeShake: GeometryEffect {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(CGAffineTransform(translationX: sin(value * .pi * 6) * 6, y: 0)) }
}
