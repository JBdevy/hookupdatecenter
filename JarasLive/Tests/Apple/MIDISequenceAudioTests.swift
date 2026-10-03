import AVFoundation
import Foundation
let rate=Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
let engine=AVAudioEngine(),format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:256)
let instrument=try JarasSoundFont(url:URL(fileURLWithPath:CommandLine.arguments[1]),sampleRate:rate)
instrument.setEnvelopeAttack(0.001,hold:0,decay:0.001,sustain:1,release:0.005)
engine.attach(instrument.node);engine.connect(instrument.node,to:engine.mainMixerNode,format:format)
let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:256)!
instrument.setSequenceNotes([["start":0.05,"end":0.20,"pitch":60,"velocity":110,"channel":1]])
instrument.sequenceHead(0,position:0,clock:0,running:true,loopStart:0,loopEnd:0)
try engine.start()
var before=0.0,during=0.0,after=0.0
for _ in 0..<Int(rate*0.4/256) {
 let start=Double(engine.manualRenderingSampleTime)/rate
 guard try engine.renderOffline(256,to:output) == .success else {fatalError("render failed")}
 for f in 0..<Int(output.frameLength) {
  let t=start+Double(f)/rate,value=Double(output.floatChannelData![0][f]);precondition(value.isFinite)
  if t<0.05 {before=max(before,abs(value))};if t>0.08&&t<0.19 {during=max(during,abs(value))};if t>0.3 {after=max(after,abs(value))}
 }
}
precondition(before<0.000001 && during>0.001 && after<0.000001,"Real MIDI PCM: before=\(before), during=\(during), after=\(after)")
let clock=Double(engine.manualRenderingSampleTime)/rate
instrument.sequenceHead(0,position:0.12,clock:clock,running:true,loopStart:0,loopEnd:0)
var chase=0.0
for _ in 0..<8 {try engine.renderOffline(256,to:output);for f in 0..<Int(output.frameLength){chase=max(chase,abs(Double(output.floatChannelData![0][f])))}}
precondition(chase>0.001,"Seeking into a held note must sound")
instrument.sequenceHead(0,position:0,clock:0,running:false,loopStart:0,loopEnd:0)
for _ in 0..<40 {try engine.renderOffline(256,to:output)}
precondition((0..<Int(output.frameLength)).allSatisfy { abs(output.floatChannelData![0][$0])<0.000001 },"Stop releases MIDI notes")
print("MIDI_REAL_PCM_SILENT_BEFORE_ONSET_AUDIBLE_NOTE_RELEASE_SEEK_AND_STOP_OK rate=\(rate)")
engine.stop()
