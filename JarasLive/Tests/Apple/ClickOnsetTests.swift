import Foundation
import AVFoundation
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-click-analysis-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
for rate in [44100.0, 48000.0] {
    let url = directory.appendingPathComponent("click-\(Int(rate)).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 14))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: Int(pcm.frameLength)) }
    let first: [Double] = (0..<12).map { 0.123 + Double($0) * 0.5 }
    let second: [Double] = (0..<12).map { 6.123 + Double($0) * (2.0 / 3.0) }
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
    precondition(sections.count == 2 && abs(sections[0].bpm-120) < 0.02 && abs(sections[1].bpm-90) < 0.02)
    precondition(abs(sections[1].position - 6.123) <= 1/rate)
    precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("WF/" + url.lastPathComponent + ".waveform").path))
}
print("CLICK_PEAK_CACHE_SAMPLE_EXACT_ONSETS_44100_48000_STEREO_AND_TEMPO_CHANGES_OK")
