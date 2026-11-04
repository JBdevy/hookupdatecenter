import Foundation
import AVFoundation

let path = CommandLine.arguments[1]
var scanError: NSError?
let plugin = JarasVST3.scan(path, error: &scanError)[0]
let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let source = AVAudioSourceNode(format: format) { _, _, frames, list in
    for b in UnsafeMutableAudioBufferListPointer(list) { b.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0, count: Int(frames)) }
    return noErr
}
let node = JarasVST3.makeNode()
engine.attach(source); engine.attach(node)
engine.connect(source, to: node, format: format); engine.connect(node, to: engine.mainMixerNode, format: format)
node.auAudioUnit.isRenderingOffline = true
try JarasVST3.configure(node, plugins: [["id": "clock", "classID": plugin["classID"]!, "path": path]])
JarasVST3.setTempoMap(node, points: [
    ["seconds": 0, "bpm": 120, "beats": 4, "unit": 4],
    ["seconds": 10, "bpm": 90, "beats": 7, "unit": 8],
    ["seconds": 20, "bpm": 60, "beats": 3, "unit": 4]
])
engine.prepare(); try engine.start()
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
func render() throws -> [Double] {
    let status = try engine.renderOffline(512, to: buffer)
    precondition(status == .success)
    let state = JarasVST3.state(node, identifier: "clock")!
    let bytes = Data(base64Encoded: state["componentState"] as! String)!
    return bytes.withUnsafeBytes { raw in (0..<8).map { raw.loadUnaligned(fromByteOffset: 12 + $0 * 8, as: Double.self) } }
}
func near(_ actual: Double, _ expected: Double) { precondition(abs(actual - expected) < 0.00005, "\(actual) != \(expected)") }
func seek(_ position: Double, playing: Bool, loopStart: Double = 0, loopEnd: Double = 0) {
    JarasVST3.transportClock(node, position: position, clock: Double(engine.manualRenderingSampleTime)/48000,
        playing: playing, loopStart: loopStart, loopEnd: loopEnd)
}
seek(12, playing: false)
for _ in 0..<4 {
    let values = try render()
    near(values[0],90); near(values[1],23); near(values[2],12); near(values[3],20)
    near(values[4],7); near(values[5],8); near(values[6],0)
}
// No UI updates while rendering: the audio callback must cross the marker on
// its own and integrate musical position, rather than multiplying by new BPM.
seek(9.99, playing: true)
for block in 0..<4 {
    let values = try render(), seconds = 9.99 + Double(block * 512)/48000
    near(values[2],seconds); near(values[0], seconds < 10 ? 120 : 90)
    near(values[1], seconds < 10 ? seconds*2 : 20+(seconds-10)*1.5)
    near(values[6],1)
    precondition(Int(values[7]) & (1 << 11) != 0, "VST3 bar position validity flag")
}
seek(21, playing: true)
var values = try render(); near(values[0],60); near(values[1],36); near(values[4],3)
seek(11.999, playing: true, loopStart: 10, loopEnd: 12)
_ = try render(); values = try render(); near(values[2],10.0096666667)
seek(4, playing: false); values = try render(); near(values[0],120); near(values[2],4); near(values[6],0)
engine.stop()
print("VST3_ACTUAL_PROCESS_CONTEXT_TEMPO_SEEK_STOP_LOOP_AND_BAR_OK")
