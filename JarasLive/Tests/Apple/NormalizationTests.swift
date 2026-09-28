import AVFoundation
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
for rate in [44100.0, 48000.0] {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let name = "tone\(rate).wav", length = Int(rate * 3)
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(length))!; buffer.frameLength = UInt32(length)
        for frame in 0..<length { buffer.floatChannelData![0][frame] = Float(0.5 * sin(Double(frame) * 2 * .pi * 997 / rate)) }
        try file.write(from: buffer)
    }
    let clip = AudioClip(id: UUID(), name: "Tone", startTime: 30, duration: 3, audioFile: AudioFile(path: name))
    let peak = try ItemNormalization.measure(clip, directory: directory, mode: .peak)
    let rms = try ItemNormalization.measure(clip, directory: directory, mode: .rms)
    let lufs = try ItemNormalization.measure(clip, directory: directory, mode: .lufs)
    let tp = try ItemNormalization.measure(clip, directory: directory, mode: .truePeak)
    precondition(abs(peak + 6.0206) < 0.01, "sample peak \(peak)")
    precondition(abs(rms + 9.0309) < 0.01, "RMS integrated \(rms)")
    precondition(abs(lufs + 9.0309) < 0.15, "LUFS calibration \(lufs)")
    precondition(tp >= peak - 0.01 && tp < peak + 0.3, "true peak \(tp)")
    precondition(abs(ItemNormalization.gain(measured: peak, target: -1) - pow(10,5.0206/20)) < 0.001)
}
precondition(ItemNormalization.gain(measured: -80, target: 12) <= pow(10,12.0/20))
precondition(ItemNormalization.gain(measured: -.infinity, target: -1) == 1)
print("NORMALIZATION_LUFS_RMS_PEAK_TRUE_PEAK_44100_48000_AND_GAIN_LIMIT_OK")
let tpFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
do {
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("intersample.wav"), settings: tpFormat.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: tpFormat, frameCapacity: 48000)!; buffer.frameLength = 48000
    for frame in 0..<48000 { buffer.floatChannelData![0][frame] = Float(0.5 * sin(Double(frame) * .pi / 2 + .pi / 4)) }
    try file.write(from: buffer)
}
let tpClip = AudioClip(id: UUID(), name: "Intersample", startTime: 0, duration: 1, audioFile: AudioFile(path: "intersample.wav"))
let samplePeak = try ItemNormalization.measure(tpClip, directory: directory, mode: .peak)
let intersamplePeak = try ItemNormalization.measure(tpClip, directory: directory, mode: .truePeak)
precondition(intersamplePeak > samplePeak + 2.5, "true peak detects peaks between samples")
print("TRUE_PEAK_INTERSAMPLE_DETECTION_OK")

let preferenceSuite = "jaras-normalization-test-" + UUID().uuidString
let defaults = UserDefaults(suiteName: preferenceSuite)!
defer { defaults.removePersistentDomain(forName: preferenceSuite) }
for mode in NormalizationMode.allCases {
    precondition(NormalizationTargetPreferences.target(for: mode,defaults: defaults) == -1)
}
NormalizationTargetPreferences.remember(-0.75,for: .peak,defaults: defaults)
NormalizationTargetPreferences.remember(-1.25,for: .truePeak,defaults: defaults)
NormalizationTargetPreferences.remember(-18,for: .rms,defaults: defaults)
NormalizationTargetPreferences.remember(-23,for: .lufs,defaults: defaults)
let reopened = UserDefaults(suiteName: preferenceSuite)!
precondition(NormalizationTargetPreferences.target(for: .peak,defaults: reopened) == -0.75)
precondition(NormalizationTargetPreferences.target(for: .truePeak,defaults: reopened) == -1.25)
precondition(NormalizationTargetPreferences.target(for: .rms,defaults: reopened) == -18)
precondition(NormalizationTargetPreferences.target(for: .lufs,defaults: reopened) == -23)
NormalizationTargetPreferences.remember(13,for: .peak,defaults: defaults)
NormalizationTargetPreferences.remember(.nan,for: .truePeak,defaults: defaults)
precondition(NormalizationTargetPreferences.target(for: .peak,defaults: defaults) == -0.75)
precondition(NormalizationTargetPreferences.target(for: .truePeak,defaults: defaults) == -1.25)
precondition(NormalizationTargetPreferences.formatted(-18) == "-18.00")
precondition(NormalizationTargetPreferences.formatted(12) == "12.00")
precondition(NormalizationTargetPreferences.formatted(-1.25) == "-1.25")
print("NORMALIZATION_PER_METRIC_TARGETS_PERSIST_AND_FORMAT_TWO_DECIMALS_OK")
