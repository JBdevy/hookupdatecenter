import Foundation
import CryptoKit

/// Each CatLive document owns its media and backup directory exclusively.
public enum ProjectDirectoryPolicy {
    /// New projects keep their human-readable name. A collision creates a
    /// separate sibling; even an existing empty folder is reserved to its owner.
    public static func availableFolder(named name: String, in parent: URL) -> URL {
        let fm = FileManager.default
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let candidate = parent.appendingPathComponent(name + suffix, isDirectory: true)
            // fileExists alone misses dangling links, which must not be reused.
            if !fm.fileExists(atPath: candidate.path),
               (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) == nil { return candidate }
            index += 1
        }
    }
    public static func newProjectDestination(for selection: URL, reuseEmptySelectedFolder: Bool = true) -> URL {
        let document = selection.pathExtension.lowercased() == "jl" ? selection : selection.appendingPathExtension("jl")
        let parent = document.deletingLastPathComponent()
        let name = document.deletingPathExtension().lastPathComponent
        // A user can create the named directory in the save panel itself.
        // Never reuse it if it already holds a project, media, or other files.
        if reuseEmptySelectedFolder, parent.lastPathComponent == name {
            let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true,
               (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true { return document }
            return availableFolder(named: name, in: parent.deletingLastPathComponent()).appendingPathComponent(document.lastPathComponent)
        }
        return availableFolder(named: name, in: parent).appendingPathComponent(document.lastPathComponent)
    }
    /// Recheck immediately before copying audio; a folder that became occupied
    /// after the save panel must not share Stems with the new project.
    public static func prepareNewProjectDirectory(for document: URL) throws {
        let fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        if fm.fileExists(atPath: folder.path) {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try fm.contentsOfDirectory(atPath: folder.path).isEmpty else {
                throw ProjectError.invalid("A project already exists at this location. Choose another name.")
            }
        } else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
    }
    /// Extraction remains atomic and never overwrites a concurrent import.
    public static func moveImportedProject(from staging: URL, named name: String, into parent: URL) throws -> URL {
        let fm = FileManager.default
        while true {
            let destination = availableFolder(named: name, in: parent)
            do { try fm.moveItem(at: staging, to: destination); return destination }
            catch {
                let failure = error as NSError
                guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileWriteFileExistsError else { throw error }
            }
        }
    }
    public static func validate(_ document: URL) throws {
        guard document.pathExtension.lowercased() == "jl" else { return }
        let fm = FileManager.default
        let folder = document.deletingLastPathComponent()
        guard fm.fileExists(atPath: folder.path) else { return }
        let others = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .contains { $0.pathExtension.lowercased() == "jl" && $0.standardizedFileURL != document.standardizedFileURL }
        guard !others else {
            throw ProjectError.invalid("This folder already contains another CatLive project. Choose or create a separate folder so Stems and backups are not shared.")
        }
    }
}
/// Portable application document protection, not a user-password vault.
/// The application key is shared by installations so projects remain transferable.
public enum ProjectDocumentCodec {
    private static let header = Data([0x4a, 0x41, 0x52, 0x41, 0x53, 0x4a, 0x4c, 0x00, 0x01])
    private static let key = SymmetricKey(data: Data([0xce, 0x9a, 0x3a, 0xb3, 0xab, 0x54, 0x63, 0x22, 0x5a, 0x93, 0xd8, 0x65, 0xdd, 0xe0, 0x49, 0xce, 0x38, 0x56, 0xde, 0x29, 0x9a, 0x12, 0x29, 0x44, 0x07, 0x41, 0xf7, 0x37, 0x0f, 0x49, 0x69, 0xfd]))

    public static func encode(_ project: Project) throws -> Data {
        try project.validate()
        let plaintext = try ProjectDocumentJSON.encode(project)
        // CryptoKit generates a fresh random nonce on every save.
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let sealed = box.combined else { throw ProjectError.invalid("Unable to encrypt project") }
        return header + sealed
    }
    public static func decode(_ data: Data) throws -> Project {
        let plaintext: Data
        if data.starts(with: header) {
            do {
                let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(header.count)))
                plaintext = try AES.GCM.open(box, using: key, authenticating: header)
            } catch { throw ProjectError.invalid("Project is damaged or could not be decrypted.") }
        } else if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 {
            // Read existing development documents; all subsequent writes are encrypted.
            plaintext = data
        } else { throw ProjectError.invalid("Invalid or unsupported .jl project.") }
        var project = try JSONDecoder().decode(Project.self, from: plaintext)
        project.promoteLoopSectionMarkers()
        try project.validate()
        return project
    }
    public static func writeEncoded(_ data: Data, to url: URL, exclusive: Bool = false) throws {
        try ProjectDirectoryPolicy.validate(url)
        try data.write(to: url, options: exclusive ? .withoutOverwriting : .atomic)
        // Finder obtains the .jl/.bkjl icon from our registered document type.
        // Do not synchronously enter AppKit (NSWorkspace.setIcon) for every
        // document and backup write while the transport is running.
    }
    public static func write(_ project: Project, to url: URL, exclusive: Bool = false) throws {
        try writeEncoded(encode(project), to: url, exclusive: exclusive)
    }
}

/// Keep schema/string/FX encoding in Foundation, while serializing repeated
/// waveform arrays only once per save. The resulting plaintext is the same JSON
/// schema; encryption, nonce generation and atomic writes stay in the codec.
enum ProjectDocumentJSON {
    static func encode(_ project: Project) throws -> Data {
        var metadata = project
        var clipCount = 0, channelFields = 0, sampleCount = 0
        for song in metadata.songs.indices {
            for track in metadata.songs[song].tracks.indices {
                for clip in metadata.songs[song].tracks[track].clips.indices {
                    let source = project.songs[song].tracks[track].clips[clip]
                    clipCount += 1; sampleCount += source.waveform.count
                    metadata.songs[song].tracks[track].clips[clip].waveform = []
                    if let channels = source.waveformChannels {
                        channelFields += 1; sampleCount += channels.reduce(0) { $0 + $1.count }
                        metadata.songs[song].tracks[track].clips[clip].waveformChannels = []
                    }
                }
            }
        }
        guard sampleCount > 0 else { return try JSONEncoder().encode(project) }
        let encoded = try JSONEncoder().encode(metadata)
        do { return try encoded.withUnsafeBytes { raw in
            var writer = Writer(bytes: raw.bindMemory(to: UInt8.self), project: project)
            writer.output.reserveCapacity(encoded.count + sampleCount * 20)
            try writer.object(.project)
            guard writer.waveformFields == clipCount, writer.channelFields == channelFields else { throw Failure.schema }
            writer.output.append(contentsOf: writer.bytes[writer.copied..<writer.bytes.count])
            return writer.output
        } } catch {
            // A future Codable schema must never silently lose a waveform if
            // its container structure changes. Fall back to the complete encoder.
            return try JSONEncoder().encode(project)
        }
    }
    private enum Failure: Error { case schema }
    private enum Context {
        case project, song(Int), track(Int, Int), clip(Int, Int, Int)
    }
    private struct Key: Hashable { let hash: Int; let count: Int }
    private struct Cached { let values: [Double]; let json: Data }
    private struct Writer {
        let bytes: UnsafeBufferPointer<UInt8>
        let project: Project
        var position = 0, copied = 0, waveformFields = 0, channelFields = 0
        var output = Data()
        var cache: [Key: [Cached]] = [:]
        var cachedBytes = 0, cachedArrays = 0
        static let maximumCachedBytes = 16 * 1_048_576
        static let maximumCachedArrays = 1024
        mutating func expect(_ byte: UInt8) throws {
            guard position < bytes.count, bytes[position] == byte else { throw Failure.schema }
            position += 1
        }
        mutating func object(_ context: Context) throws {
            try expect(123)
            if bytes[position] == 125 { position += 1; return }
            while true {
                let key = try string()
                try expect(58)
                switch (context, key) {
                case (.project, "songs"): try array { .song($0) }
                case (.song(let song), "tracks"): try array { .track(song, $0) }
                case (.track(let song, let track), "clips"): try array { .clip(song, track, $0) }
                case (.clip(let song, let track, let clip), "waveform"):
                    guard project.songs.indices.contains(song), project.songs[song].tracks.indices.contains(track),
                          project.songs[song].tracks[track].clips.indices.contains(clip) else { throw Failure.schema }
                    let values = project.songs[song].tracks[track].clips[clip].waveform
                    output.append(contentsOf: bytes[copied..<position]); try skipValue(); copied = position
                    try append(values); waveformFields += 1
                case (.clip(let song, let track, let clip), "waveformChannels"):
                    guard project.songs.indices.contains(song), project.songs[song].tracks.indices.contains(track),
                          project.songs[song].tracks[track].clips.indices.contains(clip),
                          let channels = project.songs[song].tracks[track].clips[clip].waveformChannels else { throw Failure.schema }
                    output.append(contentsOf: bytes[copied..<position]); try skipValue(); copied = position
                    output.append(91)
                    for (index, values) in channels.enumerated() {
                        if index > 0 { output.append(44) }; try append(values)
                    }
                    output.append(93); channelFields += 1
                default: try skipValue()
                }
                if bytes[position] == 125 { position += 1; return }
                try expect(44)
            }
        }
        mutating func array(_ context: (Int) -> Context) throws {
            try expect(91)
            if bytes[position] == 93 { position += 1; return }
            var index = 0
            while true {
                try object(context(index)); index += 1
                if bytes[position] == 93 { position += 1; return }
                try expect(44)
            }
        }
        mutating func string() throws -> String {
            try expect(34)
            let start = position
            while position < bytes.count {
                if bytes[position] == 34 {
                    let value = String(decoding: bytes[start..<position], as: UTF8.self)
                    position += 1; return value
                }
                if bytes[position] == 92 { position += 1 }
                position += 1
            }
            throw Failure.schema
        }
        mutating func skipValue() throws {
            var depth = 0
            while position < bytes.count {
                let value = bytes[position]
                if value == 34 {
                    position += 1
                    while position < bytes.count {
                        if bytes[position] == 34 { position += 1; break }
                        if bytes[position] == 92 { position += 1 }
                        position += 1
                    }
                    if depth == 0 { return }; continue
                }
                if value == 123 || value == 91 { depth += 1 }
                else if value == 125 || value == 93 {
                    if depth == 0 { return }
                    depth -= 1; position += 1; if depth == 0 { return }; continue
                } else if value == 44 && depth == 0 { return }
                position += 1
            }
        }
        mutating func append(_ values: [Double]) throws {
            var hasher = Hasher(); values.withUnsafeBytes { hasher.combine(bytes: $0) }
            let key = Key(hash: hasher.finalize(), count: values.count)
            if let cached = cache[key]?.first(where: { cached in
                cached.values.withUnsafeBytes { original in
                    values.withUnsafeBytes { candidate in
                        original.isEmpty || memcmp(original.baseAddress!, candidate.baseAddress!, original.count) == 0
                    }
                }
            }) {
                output.append(cached.json); return
            }
            var text = "["; text.reserveCapacity(values.count * 20 + 2)
            for (index, value) in values.enumerated() {
                guard value.isFinite else { throw Failure.schema }
                if index > 0 { text.append(",") }; text.append(String(value))
            }
            text.append("]")
            let data = Data(text.utf8)
            // Cache memory stays bounded even in projects with unique previews.
            // Compare exact bits on a hash collision, including signed zero.
            if cachedArrays < Self.maximumCachedArrays, data.count <= Self.maximumCachedBytes - cachedBytes {
                cache[key, default: []].append(Cached(values: values, json: data))
                cachedArrays += 1; cachedBytes += data.count
            }
            output.append(data)
        }
    }
}
