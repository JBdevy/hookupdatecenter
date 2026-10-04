import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor func testClipboard() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let clipboard = GridMediaClipboard(pasteboard: board)
    let audio = URL(fileURLWithPath: "/tmp/catlive-paste.wav")
    let image = URL(fileURLWithPath: "/tmp/catlive-paste.png")
    let video = URL(fileURLWithPath: "/tmp/catlive-paste.mov")
    precondition(clipboard.source() == .none)
    board.writeObjects([audio as NSURL])
    precondition(clipboard.source() == .files([audio]))
    clipboard.didCopyItems()
    precondition(clipboard.source() == .items, "internal copy replaces stale Finder files")
    board.clearContents()
    board.writeObjects([video as NSURL, image as NSURL])
    precondition(clipboard.source() == .files([video, image]), "a new Finder copy wins over internal items and preserves order")
    precondition(GridMediaClipboard.containsVisualMedia([video, image]))
    precondition(!GridMediaClipboard.containsVisualMedia([audio]))
    board.clearContents()
    board.setString("ordinary text", forType: .string)
    precondition(clipboard.source() == .none, "text must not paste stale items")
    let unsupported = URL(fileURLWithPath: "/tmp/catlive-paste.pdf")
    board.clearContents()
    board.writeObjects([unsupported as NSURL])
    precondition(clipboard.source() == .files([unsupported]), "unsupported files reach the shared import validation and its error dialog")
    precondition(!GridMediaClipboard.containsVisualMedia([unsupported]))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let audioFile = folder.appendingPathComponent("Audio.m4a")
    do {
        let file = try! AVAudioFile(forWriting: audioFile, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for frame in 0..<4410 { buffer.floatChannelData![0][frame] = 0.1 }
        try! file.write(from: buffer)
    }
    let audioMP4 = folder.appendingPathComponent("Audio.mp4")
    try! FileManager.default.moveItem(at: audioFile, to: audioMP4)
    precondition(!GridMediaClipboard.containsVisualMedia([audioMP4]), "audio-only MP4 follows the same audio routing as drag and drop")
    print("GRID_MEDIA_CLIPBOARD_OK")
}
MainActor.assumeIsolated { testClipboard() }
