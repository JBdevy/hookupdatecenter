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
        let relative = "Stems/Click/" + UUID().uuidString + "/" + source.lastPathComponent
        let destination = directory.appendingPathComponent(relative)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        return AudioFile(path: relative)
    }
}
