import SwiftUI
import AVFoundation
func waitFor<T>(_ work: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(20)
    while Date()<deadline {
        if let value=work() { return value }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    fatalError("Timed out waiting for waveform")
}
let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:directory) }
for rate in [44100.0,48000.0] {
    let format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
    let count=65536+317
    let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count))!
    pcm.frameLength=AVAudioFrameCount(count)
    for index in 0..<count {
        pcm.floatChannelData![0][index] = Float(0.12+0.31*sin(Double(index)*0.071))
        pcm.floatChannelData![1][index] = index==31000 ? -0.91 : Float(0.02*sin(Double(index)*0.043))
    }
    let live=try LiveRecordedWaveform(rate:rate,channels:2)
    try live.append(pcm)
    let file=directory.appendingPathComponent("source-\(rate).wav")
    do { let writer=try AVAudioFile(forWriting:file,settings:format.settings); try writer.write(from:pcm) }
    let cache=TimelineAudioWaveform()
    let header=waitFor { cache.header(file) }
    for step in [1,256,512,2048] {
        let scale = rate / Double(step*2)
        let span=TimelineAudioWaveform.span(step:step)
        for block in [0,(count-1)/span] {
            let recording=waitFor { live.geometry(start:Int64(block*span),step:step,span:span) }
            let finished=waitFor { cache.geometry(file,header:header,block:block,pixelsPerSecond:scale) }
            for channel in 0..<2 {
                precondition(recording.paths[channel]==finished.paths[channel],
                    "Live/final curve mismatch rate=\(rate) step=\(step) block=\(block) channel=\(channel)")
            }
        }
    }
    let before=waitFor { live.geometry(start:65536,step:1,span:512) }
    let more=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:512)!
    more.frameLength=512
    for channel in 0..<2 { more.floatChannelData![channel].update(repeating:0.4,count:512) }
    try live.append(more)
    let retained=live.geometry(start:65536,step:1,span:512)
    precondition(retained != nil, "Growing waveform must retain its last drawing while refreshing")
    let after=waitFor { () -> TimelineAudioWaveform.Geometry? in
        guard let next=live.geometry(start:65536,step:1,span:512), next.end>before.end else { return nil }
        return next
    }
    precondition(after.end>before.end && after.paths != before.paths,"Growing tail must invalidate only its partial geometry")
    print("LIVE_AND_FINISHED_SIGNED_STEREO_WAVEFORMS_MATCH rate=\(rate)")
}
