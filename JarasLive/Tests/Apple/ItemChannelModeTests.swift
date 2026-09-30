import AVFoundation
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let effect = JarasEqualizer.makeNode()
engine.attach(player); engine.attach(effect)
engine.connect(player, to: effect, format: format)
engine.connect(effect, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
input.frameLength = 48000
for i in 0..<48000 { input.floatChannelData![0][i] = 0.2; input.floatChannelData![1][i] = -0.6 }
player.scheduleBuffer(input, at: nil, options: .loops, completionHandler: nil)
try engine.start(); player.play()
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
for (mode, left, right) in [(0,0.2,-0.6), (1,0.2,0.2), (2,-0.6,-0.6), (3,-0.2,-0.2), (0,0.2,-0.6)] {
    JarasEqualizer.setInputChannelMode(effect, mode: Int32(mode))
    for _ in 0..<5 { let status = try engine.renderOffline(1024, to: output); precondition(status == .success) }
    for i in 0..<1024 {
        precondition(abs(Double(output.floatChannelData![0][i]) - left) < 0.0001)
        precondition(abs(Double(output.floatChannelData![1][i]) - right) < 0.0001)
    }
}
engine.stop()
print("ITEM_CHANNEL_MONO_LEFT_RIGHT_MIX_AND_STEREO_RESTORE_PCM_OK")
