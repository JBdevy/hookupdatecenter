import AVFoundation
import Foundation

/// Estimates one tempo from the PCM that lies under a ruler selection.
enum SelectionTempoAnalysis {
    private struct Segment {
        let clip: AudioClip
        let path: String
        let start: Double
        let end: Double
    }
    private struct Estimate {
        let bpm: Double
        let support: Double
        var anchor: Double?
    }

    static func detect(song: Song, range: ClosedRange<Double>, directory: URL,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Double? {
        try Task.checkCancellation()
        let job = Task.detached(priority: .utility) {
            try analyze(song: song, range: range, directory: directory, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
    }

    private static func analyze(song: Song, range: ClosedRange<Double>, directory: URL,
                                progress: (Double) -> Void) throws -> Double? {
        progress(0)
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.upperBound > range.lowerBound else { return nil }
        var programs = AudioTempoPrograms(song: song)
        var clicks: [[Segment]] = [], music: [[Segment]] = []
        for track in song.tracks {
            try Task.checkCancellation()
            let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isClick = track.role == .click || track.kind == .click || ["click", "metronome", "metrônomo"].contains(name)
            guard isClick || track.kind == .standard || track.kind == .video else { continue }
            var segments: [Segment] = []
            for item in track.clips where item.startTime < range.upperBound && item.startTime + item.duration > range.lowerBound {
                guard !item.isImage, item.midi == nil || item.frozenMIDI == true,
                      let path = (item.audioFile ?? track.audioFile)?.path, !path.isEmpty else { continue }
                for clip in programs.fragments(for: item) {
                    let start = max(range.lowerBound, clip.startTime), end = min(range.upperBound, clip.startTime + clip.duration)
                    if end > start, clip.audioRate > 0 {
                        segments.append(Segment(clip: clip, path: path, start: start, end: end))
                    }
                }
            }
            if !segments.isEmpty {
                if isClick { clicks.append(segments) } else { music.append(segments) }
            }
        }

        let total = max(1, clicks.count + music.count)
        var done = 0, firstError: Error?, readSamples = false
        for (group, binSeconds) in [(clicks, 0.001), (music, 0.005)] {
            var estimates: [Estimate] = []
            for track in group {
                let windows = analysisWindows(track)
                for (index, window) in windows.enumerated() {
                    try Task.checkCancellation()
                    let bins = Int(ceil((window.upperBound - window.lowerBound) / binSeconds))
                    var envelope = [Double](repeating: 0, count: max(1, bins))
                    for segment in track where segment.start < window.upperBound && segment.end > window.lowerBound {
                        do {
                            let url = segment.path.hasPrefix("/") ? URL(fileURLWithPath: segment.path) : directory.appendingPathComponent(segment.path)
                            // Avoid the playback decoder’s whole-movie extraction fallback.
                            let file = try AVAudioFile(forReading: url)
                            if try accumulate(file: file, segment: segment, window: window, binSeconds: binSeconds, energy: &envelope) { readSamples = true }
                        } catch is CancellationError { throw CancellationError() }
                        catch { if firstError == nil { firstError = error } }
                    }
                    if var value = estimate(envelope, binSeconds: binSeconds) {
                        value.anchor = value.anchor.map { $0 + window.lowerBound }
                        estimates.append(value)
                    }
                    progress((Double(done) + Double(index + 1) / Double(windows.count)) / Double(total))
                }
                done += 1
            }
            if let bpm = dominant(estimates) { progress(1); return bpm }
        }
        try Task.checkCancellation()
        if !readSamples, let firstError { throw firstError }
        progress(1)
        return nil
    }

    // Sample up to 36 seconds per track. Choose windows by time actually
    // occupied by items, so even an hour of empty grid cannot hide a short stem.
    private static func analysisWindows(_ segments: [Segment]) -> [Range<Double>] {
        var runs: [Range<Double>] = []
        for value in segments.sorted(by: { $0.start < $1.start }) {
            // Short gaps are part of the rhythm when beats are separate
            // one-shot items on the track.
            if let last = runs.last, value.start <= last.upperBound + 1.5 {
                runs[runs.count - 1] = last.lowerBound..<max(last.upperBound, value.end)
            } else { runs.append(value.start..<value.end) }
        }
        let length = runs.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        if length <= 36 { return runs }
        var windows: [Range<Double>] = []
        for fraction in [1.0 / 6, 0.5, 5.0 / 6] {
            var remaining = length * fraction
            for run in runs {
                let width = run.upperBound - run.lowerBound
                if remaining <= width {
                    let first = max(run.lowerBound, min(run.upperBound - 12, run.lowerBound + remaining - 6))
                    let sample = first..<min(run.upperBound, first + 12)
                    if !windows.contains(sample) { windows.append(sample) }
                    break
                }
                remaining -= width
            }
        }
        return windows
    }

    /// Map each measured source window onto graph time, including wraps.
    /// The playback engine's tempo fragments have already applied rate changes.
    private static func accumulate(file: AVAudioFile, segment: Segment, window: Range<Double>, binSeconds: Double, energy: inout [Double]) throws -> Bool {
        let format = file.processingFormat, hz = format.sampleRate, rate = segment.clip.audioRate
        let first = max(segment.start, window.lowerBound), end = min(segment.end, window.upperBound)
        guard hz > 0, rate.isFinite, end > first, file.length > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return false }
        let fileEnd = Double(file.length) / hz
        let loopStart = max(0, segment.clip.loopStart ?? 0)
        let loopEnd = min(fileEnd, loopStart + (segment.clip.loopLength ?? 0))
        let loop = loopEnd > loopStart
        let framesPerBin = rate * hz * binSeconds
        var timeline = first, readAny = false
        while timeline < end {
            try Task.checkCancellation()
            let raw = segment.clip.sourceOffset + (timeline - segment.clip.startTime) * rate
            let source = loop && raw >= loopEnd
                ? loopStart + (raw - loopStart).truncatingRemainder(dividingBy: loopEnd - loopStart) : raw
            guard source >= 0, source < fileEnd else { break }
            let frame = AVAudioFramePosition((source * hz).rounded(.down))
            let limit = loop ? min(file.length, AVAudioFramePosition((loopEnd * hz).rounded(.up))) : file.length
            let wanted = Int(min(8192, ceil((end - timeline) * rate * hz), Double(limit - frame)))
            guard wanted > 0 else { break }
            if file.framePosition != frame { file.framePosition = frame }
            try file.read(into: pcm, frameCount: AVAudioFrameCount(wanted))
            let count = Int(pcm.frameLength)
            guard count > 0, let channels = pcm.floatChannelData else { break }
            var offset = 0
            while offset < count {
                let relative = (timeline - window.lowerBound) / binSeconds + Double(offset) / framesPerBin
                let bin = min(energy.count - 1, max(0, Int(relative)))
                let through = min(count, offset + max(1, Int(ceil((Double(bin + 1) - relative) * framesPerBin))))
                var sum = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let samples = channels[channel]
                    for i in offset..<through {
                        let value = Double(samples[i * pcm.stride])
                        sum += value * value
                    }
                }
                energy[bin] += sum / (Double(format.channelCount) * framesPerBin)
                offset = through
            }
            readAny = true
            timeline += Double(count) / (hz * rate)
        }
        return readAny
    }

    private static func estimate(_ energy: [Double], binSeconds: Double) -> Estimate? {
        var baseline = 0.0, shortEnergy = 0.0
        let smoothing = binSeconds >= 0.005 ? 5 : 1
        let attacks = energy.indices.map { i -> Double in
            shortEnergy += energy[i]
            if i >= smoothing { shortEnergy -= energy[i - smoothing] }
            let amplitude = sqrt(max(0, shortEnergy) / Double(smoothing))
            let rise = max(0, amplitude - baseline * 1.12)
            baseline += (amplitude > baseline ? 0.65 : 0.08) * (amplitude - baseline)
            return rise
        }
        guard let maxAttack = attacks.max(), maxAttack > 1e-5 else { return nil }
        var pulses: [ClickTempoDetector.Transient] = []
        for (index, strength) in attacks.enumerated() where strength >= maxAttack * 0.045 {
            if index > 0 && strength < attacks[index - 1] { continue }
            if index + 1 < attacks.count && strength <= attacks[index + 1] { continue }
            let onset = ClickTempoDetector.Transient(position: Double(index) * binSeconds, peak: strength)
            if let last = pulses.last, onset.position - last.position < 0.08 {
                if strength > last.peak { pulses[pulses.count - 1] = onset }
            } else { pulses.append(onset) }
        }
        if binSeconds <= 0.001 {
            // A click's loudest transient can move within its ring, especially
            // between downbeats and regular beats. Fit the attack edge at a
            // fraction of this pulse's local amplitude, with sub-bin timing.
            for i in pulses.indices {
                let center = min(energy.count - 1, Int((pulses[i].position / binSeconds).rounded()))
                let start = max(0, center - 24), end = min(energy.count - 1, center + 24)
                let peak = energy[start...end].max() ?? 0
                let threshold = peak * 0.09 // 30% amplitude in squared energy
                if peak > 0, let edge = (start...end).first(where: { energy[$0] >= threshold }) {
                    var time = Double(edge)
                    if edge > start, energy[edge] > energy[edge - 1] {
                        time -= (energy[edge] - threshold) / (energy[edge] - energy[edge - 1])
                    }
                    pulses[i].position = time * binSeconds
                }
            }
        }
        pulses = ClickTempoDetector.primaryTransients(pulses)
        guard pulses.count >= 4 else { return nil }
        let times = pulses.map(\.position)
        let sections = ClickTempoDetector.sections(onsets: times)
        var estimates: [Estimate] = []
        for (i, section) in sections.enumerated() {
            let last = i + 1 < sections.count ? sections[i + 1].position : times.last!
            let subset = times.filter { $0 >= section.position - 1e-6 && $0 <= last + 1e-6 }
            if let refined = fittedBPM(times: subset, initialBPM: section.bpm, binSeconds: binSeconds) {
                estimates.append(refined)
            }
        }
        let span = times.last! - times.first!
        if let best = strongest(estimates), best.support >= span * 0.45 { return best }

        // Music need not attack on every beat. Look for a recurring accent
        // envelope; normalize the score to reject unrelated or sparse attacks.
        let stride = max(1, Int((0.005 / binSeconds).rounded()))
        let accent = stride == 1 ? attacks : Swift.stride(from: 0, to: attacks.count, by: stride).map {
            attacks[$0..<min($0 + stride, attacks.count)].max() ?? 0
        }
        let hop = Double(stride) * binSeconds
        let lagMin = Int((60 / (300 * hop)).rounded()), lagMax = min(Int(1 / hop), accent.count / 3)
        guard lagMax >= lagMin else { return nil }
        var bestLag = 0, bestScore = 0.0
        for lag in lagMin...lagMax {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for i in lag..<accent.count {
                let x = accent[i], y = accent[i - lag]
                xy += x * y; xx += x * x; yy += y * y
            }
            guard xx > 0 && yy > 0 else { continue }
            let score = xy / sqrt(xx * yy)
            if score > bestScore + 0.015 { bestScore = score; bestLag = lag }
        }
        guard bestScore >= 0.52, bestLag > 0 else { return nil }
        let period = Double(bestLag) * hop
        // For syncopated material take the onsets that occupy the strongest
        // repeating beat phase, then refine using the original-resolution times.
        let reference = pulses.max(by: { $0.peak < $1.peak })!.position
        let aligned = times.filter {
            let distance = ($0 - reference) / period
            return abs(distance - distance.rounded()) * period < max(0.014, period * 0.05)
        }
        return fittedBPM(times: aligned, initialBPM: 60 / period, binSeconds: binSeconds)
    }

    /// Fit onset time against integer beat number. Missing pulses retain their
    /// beat distance; ambiguous gaps split the run instead of shifting its phase.
    private static func fittedBPM(times: [Double], initialBPM: Double, binSeconds: Double) -> Estimate? {
        guard times.count >= 4, initialBPM.isFinite, initialBPM > 0 else { return nil }
        let expected = 60 / initialBPM
        var runs: [Estimate] = [], beats = [0.0], observed = [times[0]], direct = 0
        func median(_ values: [Double]) -> Double {
            let v = values.sorted(), middle = v.count / 2
            return v.count.isMultiple(of: 2) ? (v[middle - 1] + v[middle]) / 2 : v[middle]
        }
        func fit() {
            guard observed.count >= 4, direct >= 3, direct * 2 >= observed.count - 1 else { return }
            // Median of independent long-baseline slopes is insensitive to a
            // clipped first attack or a delayed last attack.
            var slopes: [Double] = []
            for lag in Set([max(1, beats.count / 3), beats.count / 2, 2 * beats.count / 3]) {
                for i in lag..<beats.count {
                    slopes.append((observed[i] - observed[i - lag]) / (beats[i] - beats[i - lag]))
                }
            }
            let slope = median(slopes)
            let intercept = median(beats.indices.map { observed[$0] - slope * beats[$0] })
            let tolerance = max(2.5 * binSeconds, min(0.016, expected * 0.022))
            let inliers = beats.indices.filter { abs(observed[$0] - intercept - slope * beats[$0]) <= tolerance }
            guard inliers.count >= 4, inliers.count * 4 >= beats.count * 3 else { return }
            let n = Double(inliers.count)
            let x = inliers.reduce(0) { $0 + beats[$1] } / n, y = inliers.reduce(0) { $0 + observed[$1] } / n
            let covariance = inliers.reduce(0) { $0 + (beats[$1] - x) * (observed[$1] - y) }
            let variance = inliers.reduce(0) { $0 + (beats[$1] - x) * (beats[$1] - x) }
            let period = covariance / variance, bpm = 60 / period
            if (59.95...300.05).contains(bpm) {
                let centerBeatTime = y + (x.rounded() - x) * period
                runs.append(Estimate(bpm: bpm, support: Double(inliers.count - 1) * period, anchor: centerBeatTime))
            }
        }
        for (previous, time) in zip(times, times.dropFirst()) {
            let gap = time - previous, step = (gap / expected).rounded()
            if (1...4).contains(step), abs(gap - step * expected) <= max(0.014, expected * 0.06) {
                beats.append(beats.last! + step); observed.append(time)
                if step == 1 { direct += 1 }
            } else {
                fit(); beats = [0]; observed = [time]; direct = 0
            }
        }
        fit()
        return strongest(runs)
    }

    private static func strongest(_ estimates: [Estimate]) -> Estimate? {
        let sorted = estimates.sorted { $0.bpm < $1.bpm }
        var best: Estimate?
        for anchor in sorted {
            let group = sorted.filter { abs($0.bpm - anchor.bpm) <= max(0.8, anchor.bpm * 0.015) }
            let support = group.reduce(0) { $0 + $1.support }
            if support > best?.support ?? 0 {
                let average = group.reduce(0) { $0 + $1.bpm * $1.support } / support
                let anchors = group.compactMap(\.anchor).sorted()
                let bpm = coherentBPM(anchors, near: average) ?? average
                best = Estimate(bpm: bpm, support: support, anchor: group.max(by: { $0.support < $1.support })?.anchor)
            }
        }
        return best
    }

    // Stable excerpts of the same click often share phase across the skipped
    // audio. Use that longer baseline only when the beat count is unambiguous.
    private static func coherentBPM(_ anchors: [Double], near bpm: Double) -> Double? {
        guard let first = anchors.first, let last = anchors.last, last - first >= 8 else { return nil }
        let period = 60 / bpm
        let times = anchors.map { $0 - first }
        var beats = [0.0]
        for (left, right) in zip(times, times.dropFirst()) {
            let gap = right - left, steps = (gap / period).rounded()
            guard gap <= 120, abs(gap - steps * period) < min(0.025, period * 0.05) else { return nil }
            beats.append(beats.last! + steps)
        }
        let n = Double(beats.count), x = beats.reduce(0, +) / n, y = times.reduce(0, +) / n
        let covariance = beats.indices.reduce(0.0) { $0 + (beats[$1] - x) * (times[$1] - y) }
        let variance = beats.reduce(0.0) { $0 + ($1 - x) * ($1 - x) }
        return covariance > 0 ? 60 * variance / covariance : nil
    }

    private static func dominant(_ estimates: [Estimate]) -> Double? {
        guard let best = strongest(estimates), best.support >= estimates.reduce(0, { $0 + $1.support }) * 0.45 else { return nil }
        let contrary = estimates.filter { abs($0.bpm - best.bpm) > max(0.8, best.bpm * 0.015) }
        if let alternative = strongest(contrary), alternative.support >= best.support * 0.95 { return nil }
        return best.bpm
    }
}

