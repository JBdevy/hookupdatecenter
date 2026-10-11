import Foundation
import AVFoundation
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-click-analysis-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
for rate in [44100.0, 48000.0] {
 for rates in [[120.0,90.0],[120.0,60.0],[90.0,180.0],[120.0,122.0]] {
    let url = directory.appendingPathComponent("click-\(Int(rate))-\(Int(rates[0]))-\(Int(rates[1])).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 24))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: Int(pcm.frameLength)) }
    let first: [Double] = (0..<12).map { 0.123 + Double($0) * 60/rates[0] }
    let change = 0.123 + 12 * 60/rates[0]
    let second: [Double] = (0..<12).map { change + Double($0) * 60/rates[1] }
    let beats = first + second
    for (index, beat) in beats.enumerated() {
        let frame = Int((beat * rate).rounded())
        for offset in 0..<Int(rate * 0.02) {
            let pulse = Float(0.6 * exp(-Double(offset) / 80) * cos(Double(offset) * 0.3))
            pcm.floatChannelData![index % 2][frame + offset] = pulse
        }
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
    let actual = try TimelineAudioWaveform.clickOnsets(url)
    precondition(actual.count == beats.count, "every click must have one onset")
    for (a, b) in zip(actual, beats) { precondition(abs(a-b) <= 1/rate, "onset must retain sample position") }
    let sections = ClickTempoDetector.sections(onsets: actual)
    precondition(sections.count == 2 && abs(sections[0].bpm-rates[0]) < 0.02 && abs(sections[1].bpm-rates[1]) < 0.02)
    precondition(abs(sections[1].position - change) <= 1/rate)
    precondition(FileManager.default.fileExists(atPath: TimelineAudioWaveform.diskCacheURL(url).path))
 }
}
print("CLICK_PEAK_CACHE_SAMPLE_EXACT_ONSETS_44100_48000_STEREO_AND_TEMPO_CHANGES_OK")

for rate in [44100.0, 48000.0] {
    for period in [2,3,4,6,7] {
        for timbreOnly in [false,true] {
            let url = directory.appendingPathComponent("meter-\(Int(rate))-\(period)-\(timbreOnly).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let frames = Int(rate * (Double(period*4) * 0.4 + 1))
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            pcm.frameLength = pcm.frameCapacity
            for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: frames) }
            for index in 0..<period*4 {
                let accented = index % period == 0
                let first = Int((0.123 + Double(index)*0.4)*rate)
                let amplitude = timbreOnly || accented ? 0.8 : 0.3
                let frequency = timbreOnly && accented ? 2200.0 : 900.0
                for sample in 0..<Int(rate*0.03) {
                    let t = Double(sample)/rate
                    pcm.floatChannelData![index % 2][first+sample] = Float(amplitude*exp(-t/0.006)*cos(2*Double.pi*frequency*t))
                }
            }
            do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
            let pulses = try TimelineAudioWaveform.clickTransients(url).map { ClickTempoDetector.Transient(position: $0.position, peak: $0.peak, shape: $0.shape) }
            precondition(pulses.count == period*4)
            let meter = ClickTempoDetector.meter(transients: pulses)
            precondition(meter?.beats == period && meter?.unit == 4, "Meter \(period)/4 must follow \(timbreOnly ? "timbre" : "amplitude") accents at \(rate)")
        }
    }
}
print("CLICK_METER_PCM_AMPLITUDE_AND_TIMBRE_2_3_4_6_7_OVER_4_OK")

// Low-amplitude pre-echo must not become the tempo origin. Keep exact attacks
// across cache-bin boundaries, stereo channels and quiet unaccented clicks.
for rate in [44100.0, 48000.0] {
    let url = directory.appendingPathComponent("pre-echo-\(Int(rate)).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 9))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: Int(pcm.frameLength)) }
    let beats = (0..<16).map { Int(((0.127 + Double($0) * 0.5) * rate).rounded()) }
    for (index, frame) in beats.enumerated() {
        let amplitude = index % 4 == 0 ? 0.8 : 0.24
        for offset in -Int(rate * 0.012)..<0 {
            pcm.floatChannelData![index % 2][frame + offset] = Float(amplitude * 0.015 * cos(Double(offset) * 0.27))
        }
        for offset in 0..<Int(rate * 0.025) {
            pcm.floatChannelData![index % 2][frame + offset] = Float(amplitude * exp(-Double(offset) / (rate * 0.004)) * cos(Double(offset) * 0.4))
        }
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
    let actual = try TimelineAudioWaveform.clickOnsets(url)
    precondition(actual.count == beats.count)
    for (time, frame) in zip(actual, beats) {
        precondition(abs(time - Double(frame) / rate) <= 1 / rate, "Pre-echo must not shift the marker before the actual click attack")
    }
    let sections = ClickTempoDetector.sections(onsets: actual)
    precondition(sections.count == 1 && sections[0].bpm == 120)
    precondition(abs(sections[0].position - Double(beats[0]) / rate) <= 1 / rate)
}
print("CLICK_PRE_ECHO_REJECTED_SAMPLE_EXACT_MARKER_ANCHOR_44100_48000_OK")

// Exercise the complete PCM -> onset -> tempo map path, not just synthetic
// timestamps. A gradual acceleration and fractional final rate must stay in
// phase after many bars at either common audio sample rate.
for rate in [44100.0, 48000.0] {
    let url = directory.appendingPathComponent("accelerando-\(Int(rate)).wav")
    let rates = [Double](repeating: 130, count: 32)
        + (0..<64).map { 130 + Double($0) * 10 / 63 }
        + [Double](repeating: 140.4270739, count: 160)
    var time = 0.123, beats: [Double] = []
    for bpm in rates { beats.append((time * rate).rounded() / rate); time += 60 / bpm }
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((time + 1) * rate))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: Int(pcm.frameLength)) }
    for (index, beat) in beats.enumerated() {
        let first = Int((beat * rate).rounded())
        for offset in 0..<Int(rate * 0.02) {
            pcm.floatChannelData![index % 2][first + offset] = Float(0.7 * exp(-Double(offset) / (rate * 0.004)) * cos(Double(offset) * 0.3))
        }
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
    let onsets = try TimelineAudioWaveform.clickOnsets(url)
    precondition(onsets.count == beats.count)
    let sections = ClickTempoDetector.sections(onsets: onsets)
    precondition(sections.contains { $0.bpm > 130.1 && $0.bpm < 139.9 })
    precondition(abs(sections.last!.bpm - 140.4270739) < 0.0001)
    for (index, onset) in onsets.enumerated() {
        let section = sections.last { $0.position <= onset }!
        let anchor = onsets.firstIndex(of: section.position)!
        let predicted = section.position + Double(index - anchor) * 60 / section.bpm
        // Analysis deliberately ignores tiny fluctuations instead of generating
        // a marker for every millisecond of a ramp. Require the same bounded
        // phase as the model tests, and stricter phase once the tempo is steady.
        let allowedPhase = section == sections.last ? 0.001001 : 0.0201
        precondition(abs(predicted - onset) <= allowedPhase, "tempo map must remain phase bounded through acceleration without drift in the final steady section")
    }
}
print("CLICK_PCM_ACCELERANDO_AND_FRACTIONAL_FINAL_TEMPO_NO_DRIFT_44100_48000_OK")

// A different sound on the downbeat must not turn a perfectly regular source
// clock into fractional BPMs. Use actual PCM, including a slow rounded attack:
// the 20% onset threshold reaches it roughly 23 ms after the beat, whereas the
// other three clicks have immediate attacks. That is a timbre-dependent offset,
// not an accelerando, and repeats identically every bar.
func roundedAccentTransients(rate: Double, bpms: [Double], name: String) throws -> [Double] {
    let url = directory.appendingPathComponent("rounded-accent-\(Int(rate))-\(name).wav")
    var time = 0.123, beats: [Double] = []
    for bpm in bpms { beats.append((time * rate).rounded() / rate); time += 60 / bpm }
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let frames = Int((time + 0.1) * rate)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0, count: frames) }
    for (index, beat) in beats.enumerated() {
        let accent = index % 4 == 0
        let first = Int((beat * rate).rounded())
        let amplitude = accent ? 0.8 : 0.28
        let frequency = accent ? 900.0 : 2200.0
        for offset in 0..<Int(rate * 0.07) {
            let t = Double(offset) / rate
            let envelope: Double
            if accent { envelope = t < 0.034 ? pow(t / 0.034, 4) : exp(-(t - 0.034) / 0.005) }
            else { envelope = exp(-t / 0.004) }
            pcm.floatChannelData![index % 2][first + offset] = Float(amplitude * envelope * cos(2 * .pi * frequency * t))
        }
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
    let onsets = try TimelineAudioWaveform.clickOnsets(url)
    precondition(onsets.count == beats.count, "Different attacks must still yield exactly one pulse per beat")
    for index in beats.indices {
        let offset = onsets[index] - beats[index]
        if index % 4 == 0 {
            precondition(offset > 0.020 && offset < 0.027, "Fixture must exercise a materially delayed rounded attack: \(offset)")
        } else {
            precondition(abs(offset) <= 1 / rate, "Sharp clicks must retain their original sample positions")
        }
    }
    return onsets
}

var roundedAccentFailures: [String] = []
for rate in [44100.0, 48000.0] {
    for bpm in [120.0, 130.0, 140.0, 156.0] {
        let onsets = try roundedAccentTransients(rate: rate, bpms: Array(repeating: bpm, count: 48), name: "steady-\(Int(bpm))")
        let sections = ClickTempoDetector.sections(onsets: onsets)
        if sections.count != 1 || sections.first?.bpm != bpm {
            roundedAccentFailures.append("\(Int(rate)) Hz, steady \(Int(bpm)) BPM: \(sections.map(\.bpm))")
        }
        precondition(sections.first?.position == onsets.first, "Tempo analysis must preserve the measured first attack")
    }
    let rates = Array(repeating: 120.0, count: 8) + Array(repeating: 130.0, count: 8)
        + Array(repeating: 140.0, count: 8) + Array(repeating: 156.0, count: 16)
    let onsets = try roundedAccentTransients(rate: rate, bpms: rates, name: "two-bar-changes")
    let sections = ClickTempoDetector.sections(onsets: onsets)
    if sections.map(\.bpm) != [120, 130, 140, 156] {
        roundedAccentFailures.append("\(Int(rate)) Hz, real two-bar changes: \(sections.map(\.bpm))")
    }
    if sections.map(\.position) != [onsets[0], onsets[8], onsets[16], onsets[24]] {
        roundedAccentFailures.append("\(Int(rate)) Hz, real change anchors: \(sections.map(\.position))")
    }
}
if !roundedAccentFailures.isEmpty {
    FileHandle.standardError.write(Data(("Rounded accent regression:\n" + roundedAccentFailures.joined(separator: "\n") + "\n").utf8))
}
precondition(roundedAccentFailures.isEmpty, "Rounded accent regression")
print("CLICK_PCM_ROUNDED_ACCENTS_INTEGER_TEMPO_AND_TWO_BAR_CHANGES_44100_48000_OK")
