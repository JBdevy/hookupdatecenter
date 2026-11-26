import Foundation
import AVFoundation

setbuf(stdout, nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-item-print-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"]!
var error: NSError?
let scanned = JarasVST3.scan(path, error: &error)
precondition(error == nil && scanned.count == 1)
let rate = 48000.0, frames = 24000
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
pcm.frameLength = pcm.frameCapacity
for channel in 0..<2 { for frame in 0..<frames {
    pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / rate)) * (channel == 0 ? 0.4 : -0.2)
} }
do {
    let source = try AVAudioFile(forWriting: directory.appendingPathComponent("source.wav"), settings: format.settings)
    try source.write(from: pcm)
}
func pluginFX(_ gain: Float) -> NativeFXSettings {
    var plugin = ExternalPlugin(classID: scanned[0]["classID"] as! String, name: "Item gain", path: path)
    var value = gain
    let state = withUnsafeBytes(of: &value) { Data($0).base64EncodedString() }
    plugin.componentState = state; plugin.controllerState = state
    var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
    return fx
}
func read(_ clip: AudioClip) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: directory.appendingPathComponent(clip.audioFile!.path))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
}
func checkPCM(_ actual: [[Float]], gains: [Float], label: String) {
    for channel in 0..<2 {
        precondition(actual[channel].count == frames * gains.count, "\(label): frame count")
        var maximum: Float = 0
        for (part, gain) in gains.enumerated() { for frame in 0..<frames {
            maximum = max(maximum, abs(actual[channel][part * frames + frame] - pcm.floatChannelData![channel][frame] * gain))
        } }
        precondition(maximum < 0.00001, "\(label): plugin must be baked exactly once, error=\(maximum)")
    }
}
var project = Project.empty(name: "Item plugin print")
var track = Track(id: UUID(), name: "Track", role: .other)
// Track and master processors must remain live, not be baked into an item.
track.fx = pluginFX(0.1); project.masterFX = pluginFX(0.2)
let first = AudioClip(id: UUID(), name: "First", startTime: 30, duration: 0.5,
    audioFile: AudioFile(path: "source.wav"), fx: pluginFX(0.25))
let second = AudioClip(id: UUID(), name: "Second", startTime: 30.5, duration: 0.5,
    audioFile: AudioFile(path: "source.wav"), fx: pluginFX(0.75))
track.clips = [first, second]; project.songs[0].tracks = [track]; project.songs[0].duration = 31
let song = project.songs[0]
let rendered = try ItemReRender.render(project: project, song: song, track: track, clip: first, directory: directory,
    settings: MediaProcessingFormat(format: .wav, bitDepth: 32, bitrate: 320), cancellation: AudioExportCancellation())
checkPCM(try read(rendered), gains: [0.25], label: "Re-render")
precondition(rendered.fx == nil && !rendered.waveform.isEmpty)
let glued = try ItemReRender.glue(project: project, song: song, track: track, clips: [first, second], directory: directory,
    cancellation: AudioExportCancellation())
checkPCM(try read(glued), gains: [0.25, 0.75], label: "Unify")
precondition(glued.fx == nil && !glued.waveform.isEmpty)
var bypassed = first; bypassed.fxBypassed = true
var bypassSong = song; bypassSong.tracks[0].clips = [bypassed]
let dry = try ItemReRender.render(project: project, song: bypassSong, track: bypassSong.tracks[0], clip: bypassed, directory: directory,
    settings: MediaProcessingFormat(format: .wav, bitDepth: 32, bitrate: 320), cancellation: AudioExportCancellation())
checkPCM(try read(dry), gains: [1], label: "Bypassed item")
var broken = first; broken.fx?.externalPlugins?[0].path = directory.appendingPathComponent("Missing.vst3").path
var brokenSong = song; brokenSong.tracks[0].clips = [broken]
let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Stems").path))
for unify in [false, true] {
    var failed = false
    do {
        if unify {
            _ = try ItemReRender.glue(project: project, song: brokenSong, track: brokenSong.tracks[0], clips: [broken], directory: directory,
                cancellation: AudioExportCancellation())
        } else {
            _ = try ItemReRender.render(project: project, song: brokenSong, track: brokenSong.tracks[0], clip: broken, directory: directory,
                settings: MediaProcessingFormat(format: .wav, bitDepth: 32, bitrate: 320), cancellation: AudioExportCancellation())
        }
    } catch { failed = true }
    precondition(failed, "Missing item plugin must abort rather than publish dry audio")
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Stems").path))
    precondition(after == before)
}
print("ITEM_VST3_RERENDER_UNIFY_PRESETS_BYPASS_WAVEFORM_AND_LOAD_FAILURE_OK")

// The item fader must feed the limiter during both print operations. With
// the previous post-FX fader this tone peaked at +4.08 dB despite -0.1 dB.
var limited = first
var limiter = NativeFXSettings(); limiter.appendNative("Limiter")
limiter.limiterParameters.ceiling = -0.1
limited.fx = limiter; limited.gain = 4
for automated in [false, true] {
    if automated {
        limited.gain = 1
        var automation = TrackAutomation()
        automation.envelopes = [TrackEnvelope(target: AutomationTarget(.volume), name: "Volume",
                                              defaultValue: TrackEnvelope.normalizedGain(4))]
        limited.automation = automation
    }
    var limitedSong = song; limitedSong.tracks[0].clips = [limited]
    for unify in [false, true] {
        let printed: AudioClip
        if unify {
            printed = try ItemReRender.glue(project: project, song: limitedSong, track: limitedSong.tracks[0],
                clips: [limited], directory: directory, cancellation: AudioExportCancellation())
        } else {
            printed = try ItemReRender.render(project: project, song: limitedSong, track: limitedSong.tracks[0],
                clip: limited, directory: directory, settings: MediaProcessingFormat(format: .wav, bitDepth: 32, bitrate: 320),
                cancellation: AudioExportCancellation())
        }
        let samples = try read(printed)
        let peak = Double(samples.flatMap { $0 }.map { abs($0) }.max()!)
        let ceiling = pow(10, -0.1 / 20)
        precondition(peak <= ceiling + 0.00001 && peak > ceiling - 0.005,
                     "Printed limiter ceiling exceeded: \(peak), unify=\(unify), automation=\(automated)")
        precondition((printed.gain ?? 1) == 1 && printed.fx == nil && printed.automation == nil)
        print("ITEM_LIMITER_PRINT_CEILING_OK unify=\(unify) automation=\(automated) peak=\(peak)")
    }
}
