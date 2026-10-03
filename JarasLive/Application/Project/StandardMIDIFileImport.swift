import Foundation
#if os(macOS)
import AudioToolbox

/// Reads standard MIDI files with the system's SMF decoder. Importing never
/// starts a player or opens an audio device; all event positions are in QN.
enum StandardMIDIFileImport {
    struct TempoPoint { let beat: Double; let bpm: Double }
    struct TrackData { let name: String?; let notes: [MIDINote]; let length: Double }
    struct Document {
        let tracks: [TrackData]
        let tempoPoints: [TempoPoint]
        let hasUnsupportedEvents: Bool
        func seconds(atBeat beat: Double) -> Double {
            var time = 0.0, position = 0.0, bpm = 120.0
            for point in tempoPoints where point.beat <= beat {
                time += (point.beat - position) * 60 / bpm
                position = point.beat; bpm = point.bpm
            }
            return time + (beat - position) * 60 / bpm
        }
    }
    private static func invalid(_ detail: String) -> ProjectError { .invalid("MIDI: " + detail) }
    static func read(_ url: URL) throws -> Document {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024 else { throw invalid("Invalid file size.") }
        return try read(Data(contentsOf: url, options: .mappedIfSafe))
    }
    static func read(_ data: Data) throws -> Document {
        guard data.count >= 14, data.count <= 64 * 1024 * 1024,
              data.prefix(4) == Data("MThd".utf8) else { throw invalid("Invalid standard MIDI file.") }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        func u32(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) } }
        let headerSize = u32(4), format = u16(8), trackCount = u16(10), division = u16(12)
        guard headerSize >= 6, headerSize <= data.count - 8, [0, 1].contains(format),
              trackCount > 0, trackCount <= 1000, division > 0, division & 0x8000 == 0 else {
            throw invalid("Only standard MIDI type 0/1 with quarter-note timing is supported.")
        }
        var offset = 8 + headerSize, found = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw invalid("Truncated MIDI chunk.") }
            let length = u32(offset + 4)
            guard length <= bytes.count - offset - 8 else { throw invalid("Truncated MIDI track.") }
            if Array(bytes[offset..<(offset + 4)]) == Array("MTrk".utf8) { found += 1 }
            offset += 8 + length
        }
        guard found == trackCount else { throw invalid("Incomplete MIDI tracks.") }
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let sequence else { throw invalid("Cannot create MIDI reader.") }
        defer { DisposeMusicSequence(sequence) }
        guard MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr else { throw invalid("Cannot decode MIDI events.") }
        var events = 0, notesCount = 0, unsupported = false
        func visit(_ track: MusicTrack, _ body: (Double, MusicEventType, UnsafeRawPointer, Int) throws -> Void) throws {
            var iterator: MusicEventIterator?
            guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { throw invalid("Cannot read MIDI track.") }
            defer { DisposeMusicEventIterator(iterator) }
            var exists = DarwinBoolean(false)
            MusicEventIteratorHasCurrentEvent(iterator, &exists)
            while exists.boolValue {
                events += 1
                if events % 1024 == 0 { try Task.checkCancellation() }
                guard events <= 2_000_000 else { throw invalid("Too many MIDI events.") }
                var time: MusicTimeStamp = 0, type: MusicEventType = 0, pointer: UnsafeRawPointer?, size: UInt32 = 0
                guard MusicEventIteratorGetEventInfo(iterator, &time, &type, &pointer, &size) == noErr,
                      time.isFinite, time >= 0, let pointer else { throw invalid("Invalid MIDI event.") }
                try body(time, type, pointer, Int(size))
                MusicEventIteratorNextEvent(iterator)
                MusicEventIteratorHasCurrentEvent(iterator, &exists)
            }
        }
        var count: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &count)
        guard count <= 1000 else { throw invalid("Too many MIDI tracks.") }
        var tracks: [TrackData] = []
        for index in 0..<count {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, index, &track) == noErr, let track else { throw invalid("Missing MIDI track.") }
            var name: String?, notes: [MIDINote] = []
            var length: MusicTimeStamp = 0, lengthSize = UInt32(MemoryLayout<MusicTimeStamp>.size)
            MusicTrackGetProperty(track, kSequenceTrackProperty_TrackLength, &length, &lengthSize)
            try visit(track) { time, type, pointer, size in
                if type == kMusicEventType_MIDINoteMessage, size >= MemoryLayout<MIDINoteMessage>.size {
                    let note = pointer.load(as: MIDINoteMessage.self)
                    guard note.duration.isFinite, note.duration > 0, note.channel < 16, note.note < 128, note.velocity > 0, note.velocity < 128 else { throw invalid("Invalid MIDI note.") }
                    notesCount += 1
                    guard notesCount <= 100_000 else { throw invalid("Too many MIDI notes.") }
                    notes.append(MIDINote(start: time, length: Double(note.duration), pitch: Int(note.note), velocity: Int(note.velocity), channel: Int(note.channel) + 1))
                } else if type == kMusicEventType_Meta, size >= 8 {
                    let type = pointer.load(as: UInt8.self), count = Int(pointer.load(fromByteOffset: 4, as: UInt32.self))
                    guard count <= size - 8 else { throw invalid("Invalid MIDI metadata.") }
                    if type == 3 { name = String(data: Data(bytes: pointer.advanced(by: 8), count: count), encoding: .utf8) }
                } else if type == kMusicEventType_MIDIChannelMessage || type == kMusicEventType_MIDIRawData { unsupported = true }
            }
            notes.sort { $0.start == $1.start ? $0.pitch < $1.pitch : $0.start < $1.start }
            tracks.append(TrackData(name: name, notes: notes, length: max(length.isFinite ? length : 0, notes.map(\.end).max() ?? 0)))
        }
        var tempoTrack: MusicTrack?, tempoPoints: [TempoPoint] = []
        if MusicSequenceGetTempoTrack(sequence, &tempoTrack) == noErr, let tempoTrack {
            try visit(tempoTrack) { time, type, pointer, size in
                if type == kMusicEventType_ExtendedTempo, size >= MemoryLayout<ExtendedTempoEvent>.size {
                    let bpm = pointer.load(as: ExtendedTempoEvent.self).bpm
                    guard bpm.isFinite, bpm > 0 else { throw invalid("Invalid MIDI tempo.") }
                    tempoPoints.append(TempoPoint(beat: time, bpm: bpm))
                }
            }
        }
        tempoPoints.sort { $0.beat < $1.beat }
        return Document(tracks: tracks, tempoPoints: tempoPoints, hasUnsupportedEvents: unsupported)
    }
}
#endif
