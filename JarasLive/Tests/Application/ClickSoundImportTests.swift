import XCTest
import AVFoundation
@testable import JarasApplication

final class ClickSoundImportTests: XCTestCase {
    func testSupportedSoundsAreIndependentCopiesAndSameNamesDoNotOverwrite() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for index in 0..<4410 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.2) * 0.2) }
        for ext in ["wav", "aiff"] {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: ext == "aiff"]
            let file = try AVAudioFile(forWriting: sources.appendingPathComponent("Click." + ext), settings: settings)
            try file.write(from: buffer)
        }
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Apple/Resources/Click.mp3")
        try fm.copyItem(at: bundled, to: sources.appendingPathComponent("Click.mp3"))
        let project = root.appendingPathComponent("Project")
        for ext in ["wav", "aiff", "mp3"] {
            let source = sources.appendingPathComponent("Click." + ext)
            let data = try Data(contentsOf: source)
            let first = try ClickSoundImport.copy(source, to: project)
            let second = try ClickSoundImport.copy(source, to: project)
            XCTAssertNotEqual(first.path, second.path)
            XCTAssertTrue(first.path.hasPrefix("Stems/Click/"))
            try fm.removeItem(at: source)
            XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(first.path)), data)
            XCTAssertGreaterThan(try AVAudioFile(forReading: project.appendingPathComponent(second.path)).length, 0)
        }
        let invalid = sources.appendingPathComponent("bad.mp3")
        try Data("invalid".utf8).write(to: invalid)
        let before = try fm.subpathsOfDirectory(atPath: project.path)
        XCTAssertThrowsError(try ClickSoundImport.copy(invalid, to: project))
        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: project.path), before)
    }
}
