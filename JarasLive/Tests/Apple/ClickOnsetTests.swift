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
    precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("WF/" + url.lastPathComponent + ".waveform").path))
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
