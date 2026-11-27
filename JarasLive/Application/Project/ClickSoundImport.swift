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

public enum ImpulseResponseImport {
    public static func copy(_ source: URL, to directory: URL) throws -> String {
        let formats = ["wav", "aif", "aiff"]
        guard formats.contains(source.pathExtension.lowercased()) else {
            throw ProjectError.invalid("Choose a WAV or AIFF impulse response.")
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let audio = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = audio.processingFormat.sampleRate
        let channels = Int(audio.processingFormat.channelCount)
        guard audio.length > 0, (1...2).contains(channels), (8000...384000).contains(rate),
              Double(audio.length) <= 10 * rate,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
            throw ProjectError.invalid("Choose a mono or stereo impulse response up to 10 seconds.")
        }
        var energy = 0.0
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
            for channel in 0..<channels {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = Double(samples[channel][frame])
                    guard sample.isFinite else { throw ProjectError.invalid("The impulse response contains invalid samples.") }
                    energy += sample * sample
                }
            }
        }
        guard energy > 1e-12 else { throw ProjectError.invalid("The impulse response is silent.") }
        return try ClickSoundImport.copy(source, to: directory).path
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
