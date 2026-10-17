import AVFoundation

let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let engine = AVAudioEngine(), player = AVAudioPlayerNode(), effect = JarasEqualizer.makeNode()
engine.attach(player); engine.attach(effect)
engine.connect(player, to: effect, format: format); engine.connect(effect, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
input.frameLength = 48000
for channel in 0..<2 { for i in 0..<48000 { input.floatChannelData![channel][i] = 0.25 } }
player.scheduleBuffer(input, at: nil, options: .loops, completionHandler: nil)
try engine.start(); player.play()
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
for (curvature, shape) in [(0.0,1.0),(1.0,0.0),(-1.0,-0.5),(0.4,0.8)] {
    let start = Double(engine.manualRenderingSampleTime)
    JarasEqualizer.setInputFade(effect, fadeIn: 1, fadeOut: 0, fadeInCurve: curvature, fadeInSCurve: shape, fadeOutCurve: 0, fadeOutSCurve: 1, duration: 2, position: 0.25, hostTime: 0, sampleTime: start)
    for block in 0..<12 {
        let status = try engine.renderOffline(512, to: output); precondition(status == .success)
        for channel in 0..<2 { for sample in 0..<512 {
            let t = 0.25 + Double(block * 512 + sample) / 48000
            let s = t + shape * (t*t*(3-2*t)-t), bias = exp2(4*curvature)
            let expected = 0.25 * s / (bias+(1-bias)*s)
            precondition(abs(Double(output.floatChannelData![channel][sample])-expected)<0.00002, "Fade PCM differs from its curve")
        } }
    }
}
engine.stop()
print("ITEM_FADE_TWO_PARAMETERS_NATIVE_PCM_49152_SAMPLES_OK")
