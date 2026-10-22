import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A self-contained CatLive project. The ZIP envelope uses stored entries so
/// already-compressed audio/video is transferred in bounded chunks on iOS too.
public enum PortableProjectPackage {
    public struct Limits: Sendable {
        public var maximumFiles = 100_000
        public var maximumBytes: UInt64 = 1_099_511_627_776
        public var maximumDocumentBytes: UInt64 = 134_217_728
        public var maximumManifestBytes: UInt64 = 16_777_216
        public init() {}
    }
    public struct ExportResult: Sendable {
        public let archive: URL
        public let removedPlugins: [String]
        public let requiredCapabilities: [String]
    }
    public struct ImportResult: Sendable {
        public let documentURL: URL
        public var document: URL { documentURL }
        public let project: Project
        public let removedPlugins: [String]
        public let instrumentFiles: [String: URL]
        public let requiredCapabilities: [String]
    }
    struct FileRecord: Codable, Equatable, Sendable {
        var path: String
        var bytes: UInt64
        var sha256: String
    }
    struct Manifest: Codable, Sendable {
        var format = "catlive-ziplive"
        var version = 1
        var document = "Project.jl"
        var projectID: UUID
        var files: [FileRecord]
        var instruments: [String: String]
        var removedPlugins: [String]
        var requiredCapabilities: [String]
    }
    public static func removedExternalPlugins(in project: Project) -> [String] {
        var result: [String] = []
        func visit(_ fx: NativeFXSettings?, _ location: String) {
            guard let fx else { return }
            result += (fx.externalPlugins ?? []).map { location + " · " + $0.name }
            for instance in fx.instances ?? [] { visit(instance.settings, location) }
        }
        visit(project.masterFX, "Master")
        for song in project.songs { for track in song.tracks {
            visit(track.fx, track.name)
            for clip in track.clips { visit(clip.fx, track.name + " / " + clip.name) }
        }}
        return result
    }
    public static func instrumentIDs(in project: Project) -> Set<String> {
        var ids = Set<String>()
        eachFX(in: project) { fx in
            for key in fx.instrumentKeys { if let id = fx.settings(for: key).instrumentID { ids.insert(id) } }
        }
        return ids
    }
    static func capabilities(in project: Project) -> [String] {
        var result = Set<String>()
        eachFX(in: project) { fx in
            if fx.inserted.contains(NativeFXSettings.stemSeparator) { result.insert("catstem-realtime") }
        }
        return result.sorted()
    }
    private static func eachFX(in project: Project, _ visit: (NativeFXSettings) -> Void) {
        func walk(_ fx: NativeFXSettings?) {
            guard let fx else { return }; visit(fx)
            for instance in fx.instances ?? [] { walk(instance.settings) }
        }
        walk(project.masterFX)
        for song in project.songs { for track in song.tracks {
            walk(track.fx); for clip in track.clips { walk(clip.fx) }
        }}
    }
    static func portableCopy(_ original: Project) -> Project {
        var project = original
        func clean(_ fx: NativeFXSettings?) -> NativeFXSettings? {
            guard var fx else { return nil }
            fx.inserted.removeAll { $0.hasPrefix("External:") }; fx.externalPlugins = nil
            if let instances = fx.instances { fx.instances = instances.map { value in
                var value = value; value.settings = clean(value.settings)!; return value
            }}
            return fx
        }
        func automation(_ value: TrackAutomation?) -> TrackAutomation? {
            guard var value else { return nil }
            value.envelopes.removeAll { $0.target.kind == .externalFX }; return value
        }
        project.masterFX = clean(project.masterFX); project.masterAutomation = automation(project.masterAutomation)
        for s in project.songs.indices { for t in project.songs[s].tracks.indices {
            project.songs[s].tracks[t].fx = clean(project.songs[s].tracks[t].fx)
            project.songs[s].tracks[t].automation = automation(project.songs[s].tracks[t].automation)
            for c in project.songs[s].tracks[t].clips.indices {
                project.songs[s].tracks[t].clips[c].fx = clean(project.songs[s].tracks[t].clips[c].fx)
                project.songs[s].tracks[t].clips[c].automation = automation(project.songs[s].tracks[t].clips[c].automation)
            }
        }}
        return project
    }
    public static func export(project: Project, directory: URL, to archive: URL,
                              instruments: [String: URL] = [:], limits: Limits = Limits(),
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ExportResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try exportSynchronously(project: project, directory: directory, to: archive, instruments: instruments, limits: limits, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    public static func importPackage(_ archive: URL, into projectsDirectory: URL,
                                     limits: Limits = Limits(), progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ImportResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try importSynchronously(archive, into: projectsDirectory, limits: limits, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func exportSynchronously(project original: Project, directory: URL, to archive: URL,
                                    instruments: [String: URL], limits: Limits,
                                    progress: @Sendable (Double) -> Void) throws -> ExportResult {
        try Task.checkCancellation(); try original.validate()
        guard archive.isFileURL, archive.pathExtension.lowercased() == "ziplive" else { throw invalid("Choose a .ziplive destination.") }
        var project = portableCopy(original)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var sources: [String: URL] = [:], records: [String: FileRecord] = [:], mapping: [String: String] = [:]
        var names = Set<String>(), total: UInt64 = 0
        let media = original.mediaPaths.sorted(), usedInstruments = instrumentIDs(in: project).sorted()
        guard media.count + usedInstruments.count + 2 <= limits.maximumFiles else { throw invalid("Too many files in this project.") }
        func add(_ source: URL, proposed: String) throws -> String {
            try validateRegularFile(source)
            let fingerprint = try fingerprint(source)
            var path = proposed, suffix = 1
            while names.contains(pathKey(path)) {
                if let existing = records[path], existing.sha256 == fingerprint.sha256, existing.bytes == fingerprint.bytes { return path }
                let url = URL(fileURLWithPath: proposed), ext = url.pathExtension
                path = url.deletingLastPathComponent().lastPathComponent + "/" + url.deletingPathExtension().lastPathComponent + String(format: "-%03d", suffix) + (ext.isEmpty ? "" : "." + ext)
                suffix += 1
            }
            guard fingerprint.bytes <= limits.maximumBytes - total else { throw invalid("The project exceeds the package size limit.") }
            try validatePath(path); names.insert(pathKey(path)); total += fingerprint.bytes
            sources[path] = source; records[path] = FileRecord(path: path, bytes: fingerprint.bytes, sha256: fingerprint.sha256)
            return path
        }
        progress(0)
        for (index, path) in media.enumerated() {
            try validatePath(path)
            let source = root.appendingPathComponent(path).standardizedFileURL
            guard source.path.hasPrefix(root.path + "/") else { throw invalid("Invalid project media path.") }
            mapping[path] = try add(source, proposed: (path.hasPrefix("Videos/") ? "Videos/" : "Stems/") + source.lastPathComponent)
            progress(0.25 * Double(index + 1) / Double(max(1, media.count + usedInstruments.count)))
        }
        var instrumentPaths: [String: String] = [:]
        for id in usedInstruments {
            guard !id.contains("/"), !id.contains("\\"), let source = instruments[id] else { throw invalid("A native instrument is missing: " + id) }
            instrumentPaths[id] = try add(source, proposed: "Instruments/" + id + ".sf2")
        }
        func rewrite(_ file: inout AudioFile?) { if let path = file?.path, let target = mapping[path] { file?.path = target } }
        for s in project.songs.indices { for t in project.songs[s].tracks.indices {
            rewrite(&project.songs[s].tracks[t].audioFile); rewrite(&project.songs[s].tracks[t].clickSound)
            for c in project.songs[s].tracks[t].clips.indices { rewrite(&project.songs[s].tracks[t].clips[c].audioFile) }
        }}
        project.remapFXSamples(mapping)
        let document = try ProjectDocumentCodec.encode(project)
        guard document.count <= limits.maximumDocumentBytes else { throw invalid("The project document is too large.") }
        records["Project.jl"] = record("Project.jl", data: document)
        let removed = removedExternalPlugins(in: original), required = capabilities(in: project)
        let manifest = Manifest(projectID: project.id, files: records.values.sorted { $0.path < $1.path }, instruments: instrumentPaths, removedPlugins: removed, requiredCapabilities: required)
        let metadata = try JSONEncoder().encode(manifest)
        guard metadata.count <= limits.maximumManifestBytes else { throw invalid("The package manifest is too large.") }
        guard UInt64(document.count) <= limits.maximumBytes - total,
              UInt64(metadata.count) <= limits.maximumBytes - total - UInt64(document.count) else { throw invalid("The project exceeds the package size limit.") }
        let parent = archive.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent == archive.deletingLastPathComponent().standardizedFileURL else { throw invalid("Choose a destination without symbolic links.") }
        if fm.fileExists(atPath: archive.path) { try validateRegularFile(archive) }
        let temporary = parent.appendingPathComponent(".catlive-export-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let writer = try StoredProjectZIPWriter(url: temporary)
        try writer.add(path: "Project.jl", data: document)
        var copied: UInt64 = 0
        for path in sources.keys.sorted() {
            let expected = records[path]!
            try writer.add(path: path, source: sources[path]!, expected: expected) { bytes in
                progress(0.25 + 0.74 * Double(copied + bytes) / Double(max(1, total)))
            }
            copied += expected.bytes
        }
        try writer.add(path: "manifest.json", data: metadata); try writer.finish(); try Task.checkCancellation()
        guard rename(temporary.path, archive.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        progress(1)
        return ExportResult(archive: archive, removedPlugins: removed, requiredCapabilities: required)
    }
    static func importSynchronously(_ archive: URL, into projectsDirectory: URL, limits: Limits,
                                    progress: @Sendable (Double) -> Void) throws -> ImportResult {
        try Task.checkCancellation()
        guard ["ziplive", "zip"].contains(archive.pathExtension.lowercased()) else { throw invalid("Choose a CatLive .ziplive package.") }
        try validateRegularFile(archive)
        let zip = try StoredProjectZIPReader(url: archive, limits: limits)
        let metadata = try zip.data("manifest.json", maximum: limits.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self, from: metadata)
        guard manifest.format == "catlive-ziplive", manifest.version == 1, manifest.document == "Project.jl",
              manifest.files.count + 1 == zip.entries.count else { throw invalid("Invalid or unsupported CatLive package.") }
        var expected: [String: FileRecord] = [:]
        for record in manifest.files {
            try validatePath(record.path)
            guard expected[record.path] == nil, record.path != "manifest.json", record.sha256.count == 64,
                  record.sha256.allSatisfy(\.isHexDigit), let entry = zip.entries[record.path], entry.size == record.bytes else { throw invalid("Invalid package inventory.") }
            expected[record.path] = record
        }
        guard Set(expected.keys).union(["manifest.json"]) == Set(zip.entries.keys), let documentRecord = expected[manifest.document] else { throw invalid("Incomplete package inventory.") }
        let document = try zip.data(manifest.document, maximum: limits.maximumDocumentBytes)
        guard record(manifest.document, data: document) == documentRecord else { throw invalid("The project document failed its integrity check.") }
        let project = try ProjectDocumentCodec.decode(document)
        guard project.id == manifest.projectID, portableCopy(project) == project,
              capabilities(in: project) == manifest.requiredCapabilities else { throw invalid("The package contains unsupported project data.") }
        let ids = instrumentIDs(in: project)
        guard Set(manifest.instruments.keys) == ids else { throw invalid("Native instrument inventory is incomplete.") }
        for (id, path) in manifest.instruments {
            guard !id.contains("/"), !id.contains("\\"), path == "Instruments/" + id + ".sf2" else { throw invalid("Invalid native instrument path.") }
        }
        let allowed = project.mediaPaths.union(manifest.instruments.values).union([manifest.document])
        guard allowed == Set(expected.keys), project.mediaPaths.allSatisfy({ $0.hasPrefix("Stems/") || $0.hasPrefix("Videos/") }) else { throw invalid("The package contains unreferenced files.") }
        let fm = FileManager.default
        try fm.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let root = projectsDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root == projectsDirectory.standardizedFileURL else { throw invalid("Choose a project directory without symbolic links.") }
        if let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           UInt64(max(0, available)) < zip.totalBytes { throw invalid("There is not enough space to import this project.") }
        let staging = root.appendingPathComponent(".catlive-import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var copied: UInt64 = 0
        for file in expected.values.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.extract(file.path, to: target, expected: file) { bytes in progress(Double(copied + bytes) / Double(max(1, zip.totalBytes))) }
            copied += file.bytes
        }
        // Imported packages become ordinary editable projects. Caches and new
        // backups belong to this extracted copy, never to the source archive.
        for folder in ["Stems/WF", "backups"] {
            try fm.createDirectory(at: staging.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        // Sound banks are data, never executable bundles. Validate their header
        // before exposing them to the sampler or registering the new project.
        for path in manifest.instruments.values {
            let handle = try FileHandle(forReadingFrom: staging.appendingPathComponent(path)); defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            guard header.count == 12, String(data: header.prefix(4), encoding: .ascii) == "RIFF", String(data: header.suffix(4), encoding: .ascii) == "sfbk" else { throw invalid("Invalid native instrument sound bank.") }
        }
        try Task.checkCancellation()
        let base = String(project.name.map { "/\\:\0".contains($0) ? "_" : $0 }.prefix(80))
        let name = base.isEmpty ? "CatLive" : base
        let localDocument = name + ".jl"
        if localDocument != manifest.document {
            try fm.moveItem(at: staging.appendingPathComponent(manifest.document), to: staging.appendingPathComponent(localDocument))
        }
        let destination = try ProjectDirectoryPolicy.moveImportedProject(from: staging, named: name, into: root)
        progress(1)
        return ImportResult(documentURL: destination.appendingPathComponent(localDocument), project: project,
                            removedPlugins: manifest.removedPlugins,
                            instrumentFiles: manifest.instruments.mapValues { destination.appendingPathComponent($0) },
                            requiredCapabilities: manifest.requiredCapabilities)
    }
    static func invalid(_ message: String) -> ProjectError { .invalid(message) }
    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid("Invalid package file path.") }
    }
    static func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func validateRegularFile(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true else { throw invalid("A package source is missing or is a symbolic link.") }
    }
    static func record(_ path: String, data: Data) -> FileRecord { FileRecord(path: path, bytes: UInt64(data.count), sha256: digest(SHA256.hash(data: data))) }
    static func fingerprint(_ file: URL) throws -> FileRecord {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256(), count: UInt64 = 0
        // FileHandle can return autoreleased buffers on Apple platforms. Drain
        // them per chunk rather than at the end of a multi-gigabyte package.
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 262_144), !data.isEmpty else { return false }
            count += UInt64(data.count); hash.update(data: data)
            return true
        }) {}
        return FileRecord(path: "", bytes: count, sha256: digest(hash.finalize()))
    }
    static func digest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    mutating func zipLE<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    func zipUInt(_ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, count <= 8, offset <= self.count - count else { throw PortableProjectPackage.invalid("Truncated ZIP structure.") }
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(self[startIndex + offset + index]) << (8 * index) }
        return value
    }
}
private enum PackageCRC {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        return value
    }
    static func update(_ value: inout UInt32, data: Data) {
        for byte in data { value = table[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
    }
}

/// ZIP32/ZIP64 Store writer. Data descriptors permit a single streaming write;
/// the central directory is emitted only after every source passed its hash.
final class StoredProjectZIPWriter {
    private struct Entry { let path: String; let size: UInt64; let offset: UInt64; let crc: UInt32; let zip64: Bool }
    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private let forceZIP64: Bool
    init(url: URL, forceZIP64: Bool = false) throws {
        self.forceZIP64 = forceZIP64
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }
    private func write(_ data: Data) throws { try handle.write(contentsOf: data); offset += UInt64(data.count) }
    func add(path: String, data: Data) throws {
        let expected = PortableProjectPackage.record(path, data: data)
        var sent = false
        try add(path: path, expected: expected, next: { if sent { return nil }; sent = true; return data }, progress: { _ in })
    }
    func add(path: String, source: URL, expected: PortableProjectPackage.FileRecord, progress: (UInt64) -> Void) throws {
        let source = try FileHandle(forReadingFrom: source); defer { try? source.close() }
        try add(path: path, expected: expected, next: { try source.read(upToCount: 262_144) }, progress: progress)
    }
    private func add(path: String, expected: PortableProjectPackage.FileRecord, next: () throws -> Data?, progress: (UInt64) -> Void) throws {
        try PortableProjectPackage.validatePath(path)
        let name = Data(path.utf8), large = forceZIP64 || expected.bytes >= UInt32.max, begin = offset
        var extra = Data()
        if large { extra.zipLE(UInt16(1)); extra.zipLE(UInt16(16)); extra.zipLE(expected.bytes); extra.zipLE(expected.bytes) }
        var header = Data(); header.zipLE(UInt32(0x04034b50)); header.zipLE(UInt16(large ? 45 : 20)); header.zipLE(UInt16(0x0808)); header.zipLE(UInt16(0))
        header.zipLE(UInt16(0)); header.zipLE(UInt16(0x21)); header.zipLE(UInt32(0)); header.zipLE(large ? UInt32.max : 0); header.zipLE(large ? UInt32.max : 0)
        header.zipLE(UInt16(name.count)); header.zipLE(UInt16(extra.count)); header.append(name); header.append(extra); try write(header)
        var crc = UInt32.max, sha = SHA256(), count: UInt64 = 0
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data = try next(), !data.isEmpty else { return false }
            count += UInt64(data.count)
            guard count <= expected.bytes else { throw PortableProjectPackage.invalid("A project source changed while exporting.") }
            PackageCRC.update(&crc, data: data); sha.update(data: data); try write(data); progress(count)
            return true
        }) {}
        guard count == expected.bytes, PortableProjectPackage.digest(sha.finalize()) == expected.sha256 else { throw PortableProjectPackage.invalid("A project source changed while exporting.") }
        crc ^= UInt32.max
        var descriptor = Data(); descriptor.zipLE(UInt32(0x08074b50)); descriptor.zipLE(crc)
        if large { descriptor.zipLE(count); descriptor.zipLE(count) } else { descriptor.zipLE(UInt32(count)); descriptor.zipLE(UInt32(count)) }
        try write(descriptor); entries.append(Entry(path: path, size: count, offset: begin, crc: crc, zip64: large))
    }
    func finish() throws {
        let start = offset
        for entry in entries {
            let name = Data(entry.path.utf8), largeOffset = forceZIP64 || entry.offset >= UInt32.max
            var zip64 = Data()
            if entry.zip64 { zip64.zipLE(entry.size); zip64.zipLE(entry.size) }
            if largeOffset { zip64.zipLE(entry.offset) }
            var extra = Data()
            if !zip64.isEmpty { extra.zipLE(UInt16(1)); extra.zipLE(UInt16(zip64.count)); extra.append(zip64) }
            var header = Data(); header.zipLE(UInt32(0x02014b50)); header.zipLE(UInt16(0x032d)); header.zipLE(UInt16(45)); header.zipLE(UInt16(0x0808)); header.zipLE(UInt16(0))
            header.zipLE(UInt16(0)); header.zipLE(UInt16(0x21)); header.zipLE(entry.crc)
            header.zipLE(entry.zip64 ? UInt32.max : UInt32(entry.size)); header.zipLE(entry.zip64 ? UInt32.max : UInt32(entry.size))
            header.zipLE(UInt16(name.count)); header.zipLE(UInt16(extra.count)); header.zipLE(UInt16(0)); header.zipLE(UInt16(0)); header.zipLE(UInt16(0)); header.zipLE(UInt32(0o100600) << 16)
            header.zipLE(largeOffset ? UInt32.max : UInt32(entry.offset)); header.append(name); header.append(extra); try write(header)
        }
        let length = offset - start
        let large = forceZIP64 || start >= UInt32.max || length >= UInt32.max || entries.count >= Int(UInt16.max)
        if large {
            let endOffset = offset
            var end = Data(); end.zipLE(UInt32(0x06064b50)); end.zipLE(UInt64(44)); end.zipLE(UInt16(45)); end.zipLE(UInt16(45)); end.zipLE(UInt32(0)); end.zipLE(UInt32(0))
            end.zipLE(UInt64(entries.count)); end.zipLE(UInt64(entries.count)); end.zipLE(length); end.zipLE(start); try write(end)
            var locator = Data(); locator.zipLE(UInt32(0x07064b50)); locator.zipLE(UInt32(0)); locator.zipLE(endOffset); locator.zipLE(UInt32(1)); try write(locator)
        }
        var end = Data(); end.zipLE(UInt32(0x06054b50)); end.zipLE(UInt16(0)); end.zipLE(UInt16(0))
        end.zipLE(large ? UInt16.max : UInt16(entries.count)); end.zipLE(large ? UInt16.max : UInt16(entries.count)); end.zipLE(large ? UInt32.max : UInt32(length)); end.zipLE(large ? UInt32.max : UInt32(start)); end.zipLE(UInt16(0))
        try write(end); try handle.synchronize(); try handle.close()
    }
}

final class StoredProjectZIPReader {
    struct Entry { let name: String; let size: UInt64; let offset: UInt64; let crc: UInt32 }
    private let handle: FileHandle
    private let length: UInt64
    private var directoryStart: UInt64 = 0
    private(set) var entries: [String: Entry] = [:]
    private(set) var totalBytes: UInt64 = 0
    init(url: URL, limits: PortableProjectPackage.Limits) throws {
        handle = try FileHandle(forReadingFrom: url); length = try handle.seekToEnd()
        guard length >= 22 else { throw Self.invalid() }
        let end = try read(at: length - 22, count: 22)
        guard (try end.zipUInt(0, 4)) == 0x06054b50, (try end.zipUInt(4, 2)) == 0, (try end.zipUInt(6, 2)) == 0, (try end.zipUInt(20, 2)) == 0,
              (try end.zipUInt(8, 2)) == (try end.zipUInt(10, 2)) else { throw Self.invalid() }
        var count = (try end.zipUInt(10, 2)), size = (try end.zipUInt(12, 4)), start = (try end.zipUInt(16, 4)), boundary = length - 22
        if count == UInt16.max || size == UInt32.max || start == UInt32.max {
            guard length >= 98 else { throw Self.invalid() }
            let locator = try read(at: length - 42, count: 20)
            guard (try locator.zipUInt(0, 4)) == 0x07064b50, (try locator.zipUInt(4, 4)) == 0, (try locator.zipUInt(16, 4)) == 1 else { throw Self.invalid() }
            let position = (try locator.zipUInt(8, 8)), zip64 = try read(at: position, count: 56)
            guard position == length - 98, (try zip64.zipUInt(0, 4)) == 0x06064b50, (try zip64.zipUInt(4, 8)) == 44,
                  (try zip64.zipUInt(16, 4)) == 0, (try zip64.zipUInt(20, 4)) == 0, (try zip64.zipUInt(24, 8)) == (try zip64.zipUInt(32, 8)) else { throw Self.invalid() }
            count = (try zip64.zipUInt(32, 8)); size = (try zip64.zipUInt(40, 8)); start = (try zip64.zipUInt(48, 8)); boundary = position
        }
        guard count > 0, count <= UInt64(max(0, limits.maximumFiles)), size <= 64 * 1024 * 1024, start <= boundary, size == boundary - start else { throw Self.invalid() }
        directoryStart = start
        let central = try read(at: start, count: Int(size)); var index = 0; var names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard (try central.zipUInt(index, 4)) == 0x02014b50, (try central.zipUInt(index + 8, 2)) == 0x0808,
                  (try central.zipUInt(index + 10, 2)) == 0, (try central.zipUInt(index + 34, 2)) == 0 else { throw Self.invalid() }
            let nameSize = Int((try central.zipUInt(index + 28, 2))), extraSize = Int((try central.zipUInt(index + 30, 2))), commentSize = Int((try central.zipUInt(index + 32, 2)))
            let endIndex = index + 46 + nameSize + extraSize + commentSize
            guard endIndex <= central.count, nameSize > 0, let name = String(data: central.subdata(in: index + 46..<index + 46 + nameSize), encoding: .utf8) else { throw Self.invalid() }
            try PortableProjectPackage.validatePath(name)
            guard names.insert(PortableProjectPackage.pathKey(name)).inserted else { throw Self.invalid() }
            let attributes = (try central.zipUInt(index + 38, 4))
            guard attributes >> 16 & 0o170000 == 0o100000 else { throw PortableProjectPackage.invalid("Package links and directories are not allowed.") }
            var compressed = (try central.zipUInt(index + 20, 4)), uncompressed = (try central.zipUInt(index + 24, 4)), local = (try central.zipUInt(index + 42, 4))
            if compressed == UInt32.max || uncompressed == UInt32.max || local == UInt32.max {
                var cursor = index + 46 + nameSize, found = false
                while cursor < index + 46 + nameSize + extraSize {
                    let kind = (try central.zipUInt(cursor, 2)), bytes = Int((try central.zipUInt(cursor + 2, 2))); cursor += 4
                    guard cursor + bytes <= index + 46 + nameSize + extraSize else { throw Self.invalid() }
                    if kind == 1 {
                        guard !found else { throw Self.invalid() }; found = true
                        let values = central.subdata(in: cursor..<cursor + bytes); var field = 0
                        if uncompressed == UInt32.max { uncompressed = (try values.zipUInt(field, 8)); field += 8 }
                        if compressed == UInt32.max { compressed = (try values.zipUInt(field, 8)); field += 8 }
                        if local == UInt32.max { local = (try values.zipUInt(field, 8)) }
                    }
                    cursor += bytes
                }
                guard found else { throw Self.invalid() }
            }
            guard compressed == uncompressed, local < start, uncompressed <= limits.maximumBytes - totalBytes else { throw Self.invalid() }
            totalBytes += uncompressed
            entries[name] = Entry(name: name, size: uncompressed, offset: local, crc: UInt32((try central.zipUInt(index + 16, 4))))
            index = endIndex
        }
        guard index == central.count else { throw Self.invalid() }
        // Reject aliasing/overlap: no two logical files may point at the same
        // local record, or smuggle another file/header inside their payload.
        var previousEnd: UInt64 = 0
        for entry in entries.values.sorted(by: { $0.offset < $1.offset }) {
            guard entry.offset == previousEnd else { throw Self.invalid() }
            let payload = try payload(entry)
            previousEnd = payload.end
        }
        guard previousEnd == directoryStart else { throw Self.invalid() }
    }
    deinit { try? handle.close() }
    private static func invalid() -> ProjectError { PortableProjectPackage.invalid("Invalid, damaged or unsupported CatLive ZIP package.") }
    private func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw Self.invalid() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Self.invalid() }
        return data
    }
    private func payload(_ entry: Entry) throws -> (start: UInt64, end: UInt64) {
        let header = try read(at: entry.offset, count: 30)
        guard (try header.zipUInt(0, 4)) == 0x04034b50, (try header.zipUInt(6, 2)) == 0x0808, (try header.zipUInt(8, 2)) == 0 else { throw Self.invalid() }
        let nameCount = Int((try header.zipUInt(26, 2))), extra = Int((try header.zipUInt(28, 2)))
        let name = try read(at: entry.offset + 30, count: nameCount)
        guard String(data: name, encoding: .utf8) == entry.name else { throw Self.invalid() }
        let start = entry.offset + 30 + UInt64(nameCount + extra)
        guard start <= directoryStart, entry.size <= directoryStart - start else { throw Self.invalid() }
        let large = try header.zipUInt(18, 4) == UInt32.max || header.zipUInt(22, 4) == UInt32.max
        let descriptor = try read(at: start + entry.size, count: large ? 24 : 16)
        guard (try descriptor.zipUInt(0, 4)) == 0x08074b50, (try descriptor.zipUInt(4, 4)) == entry.crc,
              (try descriptor.zipUInt(8, large ? 8 : 4)) == entry.size, (try descriptor.zipUInt(large ? 16 : 12, large ? 8 : 4)) == entry.size else { throw Self.invalid() }
        let end = start + entry.size + UInt64(descriptor.count)
        guard end <= directoryStart else { throw Self.invalid() }; return (start, end)
    }
    func data(_ name: String, maximum: UInt64) throws -> Data {
        guard let entry = entries[name], entry.size <= maximum else { throw Self.invalid() }
        let bytes = try read(at: payload(entry).start, count: Int(entry.size)); var crc = UInt32.max
        PackageCRC.update(&crc, data: bytes)
        guard crc ^ UInt32.max == entry.crc else { throw Self.invalid() }; return bytes
    }
    func extract(_ name: String, to target: URL, expected: PortableProjectPackage.FileRecord, progress: (UInt64) -> Void) throws {
        guard let entry = entries[name] else { throw Self.invalid() }
        let start = try payload(entry).start
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let destination = try FileHandle(forWritingTo: target); defer { try? destination.close() }
        var copied: UInt64 = 0, crc = UInt32.max, sha = SHA256()
        while copied < entry.size {
            try autoreleasepool {
                try Task.checkCancellation()
                let bytes = try read(at: start + copied, count: Int(min(262_144, entry.size - copied)))
                copied += UInt64(bytes.count); PackageCRC.update(&crc, data: bytes); sha.update(data: bytes)
                try destination.write(contentsOf: bytes); progress(copied)
            }
        }
        guard copied == expected.bytes, crc ^ UInt32.max == entry.crc, PortableProjectPackage.digest(sha.finalize()) == expected.sha256 else { throw PortableProjectPackage.invalid("A package file failed its integrity check.") }
    }
}

/// iOS changes the sandbox UUID when replacing an installed app. Persist the
/// Documents-relative location; migrate only paths from an iOS app container.
public enum NativeRecentProjectPath {
    public static func resolve(_ stored: String, documents: URL) -> URL {
        if stored.hasPrefix("External/") { return URL(fileURLWithPath: String(stored.dropFirst("External/".count))) }
        let prefix = "Documents/"
        let relative: String?
        if stored.hasPrefix(prefix) { relative = String(stored.dropFirst(prefix.count)) }
        else if stored.contains("/Containers/Data/Application/"), let range = stored.range(of: "/Documents/") {
            relative = String(stored[range.upperBound...])
        } else { relative = nil }
        guard let relative, !relative.isEmpty,
              !relative.split(separator: "/").contains("..") else { return URL(fileURLWithPath: stored) }
        return documents.appendingPathComponent(relative).standardizedFileURL
    }
    public static func store(_ url: URL, documents: URL) -> String {
        let root = documents.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? "Documents/" + path.dropFirst(root.count) : "External/" + path
    }
}
