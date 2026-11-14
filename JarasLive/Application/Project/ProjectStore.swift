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
        try save(project, to: document, previousMediaPaths: previousMediaPaths, files: SaveFiles())
    }
    /// The injectable file operations keep failure-path tests independent of
    /// volume permissions, available space, and whether the volume is APFS.
    struct SaveFiles {
        var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
        var backup: (URL, URL) throws -> Void = { _ = try ProjectSaveFiles.copyBackup(from: $0, to: $1) }
        var commit: (URL, URL) throws -> Void = ProjectSaveFiles.replace
    }
    static func save(_ project: Project, to document: URL, previousMediaPaths: Set<String>? = nil, files operations: SaveFiles) throws {
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

        // Write the encrypted document once. The private name cannot be
        // mistaken for another project by ProjectDirectoryPolicy. Until both
        // staging and the backup succeed, the current .jl remains untouched.
        let temporary = try ProjectSaveFiles.temporary(beside: document)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try operations.write(data, temporary)
        let permissions = FileManager.default.fileExists(atPath: document.path)
            ? try FileManager.default.attributesOfItem(atPath: document.path)[.posixPermissions] : nil
        try FileManager.default.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: temporary.path)
        try operations.backup(temporary, backup)
        do {
            try ProjectDirectoryPolicy.validate(document)
            try operations.commit(temporary, document)
        }
        catch { try? FileManager.default.removeItem(at: backup); throw error }
        for old in previous.prefix(max(0, previous.count + 1 - 10)) { try FileManager.default.removeItem(at: old) }
    }
    public static func mediaDirectory(for url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        return url.pathExtension.lowercased() == "bkjl" && parent.lastPathComponent.lowercased() == "backups" ? parent.deletingLastPathComponent() : parent
    }
    /// Recovery never overwrites either the original project or its history.
    public struct RestoreProgress: Sendable {
        public let completedFiles: Int
        public let totalFiles: Int
        public let fileName: String
        public var fraction: Double { Double(completedFiles) / Double(max(1, totalFiles)) }
    }
    public static func restore(_ backup: URL, progress: @Sendable (RestoreProgress) -> Void = { _ in }) throws -> URL {
        try Task.checkCancellation()
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
            let paths = project.mediaPaths.sorted()
            let total = paths.count + 1
            var completed = 0
            // Independent copies: deleting the original project cannot break a
            // recovered document, and both keep separate future backup histories.
            for path in paths {
                try Task.checkCancellation()
                progress(.init(completedFiles: completed, totalFiles: total, fileName: path))
                let source = root.appendingPathComponent(path).standardizedFileURL
                let target = folder.appendingPathComponent(path).standardizedFileURL
                guard target.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                    throw ProjectError.invalid("Invalid imported media path.")
                }
                if fm.fileExists(atPath: source.path) {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: target)
                }
                completed += 1
                progress(.init(completedFiles: completed, totalFiles: total, fileName: path))
            }
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(base).appendingPathExtension("jl")
            progress(.init(completedFiles: completed, totalFiles: total, fileName: destination.lastPathComponent))
            try ProjectDocumentCodec.writeEncoded(data, to: destination, exclusive: true)
            progress(.init(completedFiles: total, totalFiles: total, fileName: ""))
            return destination
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}

/// Save staging and history publication never overwrite another save's backup.
/// copyfile uses an APFS clone when possible and a normal copy on other volumes.
enum ProjectSaveFiles {
    static func temporary(beside destination: URL) throws -> URL {
        let url = destination.deletingLastPathComponent().appendingPathComponent(".catlive-save-" + UUID().uuidString + ".tmp")
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        guard Darwin.close(descriptor) == 0 else {
            let error = posixError()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        #else
        try Data().write(to: url, options: .withoutOverwriting)
        #endif
        return url
    }
    /// Returns whether the file system actually cloned the data. Keeping a
    /// private intermediate file also cleans up a partial ordinary copy if the
    /// destination disk fills; no incomplete .bkjl enters the history list.
    @discardableResult static func copyBackup(from source: URL, to destination: URL, allowClone: Bool = true) throws -> Bool {
        let temporary = try temporary(beside: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if canImport(Darwin)
        guard let state = copyfile_state_alloc() else { throw posixError() }
        defer { copyfile_state_free(state) }
        // UNLINK only applies to the private file we have exclusively reserved,
        // never to the final backup name. COPYFILE_CLONE includes copy fallback.
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_UNLINK | (allowClone ? COPYFILE_CLONE : 0))
        guard copyfile(source.path, temporary.path, state, flags) == 0 else { throw posixError() }
        var cloned = false
        guard copyfile_state_get(state, UInt32(COPYFILE_STATE_WAS_CLONED), &cloned) == 0 else { throw posixError() }
        try publishBackup(temporary, to: destination)
        return cloned
        #else
        try FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return false
        #endif
    }
    #if canImport(Darwin)
    static func publishBackup(_ source: URL, to destination: URL,
                              exclusiveRename: (URL, URL) throws -> Void = exclusiveRename) throws {
        do { try exclusiveRename(source, destination) }
        catch {
            let error = error as NSError
            guard error.domain == NSPOSIXErrorDomain,
                  [ENOTSUP, ENOSYS, EINVAL].contains(Int32(error.code)) else { throw error }
            // Some external/network volumes cannot do RENAME_EXCL. Foundation's
            // move still refuses an existing destination; both paths are in the
            // same backup directory, so it need not copy across file systems.
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
    private static func exclusiveRename(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
    }
    #endif
    static func replace(_ source: URL, _ destination: URL) throws {
        #if canImport(Darwin)
        guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError() }
        #else
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        #endif
    }
    #if canImport(Darwin)
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    #endif
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
    public struct SaveProgress: Sendable {
        public enum Stage: Sendable { case preparing, copying, writing, complete }
        public let stage: Stage
        public let completedFiles: Int
        public let totalFiles: Int
        public let fileName: String
        public var fraction: Double {
            switch stage {
            case .preparing: return 0
            case .copying: return 0.95 * Double(completedFiles) / Double(max(1, totalFiles))
            case .writing: return 0.95
            case .complete: return 1
            }
        }
        public var sequence: Int {
            switch stage {
            case .preparing: return 0
            case .copying: return completedFiles + 1
            case .writing: return totalFiles + 1
            case .complete: return totalFiles + 2
            }
        }
        public static var preparing: Self { .init(stage: .preparing, completedFiles: 0, totalFiles: 0, fileName: "") }
    }
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
    public func export(_ original: Project, to destination: URL,
                       progress: @Sendable (SaveProgress) -> Void = { _ in }) throws -> Project {
        progress(.preparing)
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
            for (index, path) in paths.sorted().enumerated() {
                try Task.checkCancellation()
                progress(.init(stage: .copying, completedFiles: index, totalFiles: paths.count,
                               fileName: URL(fileURLWithPath: path).lastPathComponent))
                let source = directory.appendingPathComponent(path).standardizedFileURL
                let target = folder.appendingPathComponent(path).standardizedFileURL
                guard source.path.hasPrefix(directory.path + "/"), target.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                      (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw ProjectError.invalid("Invalid project media path.")
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let before = try fm.attributesOfItem(atPath: source.path)
                try fm.copyItem(at: source, to: target)
                // copyItem reports copy/clone failures. Re-reading both complete
                // files here defeats APFS cloning and blocks Play for minutes
                // when a temporary session contains hundreds of large stems.
                // Reject a changed source or incomplete destination before
                // committing the document; keep scratch media until activation.
                let after = try fm.attributesOfItem(atPath: source.path)
                let copied = try fm.attributesOfItem(atPath: target.path)
                guard let size = before[.size] as? NSNumber,
                      size == after[.size] as? NSNumber, size == copied[.size] as? NSNumber,
                      before[.modificationDate] as? Date == after[.modificationDate] as? Date else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            progress(.init(stage: .writing, completedFiles: paths.count, totalFiles: paths.count, fileName: ""))
            try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(project), to: destination, exclusive: true)
            progress(.init(stage: .complete, completedFiles: paths.count, totalFiles: paths.count, fileName: ""))
            return project
        } catch { try? fm.removeItem(at: folder); throw error }
    }
}
#endif
