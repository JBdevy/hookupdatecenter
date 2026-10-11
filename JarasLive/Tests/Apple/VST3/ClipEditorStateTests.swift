import Foundation
import AppKit
import AVFoundation

@main struct ClipEditorStateTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let path = CommandLine.arguments[1], clipID = UUID(), trackID = UUID()
        let show = ShowController()
        var plugin = ExternalPlugin(classID: "1234123456785678ABCDEF0012345678", name: "Gain fixture", path: path, category: "Fx")
        plugin.id = "take-fixture"
        var settings = NativeFXSettings(); settings.inserted = [plugin.effectKey]; settings.externalPlugins = [plugin]
        show.snapshot.project.clips[clipID] = TestClip(id: clipID, fx: settings)
        show.trackSettings[trackID] = settings
        let originalTrack = show.trackSettings[trackID], originalMaster = show.masterSettings
        let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let source = AVAudioSourceNode(format: format) { silent, _, frames, list in
            silent.pointee = false
            for channel in UnsafeMutableAudioBufferListPointer(list) { channel.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.2, count: Int(frames)) }
            return noErr
        }
        let node = JarasVST3.makeNode(); engine.attach(source); engine.attach(node)
        engine.connect(source, to: node, format: format); engine.connect(node, to: engine.mainMixerNode, format: format)
        let spec = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plugin)) as! [String: Any]
        try JarasVST3.configure(node, plugins: [spec]); engine.prepare(); try engine.start()
        defer { engine.stop() }
        StemAudioPlayback.shared.chains[clipID] = NativeEffectsChain(node: node)
        let editor = ClipExternalPluginHostView(show: show, clip: clipID, effect: plugin.effectKey)
        precondition(StemAudioPlayback.shared.observed.contains(clipID))
        precondition(editor.subviews.first is NSScrollView, "native take editor is hosted inside its own viewport")
        JarasVST3.setParameter(node, identifier: plugin.id, parameter: 0, value: 0.37)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        for _ in 0..<4 { let status = try engine.renderOffline(512, to: buffer); precondition(status == .success) }
        ExternalPluginState.captureAll(show: show)
        let saved = show.clipFXSettings(clipID)
        precondition(show.clipWrites == [clipID] && show.trackWrites == 0, "take edits must never write track or Master settings")
        precondition(show.trackSettings[trackID] == originalTrack && show.masterSettings == originalMaster)
        let savedPlugin = saved.externalPlugins![0]
        let bytes = Data(base64Encoded: savedPlugin.componentState!)!
        let gain = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        precondition(abs(gain - 0.37) < 0.000001, "edited processor preset must be captured")
        let reopened = try JSONDecoder().decode(NativeFXSettings.self, from: JSONEncoder().encode(saved))
        precondition(reopened == saved)
        let lookupCount = StemAudioPlayback.shared.lookups
        ExternalPluginState.captureAll(show: show)
        precondition(StemAudioPlayback.shared.lookups == lookupCount, "saving must not prepare unobserved item chains")
        precondition(show.clipWrites == [clipID], "unchanged state must not create another undo/save edit")
        editor.suspend()
        precondition(!StemAudioPlayback.shared.observed.contains(clipID), "closing releases the protected item voice")
        editor.resume()
        precondition(StemAudioPlayback.shared.observed.contains(clipID))
        show.snapshot.project.id = UUID()
        JarasVST3.setParameter(node, identifier: plugin.id, parameter: 0, value: 0.81)
        for _ in 0..<4 { let status = try engine.renderOffline(512, to: buffer); precondition(status == .success) }
        editor.suspend()
        precondition(show.clipWrites == [clipID], "closing an editor from an old project cannot mutate the replacement project")
        precondition(show.automationWrites == 0)
        print("Clip VST3 editor preset/save isolation, no-op capture, voice observation and project teardown passed")
    }
}
