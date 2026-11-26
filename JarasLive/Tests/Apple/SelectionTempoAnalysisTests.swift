import AVFoundation
import Foundation
import ObjectiveC

private typealias FileRead = @convention(c) (AVAudioFile, Selector, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

@main struct SelectionTempoAnalysisTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-bpm-range-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hz = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: hz, channels: 2)!
        func wave(_ name: String, tempos: [Double], musical: Bool = false) throws {
            let sectionFrames = Int(hz) * 6
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(tempos.count * sectionFrames))!
            buffer.frameLength = buffer.frameCapacity
            for n in 0..<Int(buffer.frameLength) {
                let bpm = tempos[n / sectionFrames], t = Double(n % sectionFrames) / hz
                let phase = bpm > 0 ? t.truncatingRemainder(dividingBy: 60 / bpm) : 1.0
                let attack = bpm > 0 && phase < 0.06 ? 0.6 * exp(-phase * 100) * cos(2 * .pi * 340 * phase) : 0
                let bed = musical ? 0.06 * sin(t * 145 * 2 * .pi) : 0
                buffer.floatChannelData![0][n] = Float(bed + attack)
                buffer.floatChannelData![1][n] = Float(-bed - attack)
            }
            try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings).write(from: buffer)
        }
        try wave("click.wav", tempos: [90, 150, 120])
        try wave("music.wav", tempos: [100, 100, 100], musical: true)
        try wave("silent.wav", tempos: [0, 0])
        try wave("fractional.wav", tempos: [93.75, 107.29])
        try wave("sustain.wav", tempos: [0], musical: true)
        func track(_ name: String, _ role: TrackRole, _ path: String, offset: Double = 0, rate: Double = 1) -> Track {
            var t = Track(id: UUID(), name: name, role: role)
            var item = AudioClip(id: UUID(), name: name, startTime: 20, duration: (18 - offset) / rate, audioFile: AudioFile(path: path))
            item.playbackRate = rate; item.sourceOffset = offset
            t.clips = [item]
            return t
        }
        var song = Project.empty(name: "Test").songs[0]
        song.duration = 100
        var click = track("Click", .click, "click.wav")
        let bass = track("Bass", .bass, "music.wav")
        song.tracks = [bass, click]
        func bpm(_ s: Song, _ a: Double, _ b: Double) async throws -> Double? {
            try await SelectionTempoAnalysis.detect(song: s, range: a...b, directory: directory)
        }
        func check(_ value: Double?, _ expected: Double) {
            precondition(abs((value ?? -1) - expected) < 1, "Expected \(expected), got \(String(describing: value))")
        }
        check(try await bpm(song, 20, 26), 90)
        // The same 18s stem contains three distinct tempi. Only its middle
        // six seconds may be decoded, in bounded blocks and off the caller.
        let selector = NSSelectorFromString("readIntoBuffer:frameCount:error:")
        let method = class_getInstanceMethod(AVAudioFile.self, selector)!, original = method_getImplementation(method)
        let read = unsafeBitCast(original, to: FileRead.self)
        let checked: @convention(block) (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { file, buffer, frames, error in
            if file.url.lastPathComponent == "click.wav" {
                precondition(file.framePosition >= 48000 && file.framePosition + Int64(frames) <= 96000)
                precondition(frames <= 8192 && !Thread.isMainThread)
            }
            return read(file, selector, buffer, frames, error)
        }
        let implementation = imp_implementationWithBlock(checked)
        method_setImplementation(method, implementation)
        do {
            defer { method_setImplementation(method, original); imp_removeBlock(implementation) }
            check(try await bpm(song, 26, 32), 150)
        }
        check(try await bpm(song, 32, 38), 120)
        click = track("Metronome", .other, "click.wav", offset: 6, rate: 0.8)
        song.tracks = [bass, click]
        check(try await bpm(song, 20, 27.5), 120)
        click.clips[0].loopStart = 6; click.clips[0].loopLength = 2.4
        check(try await bpm(song, 23, 30), 120)
        song.tracks = [track("Click", .click, "silent.wav"), bass]
        check(try await bpm(song, 20, 26), 100)
        song.tracks = [track("Click", .click, "fractional.wav")]
        let intro = try await bpm(song, 20, 26), later = try await bpm(song, 26, 32)
        precondition(abs((intro ?? 0) - 93.75) < 0.03 && abs((later ?? 0) - 107.29) < 0.03)
        var kicks = track("Drums", .drums, "click.wav")
        let oneShot = kicks.clips[0]
        kicks.clips = (0..<10).map { beat in
            var hit = oneShot; hit.id = UUID(); hit.startTime = 20 + Double(beat) * 0.5; hit.duration = 0.1
            return hit
        }
        song.tracks = [kicks]
        check(try await bpm(song, 20, 25), 120)
        song.tracks = [track("Pads", .other, "sustain.wav")]
        let sustained = try await bpm(song, 20, 26)
        precondition(sustained == nil, "A steady carrier is not a rhythmic beat")
        song.tracks = [track("Click", .click, "silent.wav"), bass]
        song.tracks.removeLast()
        let silent = try await bpm(song, 20, 26)
        let empty = try await bpm(song, 2, 9)
        precondition(silent == nil && empty == nil)
        let canceled = Task { try await SelectionTempoAnalysis.detect(song: song, range: 0...35, directory: directory) }
        canceled.cancel()
        do { _ = try await canceled.value; preconditionFailure("Expected cancellation") } catch is CancellationError { }
        print("SELECTION_BPM_WINDOW_OFFSET_RATE_LOOP_CLICK_PRIORITY_MUSIC_FALLBACK_SILENCE_CANCEL_OK")
    }
}

