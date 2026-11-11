import Foundation

/// Logical size of the saved document and its unique, locally available media.
/// Metadata only: never decode audio or traverse unrelated sibling projects.
public enum RecentProjectStorage {
    public static func bytes(at document: URL) throws -> Int64 {
        // External iPad projects can belong to a File Provider. Coordinate the
        // document read and retain the granted URLs while inspecting metadata.
        var coordinationError: NSError?
        var result: Result<Int64, Error>?
        NSFileCoordinator().coordinate(readingItemAt: document, options: [], error: &coordinationError) { granted in
            result = Result { try measure(granted) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    private static func measure(_ document: URL) throws -> Int64 {
        let project = try ProjectDocumentCodec.decode(Data(contentsOf: document))
        let root = document.deletingLastPathComponent()
        var files: [String: URL] = [document.resolvingSymlinksInPath().standardizedFileURL.path: document]
        for path in project.mediaPaths {
            try Task.checkCancellation()
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            files[url.resolvingSymlinksInPath().standardizedFileURL.path] = url
        }
        var total: Int64 = 0
        for file in files.values {
            try Task.checkCancellation()
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
            } catch {
                let ns = error as NSError
                // Missing media occupies no local storage. Permission and I/O
                // failures must not be presented as a misleading zero size.
                if ns.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { throw error }
            }
        }
        return total
    }
}

public protocol ProjectPersistence: Sendable {
    func load() async throws -> Project?
    func save(_ project: Project) async throws
}
public actor ProjectStore: ProjectPersistence {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Project? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ProjectDocumentCodec.decode(Data(contentsOf: url))
    }
    public func save(_ project: Project) throws {
        try project.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectDocumentCodec.write(project, to: url)
    }
}
public actor MemoryProjectStore: ProjectPersistence {
    private var project: Project?
    public init(project: Project? = nil) { self.project = project }
    public func load() -> Project? { project }
    public func save(_ project: Project) throws { try project.validate(); self.project = project }
}

/// Saves only to the explicitly opened document, never to an implicit demo file.
public actor DocumentProjectStore: ProjectPersistence {
    private var url: URL?
    private var projectID: UUID?
    private struct DocumentVersion: Equatable {
        let device: UInt64, inode: UInt64, size: UInt64
        let modified: Date
        static func read(_ url: URL) throws -> Self? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return Self(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
        }
    }
    private var savedVersion: DocumentVersion?
    private var savedMediaPaths: Set<String>?
    public init() {}
    public func select(url: URL, id: UUID) {
        self.url = url; projectID = id; savedVersion = nil; savedMediaPaths = nil
    }
    /// The caller has already read this document while opening it. Keep only
    /// its media references so the first Save need not decode it a second time.
    public func select(url: URL, savedProject project: Project) {
        select(url: url, id: project.id)
        savedVersion = try? DocumentVersion.read(url)
        savedMediaPaths = project.mediaPaths
    }
    /// Renaming keeps the media directory and project identity intact.
    public func rename(to destination: URL, id: UUID) throws {
        guard let url, projectID == id, destination.deletingLastPathComponent() == url.deletingLastPathComponent() else {
            throw ProjectError.invalid("The open project changed before saving. The project was not saved.")
        }
        guard destination != url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProjectError.invalid("A project with this name already exists.")
        }
        try FileManager.default.moveItem(at: url, to: destination)
        self.url = destination
        savedVersion = try? DocumentVersion.read(destination)
    }
    public func deselect() { url = nil; projectID = nil; savedVersion = nil; savedMediaPaths = nil }
    public func load() async throws -> Project? {
        guard let url else { return nil }
        return try await ProjectStore(url: url).load()
    }
    public func save(_ project: Project) async throws {
        guard let url else { throw ProjectError.invalid("No project is open for saving.") }
        guard project.id == projectID else { throw ProjectError.invalid("The open project changed before saving. The project was not saved.") }
        let currentVersion = try DocumentVersion.read(url)
        let previousPaths = currentVersion != nil && currentVersion == savedVersion ? savedMediaPaths : nil
        try ProjectBackups.save(project, to: url, previousMediaPaths: previousPaths)
        // The actor serializes saves. Reuse only the media references from our
        // last committed file; a replacement or external edit invalidates them.
        savedVersion = try DocumentVersion.read(url)
        savedMediaPaths = project.mediaPaths
    }
}

/// Each backup contains the same encrypted bytes as the successfully saved document.
public enum ProjectBackups {
    private static func sequence(_ backup: URL, document: URL) -> Int? {
        let prefix = document.deletingPathExtension().lastPathComponent + " - "
        let name = backup.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count >= 3, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(suffix)
    }
    private static func legacyStamp(_ backup: URL, document: URL? = nil) -> Int64? {
        let name = backup.deletingPathExtension().lastPathComponent
        if let document, !name.hasPrefix(document.deletingPathExtension().lastPathComponent + "--") { return nil }
        guard name.count >= 22, name.dropLast(20).hasSuffix("--") else { return nil }
        let suffix = name.suffix(20)
        return suffix.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int64(suffix) : nil
    }
    public static func date(for backup: URL) -> Date {
        if let stamp = legacyStamp(backup) { return Date(timeIntervalSince1970: Double(stamp) / 1_000_000) }
        let values = try? backup.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
    private static func stampedName(for document: URL, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy - HH-mm"
        return document.deletingPathExtension().lastPathComponent + " - " + formatter.string(from: date)
    }
    private static func isDated(_ url: URL, document: URL) -> Bool {
        let prefix = document.deletingPathExtension().lastPathComponent + " - "
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(prefix) else { return false }
        return String(name.dropFirst(prefix.count)).range(of: #"^\d{2}-\d{2}-\d{4} - \d{2}-\d{2}( - \d+)?$"#, options: .regularExpression) != nil
    }
    public static func files(for document: URL) throws -> [URL] {
        let folder = document.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])
            .filter { $0.pathExtension.lowercased() == "bkjl" && (isDated($0, document: document) || sequence($0, document: document) != nil || legacyStamp($0, document: document) != nil) }
            .sorted { date(for: $0) == date(for: $1) ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending : date(for: $0) < date(for: $1) }
    }
    private static func availableBackup(for document: URL, date: Date) -> URL {
        let folder = document.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let base = stampedName(for: document, date: date)
        var result = folder.appendingPathComponent(base + ".bkjl"), index = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = folder.appendingPathComponent(base + " - \(index).bkjl"); index += 1
        }
        return result
    }
    public static func migrateLegacyNames(for document: URL) throws {
        for backup in try files(for: document) where !isDated(backup, document: document) {
            let savedDate = date(for: backup)
            let destination = availableBackup(for: document, date: savedDate)
            try FileManager.default.moveItem(at: backup, to: destination)
            try FileManager.default.setAttributes([.creationDate: savedDate, .modificationDate: savedDate], ofItemAtPath: destination.path)
        }
    }
    public static func save(_ project: Project, to document: URL, previousMediaPaths: Set<String>? = nil) throws {
        try ProjectDirectoryPolicy.validate(document)
        let data = try ProjectDocumentCodec.encode(project)
        let folder = document.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var known = project.mediaPaths
        if let previousMediaPaths {
            known.formUnion(previousMediaPaths)
        } else if FileManager.default.fileExists(atPath: document.path) {
            known.formUnion(try ProjectDocumentCodec.decode(Data(contentsOf: document)).mediaPaths)
        }
        try ProjectMediaCleanup.remember(project: project, document: document, knownPaths: known)
        try migrateLegacyNames(for: document)
        let previous = try files(for: document)
        let backup = availableBackup(for: document, date: Date())
        try ProjectDocumentCodec.writeEncoded(data, to: backup, exclusive: true)
        do { try ProjectDocumentCodec.writeEncoded(data, to: document) }
        catch { try? FileManager.default.removeItem(at: backup); throw error }
        for old in previous.prefix(max(0, previous.count + 1 - 10)) { try FileManager.default.removeItem(at: old) }
    }
    public static func mediaDirectory(for url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        return url.pathExtension.lowercased() == "bkjl" && parent.lastPathComponent.lowercased() == "backups" ? parent.deletingLastPathComponent() : parent
    }
    /// Recovery never overwrites either the original project or its history.
    public static func restore(_ backup: URL) throws -> URL {
        let data = try Data(contentsOf: backup)
        let project = try ProjectDocumentCodec.decode(data)
        let root = mediaDirectory(for: backup)
        let base = backup.deletingPathExtension().lastPathComponent + "-Recovered"
        let fm = FileManager.default
        var folder = root.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: folder.path) {
            folder = root.deletingLastPathComponent().appendingPathComponent(base + "-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        folder = folder.resolvingSymlinksInPath().standardizedFileURL
        do {
            // Independent copies: deleting the original project cannot break a
            // recovered document, and both keep separate future backup histories.
            for path in project.mediaPaths {
                let source = root.appendingPathComponent(path).standardizedFileURL
                let target = folder.appendingPathComponent(path).standardizedFileURL
                guard target.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                    throw ProjectError.invalid("Invalid imported media path.")
                }
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
            let destination = folder.appendingPathComponent(base).appendingPathExtension("jl")
            try ProjectDocumentCodec.writeEncoded(data, to: destination, exclusive: true)
            return destination
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}

public enum ProjectName {
    public static func validated(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = name.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !name.isEmpty, name.count <= 180, !name.hasSuffix("."),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)) == nil,
              !reserved.contains(stem) else { throw ProjectError.invalid("Enter a valid project name.") }
        return name
    }
}

#if canImport(Darwin)
import Darwin

/// A disposable document owns exactly Documents/catlive-temp. The sibling lock
/// survives cleanup and prevents another window/process from clearing live media.
public final class TemporaryProjectSession: @unchecked Sendable {
    public let directory: URL
    private var descriptor: Int32 = -1
    public init(documents: URL) throws {
        let fm = FileManager.default
        directory = documents.appendingPathComponent("catlive-temp", isDirectory: true).standardizedFileURL
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let lock = documents.appendingPathComponent(".catlive-temp.lock")
        descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProjectError.invalid("Could not prepare the temporary project folder.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw ProjectError.invalid("Close the other temporary session before creating a new one.")
        }
        do {
            try verifyDirectory()
            if !fm.fileExists(atPath: directory.path) { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
            try clearContents()
        } catch { unlock(); throw error }
    }
    deinit { unlock() } // An interrupted session is cleaned on the next creation.
    private func unlock() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
    }
    private func verifyDirectory() throws {
        if let type = try? FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType, type != FileAttributeType.typeDirectory {
            throw ProjectError.invalid("The temporary project folder must be a real directory.")
        }
        guard directory.resolvingSymlinksInPath().path == directory.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent("catlive-temp", isDirectory: true).path else {
            throw ProjectError.invalid("The temporary project folder must be a real directory.")
        }
    }
    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.path + "/")
    }
    private func clearContents() throws {
        try verifyDirectory()
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // removeItem removes a child symlink itself, never its destination.
            try FileManager.default.removeItem(at: entry)
        }
    }
    public func discard() throws { guard descriptor >= 0 else { return }; try clearContents(); unlock() }
    /// Commit a self-contained normal project before releasing any scratch media.
    /// A failed/cancelled copy removes only the new folder this method created.
    public func export(_ original: Project, to destination: URL) throws -> Project {
        let fm = FileManager.default, folder = destination.deletingLastPathComponent()
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let scratch = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved != scratch, !resolved.hasPrefix(scratch + "/"),
              !fm.fileExists(atPath: folder.path) else {
            throw ProjectError.invalid("Choose a new folder outside catlive-temp.")
        }
        try ProjectDirectoryPolicy.validate(destination)
        var project = original
        project.name = try ProjectName.validated(destination.deletingPathExtension().lastPathComponent)
        try project.validate()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var paths = project.mediaPaths
            let instruments = directory.appendingPathComponent("Instruments", isDirectory: true)
            if fm.fileExists(atPath: instruments.path) {
                for item in try fm.contentsOfDirectory(at: instruments, includingPropertiesForKeys: nil) {
                    paths.insert("Instruments/" + item.lastPathComponent)
                }
            }
            for path in paths.sorted() {
                try Task.checkCancellation()
                let source = directory.appendingPathComponent(path).standardizedFileURL
                let target = folder.appendingPathComponent(path).standardizedFileURL
                guard source.path.hasPrefix(directory.path + "/"), target.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                      (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw ProjectError.invalid("Invalid project media path.")
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                guard fm.contentsEqual(atPath: source.path, andPath: target.path) else { throw CocoaError(.fileWriteUnknown) }
            }
            try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(project), to: destination, exclusive: true)
            return project
        } catch { try? fm.removeItem(at: folder); throw error }
    }
}
#endif
