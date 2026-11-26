import Foundation
import AVFoundation

public enum ClickSoundImport {
    public static func copy(_ source: URL, to directory: URL) throws -> AudioFile {
        guard ["wav", "aif", "aiff", "mp3"].contains(source.pathExtension.lowercased()) else {
            throw ProjectError.invalid("Choose a WAV, AIFF or MP3 file.")
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let audio = try AVAudioFile(forReading: source)
        guard audio.length > 0 else { throw ProjectError.invalid("The click audio is empty.") }
        var names = MediaFileNames(directory: directory.appendingPathComponent("Stems"))
        let relative = "Stems/" + names.allocate(source.lastPathComponent)
        let destination = directory.appendingPathComponent(relative)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return AudioFile(path: relative)
    }
}

public enum TriggerSampleImport {
    public static func copy(_ source: URL, to directory: URL) throws -> String {
        guard ["wav","mp3"].contains(source.pathExtension.lowercased()) else {
            throw ProjectError.invalid("Choose a WAV or MP3 sample.")
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let audio = try AVAudioFile(forReading: source)
        guard audio.length > 0, (1...2).contains(audio.processingFormat.channelCount),
              audio.processingFormat.sampleRate > 0,
              Double(audio.length) / audio.processingFormat.sampleRate <= 60 else {
            throw ProjectError.invalid("Choose a mono or stereo sample up to 60 seconds.")
        }
        return try ClickSoundImport.copy(source, to: directory).path
    }
}
