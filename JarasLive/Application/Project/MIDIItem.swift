import Foundation

/// Quarter-note units in the item's source; trimming keeps this source intact.
public struct MIDINote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var start: Double
    public var length: Double
    public var pitch: Int
    public var velocity: Int = 100
    public var channel: Int = 1
    public init(id: UUID = UUID(), start: Double, length: Double, pitch: Int, velocity: Int = 100, channel: Int = 1) {
        self.id = id; self.start = start; self.length = length; self.pitch = pitch; self.velocity = velocity; self.channel = channel
    }
    public var end: Double { start + length }
}
public enum MIDIGridMode: String, Codable, CaseIterable, Sendable {
    case straight, triplet, dotted, swing
    public var title: String { rawValue.capitalized }
}
public struct MIDIGrid: Codable, Equatable, Sendable {
    public static let divisions = [1, 2, 4, 8, 16, 32, 64, 128]
    public var division = 16
    public var mode: MIDIGridMode = .straight
    public var swing = 0.5
    public init(division: Int = 16, mode: MIDIGridMode = .straight, swing: Double = 0.5) {
        self.division = division; self.mode = mode; self.swing = swing
    }
    public var step: Double { 4 / Double(division) * (mode == .triplet ? 2.0 / 3 : mode == .dotted ? 1.5 : 1) }
    public func line(_ index: Int) -> Double {
        Double(index) * step + (mode == .swing && index % 2 != 0 ? step * min(0.95, max(0, swing)) : 0)
    }
    public func snap(_ beat: Double, bypass: Bool = false) -> Double {
        guard beat.isFinite else { return 0 }
        guard !bypass else { return max(0, beat) }
        let center = Int(max(0, beat) / step)
        return (max(0, center - 2)...(center + 2)).map(line).min { abs($0 - beat) < abs($1 - beat) } ?? 0
    }
    public func quantize(_ notes: [MIDINote], selected: Set<UUID>? = nil, strength: Double = 1, lengths: Bool = false) -> [MIDINote] {
        let amount = min(1, max(0, strength))
        return notes.map { source in
            guard selected == nil || selected!.contains(source.id) else { return source }
            var note = source
            note.start += (snap(source.start) - source.start) * amount
            if lengths {
                let end = source.end + (snap(source.end) - source.end) * amount
                note.length = max(1.0 / 960, end - note.start)
            }
            return note
        }
    }
}
public struct MIDIItem: Codable, Equatable, Sendable {
    public var notes: [MIDINote] = []
    public var sourceBPM: Double = 120
    public var grid = MIDIGrid()
    public init(notes: [MIDINote] = [], sourceBPM: Double = 120, grid: MIDIGrid = MIDIGrid()) {
        self.notes = notes; self.sourceBPM = sourceBPM; self.grid = grid
    }
    public func validate() throws {
        guard sourceBPM.isFinite, (1...1000).contains(sourceBPM), MIDIGrid.divisions.contains(grid.division),
              grid.swing.isFinite, (0...0.95).contains(grid.swing), notes.count <= 100_000 else { throw ProjectError.invalid("Invalid MIDI item") }
        var ids = Set<UUID>()
        for n in notes {
            guard ids.insert(n.id).inserted, n.start.isFinite, n.length.isFinite, n.start >= 0, n.length > 0, n.end <= 10_000_000,
                  (0...127).contains(n.pitch), (1...127).contains(n.velocity), (1...16).contains(n.channel) else { throw ProjectError.invalid("Invalid MIDI note") }
        }
    }
}
public struct MIDIPlaybackNote: Equatable, Sendable {
    public var sourceID: UUID
    public var start: Double
    public var end: Double
    public var pitch: Int
    public var velocity: Int
    public var channel: Int
}
public extension MIDIPlaybackNote {
    /// Integer UUID words remain exact in the numeric bridge dictionary and
    /// identify the same held note after a tempo/timebase remap.
    var sequenceValues: [String: Double] {
        var result = ["start": start, "end": end, "pitch": Double(pitch), "velocity": Double(velocity), "channel": Double(channel)]
        var uuid = sourceID.uuid
        withUnsafeBytes(of: &uuid) { bytes in
            for word in 0..<4 {
                var value: UInt32 = 0
                for byte in 0..<4 { value |= UInt32(bytes[word * 4 + byte]) << (byte * 8) }
                result["sourceID\(word)"] = Double(value)
            }
        }
        return result
    }
}
public extension AudioClip {
    /// A take instrument owns its own notes and audio; it must not also feed
    /// the track instrument. Bypassed/missing inserts retain the track path.
    var hasTakeInstrument: Bool {
        midi != nil && fxBypassed != true && fx?.externalPlugins?.contains(where: {
            !$0.bypassed && $0.category.contains("Instrument") && fx?.inserted.contains($0.effectKey) == true
        }) == true
    }
    /// Same source offset/rate contract as audio, including left trims and splits.
    func midiPlaybackNotes() -> [MIDIPlaybackNote] {
        guard let midi, muted != true else { return [] }
        let seconds = 60 / midi.sourceBPM
        let rate = audioRate
        var result: [MIDIPlaybackNote] = []
        let sourceEnd = sourceOffset + duration * rate
        for note in midi.notes {
            let noteStart = note.start * seconds, noteEnd = note.end * seconds
            let loop = loopLength.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            let origin = loopStart ?? 0
            let firstCycle = loop.map { max(0, Int(floor((sourceOffset - origin) / $0))) } ?? 0
            let lastCycle = loop.map { max(firstCycle, Int(ceil((sourceEnd - origin) / $0)) - 1) } ?? 0
            for cycle in firstCycle...lastCycle {
                let shift = Double(cycle) * (loop ?? 0)
                let rawStart = loop == nil ? noteStart : max(origin, noteStart) + shift
                let rawEnd = loop.map { min(origin + $0, noteEnd) + shift } ?? noteEnd
                guard rawEnd > rawStart else { continue }
                let start = max(startTime, startTime + (rawStart - sourceOffset) / rate)
                let end = min(startTime + duration, startTime + (rawEnd - sourceOffset) / rate)
                if end > start {
                    let fadedVelocity = min(127, max(0, (Double(note.velocity) * (gain ?? 1) * fadeGain(at: start)).rounded()))
                    guard fadedVelocity > 0 else { continue }
                    // Each repetition must retrigger; only pieces of the same
                    // held note across tempo boundaries share an identity.
                    var identifier = note.id.uuid
                    if cycle > 0 {
                        withUnsafeMutableBytes(of: &identifier) { bytes in
                            for index in 0..<8 { bytes[index + 8] ^= UInt8(truncatingIfNeeded: UInt64(cycle) >> (index * 8)) }
                        }
                    }
                    result.append(MIDIPlaybackNote(sourceID: UUID(uuid: identifier), start: start, end: end, pitch: note.pitch,
                        // Saturate in floating point before converting: a valid
                        // finite item gain can exceed Int.max when multiplied.
                        velocity: Int(fadedVelocity), channel: note.channel))
                }
            }
        }
        return (gain ?? 1) <= 0 ? [] : result.sorted { $0.start < $1.start }
    }
    /// Muting a take or lowering its gain must not erase its notes from the
    /// timeline. Keep the same trim/rate/loop mapping as playback, without its
    /// audibility filters; the source item's saved state remains unchanged.
    func midiDisplayNotes() -> [MIDIPlaybackNote] {
        var visible = self
        visible.muted = false; visible.gain = 1; visible.fadeIn = nil; visible.fadeOut = nil
        return visible.midiPlaybackNotes()
    }
}

public extension Song {
    func midiPlaybackNotes(in clip: AudioClip) -> [MIDIPlaybackNote] {
        var result: [MIDIPlaybackNote] = [], last: [UUID: Int] = [:]
        var source = clip.sourceOffset
        for var segment in tempoAudioSegments(clip) {
            segment.sourceOffset = source
            segment.fadeIn = nil; segment.fadeOut = nil
            source += segment.duration * segment.audioRate
            for note in segment.midiPlaybackNotes() {
                if let index = last[note.sourceID], abs(result[index].end - note.start) < 0.000001 {
                    result[index].end = note.end
                } else { last[note.sourceID] = result.count; result.append(note) }
            }
        }
        return result.compactMap { note -> MIDIPlaybackNote? in
            var faded = note
            faded.velocity = Int((Double(note.velocity) * clip.fadeGain(at: note.start)).rounded())
            return faded.velocity > 0 ? faded : nil
        }.sorted { $0.start < $1.start }
    }
}

/// Captures performed notes in the same source-time units used by MIDI playback.
/// Host timestamps are converted to timeline positions by the recording coordinator.
public struct MIDIRecordingTake: Sendable {
    public let id: UUID
    public let track: UUID
    public let startTime: Double
    public let sourceBPM: Double
    public let name: String
    private let song: Song
    private let lane: Int
    private let regionOwnerID: UUID?
    private struct Key: Hashable, Sendable { let source: Int32; let channel: Int; let pitch: Int }
    private struct Press: Sendable { var note: MIDINote; var released = false }
    private struct Pedal: Hashable, Sendable { let source: Int32; let channel: Int }
    private var pressed: [Key: Press] = [:]
    private var sustain: Set<Pedal> = []
    private var notes: [MIDINote] = []
    public init(track: UUID, song: Song, startTime: Double, lane: Int = 0, id: UUID = UUID(), name: String = "MIDI recording") {
        self.track = track; self.song = song; self.startTime = startTime; self.lane = lane; self.id = id; self.name = name
        regionOwnerID = song.regionOwner(at: startTime)
        let probe = AudioClip(id: id, name: "MIDI", startTime: startTime, duration: 0.01, regionOwnerID: regionOwnerID)
        let rate = song.tempoAudioSegments(probe).first?.audioRate ?? 1
        sourceBPM = (song.activeTempoMarker(at: startTime)?.tempoBPM ?? song.bpm) / rate
    }
    private func beat(at position: Double) -> Double {
        let elapsed = max(0, position - startTime)
        guard elapsed > 0 else { return 0 }
        let probe = AudioClip(id: id, name: "MIDI", startTime: startTime, duration: elapsed, regionOwnerID: regionOwnerID)
        return song.tempoAudioSegments(probe).reduce(0) { $0 + $1.duration * $1.audioRate } * sourceBPM / 60
    }
    private mutating func release(_ key: Key, at beat: Double) {
        guard var press = pressed.removeValue(forKey: key) else { return }
        press.note.length = max(1.0 / 960, beat - press.note.start)
        notes.append(press.note)
    }
    public mutating func receive(source: Int32, status: UInt8, number: UInt8, value: UInt8, position: Double) {
        guard position.isFinite, position >= startTime, number < 128, value < 128 else { return }
        let channel = Int(status & 0x0f) + 1, kind = status & 0xf0
        let key = Key(source: source, channel: channel, pitch: Int(number))
        let pedal = Pedal(source: source, channel: channel)
        let time = beat(at: position)
        if kind == 0x90 && value > 0 {
            guard notes.count + pressed.count < 100_000 else { return }
            release(key, at: time)
            pressed[key] = Press(note: MIDINote(start: time, length: 1.0 / 960, pitch: Int(number), velocity: Int(value), channel: channel))
        } else if kind == 0x80 || (kind == 0x90 && value == 0) {
            if sustain.contains(pedal) { pressed[key]?.released = true }
            else { release(key, at: time) }
        } else if kind == 0xb0 {
            if number == 64 {
                if value >= 64 { sustain.insert(pedal) }
                else {
                    sustain.remove(pedal)
                    for key in Array(pressed.keys) where key.source == source && key.channel == channel && pressed[key]?.released == true { release(key, at: time) }
                }
            } else if number == 120 || number == 123 {
                for key in Array(pressed.keys) where key.source == source && key.channel == channel { release(key, at: time) }
                sustain.remove(pedal)
            }
        }
    }
    public mutating func finish(at position: Double) -> AudioClip? {
        let end = max(startTime, position), time = beat(at: end)
        for key in Array(pressed.keys) { release(key, at: time) }
        sustain.removeAll()
        guard end > startTime || !notes.isEmpty else { return nil }
        notes.sort { $0.start == $1.start ? ($0.channel == $1.channel ? $0.pitch < $1.pitch : $0.channel < $1.channel) : $0.start < $1.start }
        return AudioClip(id: id, name: name, startTime: startTime, duration: max(0.01, end - startTime),
            recordingLane: lane, midi: MIDIItem(notes: notes, sourceBPM: sourceBPM), regionOwnerID: regionOwnerID)
    }
}

/// Standard MIDI File, format 0. Export only the visible trim/repetitions,
/// starting at zero, without discarding notes because the item is muted.
public enum MIDIItemExport {
    public static func data(for clip: AudioClip) throws -> Data {
        guard let midi = clip.midi else { throw ProjectError.invalid("Expected a MIDI item") }
        try midi.validate()
        let ticksPerSecond = 960 * midi.sourceBPM / 60
        struct Event { let tick: Int; let priority: Int; let bytes: [UInt8] }
        var events: [Event] = []
        let tempo = Int((60_000_000 / midi.sourceBPM).rounded())
        events.append(Event(tick: 0, priority: -2, bytes: [0xff, 0x51, 3, UInt8((tempo >> 16) & 255), UInt8((tempo >> 8) & 255), UInt8(tempo & 255)]))
        func variable(_ value: Int) throws -> [UInt8] {
            guard (0...0x0fffffff).contains(value) else { throw ProjectError.invalid("MIDI item exceeds the supported file length") }
            var remaining = value, bytes = [UInt8(value & 127)]
            while remaining > 127 { remaining >>= 7; bytes.insert(UInt8(remaining & 127) | 128, at: 0) }
            return bytes
        }
        let name = Array(clip.name.utf8)
        events.append(Event(tick: 0, priority: -1, bytes: [0xff, 3] + (try variable(name.count)) + name))
        for note in clip.midiDisplayNotes() {
            let start = max(0, Int(((note.start - clip.startTime) * ticksPerSecond).rounded()))
            let end = max(start + 1, Int(((note.end - clip.startTime) * ticksPerSecond).rounded()))
            let channel = UInt8(note.channel - 1), pitch = UInt8(min(127, max(0, note.pitch + Int((clip.pitchSemitones ?? 0).rounded()))))
            events.append(Event(tick: start, priority: 1, bytes: [0x90 | channel, pitch, UInt8(note.velocity)]))
            events.append(Event(tick: end, priority: 0, bytes: [0x80 | channel, pitch, 0]))
        }
        let end = max(events.map(\.tick).max() ?? 0, Int((clip.duration * ticksPerSecond).rounded()))
        events.append(Event(tick: end, priority: 2, bytes: [0xff, 0x2f, 0]))
        events.sort { $0.tick == $1.tick ? $0.priority < $1.priority : $0.tick < $1.tick }
        var track = Data(), previous = 0
        for event in events { track.append(contentsOf: try variable(event.tick - previous)); track.append(contentsOf: event.bytes); previous = event.tick }
        var result = Data([0x4d,0x54,0x68,0x64,0,0,0,6,0,0,0,1,3,0xc0,0x4d,0x54,0x72,0x6b])
        let count = UInt32(track.count)
        result.append(contentsOf: [UInt8((count >> 24) & 255),UInt8((count >> 16) & 255),UInt8((count >> 8) & 255),UInt8(count & 255)])
        result.append(track); return result
    }
}
