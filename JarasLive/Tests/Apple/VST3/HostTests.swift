import Foundation
import AVFoundation
import AppKit
let application = NSApplication.shared
let path = CommandLine.arguments[1]
var scanError: NSError?
let catalog = JarasVST3.scan(path, error: &scanError)
precondition(scanError == nil)
precondition(catalog.count == 1 && catalog[0]["name"] as? String == "Gain fixture")
let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let source = AVAudioSourceNode(format: format) { silent, _, frames, list in
    silent.pointee = false
    for b in UnsafeMutableAudioBufferListPointer(list) { b.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.2, count: Int(frames)) }
    return noErr
}
let plugin = JarasVST3.makeNode(); engine.attach(source); engine.attach(plugin)
engine.connect(plugin, to: engine.mainMixerNode, format: format); engine.connect(source, to: plugin, format: format)
var spec: [String: Any] = ["id": "fixture", "classID": catalog[0]["classID"]!, "path": path, "bypassed": false]
try JarasVST3.configure(plugin, plugins: [spec])
let editor = JarasVST3.editor(plugin, identifier: "fixture")!
precondition(editor.window == nil && editor.frame.size == NSSize(width: 32, height: 32), "the plugin must wait for its actual Cocoa parent window")
let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
let editorParent = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
editorWindow.contentView = editorParent
editorParent.addSubview(editor)
editorWindow.orderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(editor.frame.size == NSSize(width: 980, height: 660), "deferred plugin resize determines the opening editor dimensions: \(editor.frame.size), window=\(editor.window != nil)")
editor.setFrameSize(NSSize(width: 20, height: 20))
precondition(editor.frame.size == NSSize(width: 320, height: 200), "native editor constraints are respected before applying its frame")
editorWindow.contentView = nil
editorWindow.orderOut(nil)
print("VST3_NATIVE_EDITOR_DEFERRED_INITIAL_SIZE_AND_RESIZE_CONSTRAINTS_OK")
engine.prepare(); try engine.start()
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
func peak() throws -> Float {
    for _ in 0..<8 { let status = try engine.renderOffline(512, to: buffer); precondition(status == .success) }
    return abs(buffer.floatChannelData![0][100])
}
func check(_ expected: Float, _ message: String = "DSP level") throws { let result = try peak(); precondition(abs(result-expected) < 0.00001, message + ": \(result) vs \(expected)") }
try check(0.1)
let original = JarasVST3.state(plugin, identifier: "fixture")!
JarasVST3.setParameter(plugin, identifier: "fixture", parameter: 0, value: 0.25)
try check(0.05)
for (key, value) in original { spec[key as! String] = value }
try JarasVST3.configure(plugin, plugins: [spec])
try check(0.1, "saved state restores the same plugin instance")
spec["bypassed"] = true; try JarasVST3.configure(plugin, plugins: [spec])
try check(0.2)
spec["bypassed"] = false; try JarasVST3.configure(plugin, plugins: [spec])
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 60, data2: 100)
try check(0.225)
JarasVST3.silence(plugin)
try check(0.1)
spec["category"] = "Instrument"
try JarasVST3.configure(plugin, plugins: [])
try JarasVST3.configure(plugin, plugins: [spec])
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 60, data2: 100)
try check(0.1, "unarmed instrument rejects new notes while keeping its DSP active")
JarasVST3.instrumentMIDIInput(plugin, enabled: true)
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 60, data2: 100)
try check(0.225)
JarasVST3.instrumentMIDIInput(plugin, enabled: false)
try check(0.225, "disarming never cuts an existing instrument note")
JarasVST3.sendMIDI(plugin, status: 0x80, data1: 60, data2: 0)
try check(0.1, "note-off continues arriving while unarmed")
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 61, data2: 100)
try check(0.1, "further note-ons are blocked after disarming")
JarasVST3.instrumentMIDIInput(plugin, enabled: true)
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 62, data2: 100)
try check(0.225)
JarasVST3.instrumentMIDIInput(plugin, enabled: false)
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 62, data2: 0)
try check(0.1, "zero-velocity note-on remains a valid note-off after disarming")
JarasVST3.instrumentMIDIInput(plugin, enabled: true)
JarasVST3.sendMIDI(plugin, status: 0xb0, data1: 64, data2: 127)
JarasVST3.sendMIDI(plugin, status: 0x90, data1: 60, data2: 100)
try check(0.225)
JarasVST3.instrumentMIDIInput(plugin, enabled: false)
JarasVST3.sendMIDI(plugin, status: 0x80, data1: 60, data2: 0)
try check(0.225, "sustain keeps the disarmed VST3 note sounding")
JarasVST3.sendMIDI(plugin, status: 0xb0, data1: 64, data2: 0)
try check(0.1, "sustain-up reaches the VST3 after disarming")
print("VST3_REC_ARM_NEW_NOTES_ONLY_EXISTING_AUDIO_AND_NOTE_OFF_CONTINUE_OK")
try JarasVST3.configure(plugin, plugins: [])
try check(0.2)
engine.stop()
print("VST3_SCAN_STEREO_DSP_STATE_RESTORE_PARAMETERS_BYPASS_MIDI_AND_REMOVAL_OK")
