import AppKit
import AVFoundation

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-drop-preview-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let url = folder.appendingPathComponent("Teste de duração.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
do {
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
    buffer.frameLength = 96000
    try file.write(from: buffer)
}
let original = try Data(contentsOf: url)
precondition(GridExternalMedia.duration(at: url) == 2, "preview duration must match the source frame count")
precondition(GridExternalMedia.duration(at: folder.appendingPathComponent("missing.wav")) == nil)
Task { @MainActor in
    let preview = GridInsertionPreview()
    preview.externalSources([url])
    preview.update(12)
    preview.targetExternal(.init(y: 100, height: 64, color: 0x123456, newTracksY: 400, newTrackHeight: 64))
    precondition(preview.externalFiles.first?.name == "Teste de duração", "show the item name immediately, before metadata finishes")
    preview.update(15)
    for _ in 0..<200 {
        if preview.externalFiles.first?.duration != nil { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    precondition(preview.externalFiles.first?.duration == 2 && preview.time == 15,
                 "metadata completion must preserve the latest drag position")
    precondition(preview.externalTarget?.y == 100)
    preview.externalSources([]); preview.update(nil)
    // A late completion from a cancelled drag must never resurrect its preview.
    preview.externalSources([url]); preview.externalSources([])
    try? await Task.sleep(nanoseconds: 50_000_000)
    precondition(preview.externalFiles.isEmpty && preview.externalTarget == nil && preview.time == nil)
    let after = try! Data(contentsOf: url)
    let names = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
    precondition(after == original && names == [url.lastPathComponent], "hovering cannot copy media or create waveform caches")
    try? FileManager.default.removeItem(at: folder)
    print("GRID_EXTERNAL_PREVIEW_REAL_DURATION_NAME_LATEST_POSITION_AND_CANCELLATION_OK")
    exit(0)
}
dispatchMain()
