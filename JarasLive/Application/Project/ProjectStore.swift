import Foundation
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
    public init() {}
    public func select(url: URL, id: UUID) { self.url = url; projectID = id }
    public func load() async throws -> Project? {
        guard let url else { return nil }
        return try await ProjectStore(url: url).load()
    }
    public func save(_ project: Project) async throws {
        guard let url, project.id == projectID else { return }
        try ProjectBackups.save(project, to: url)
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
    public static func save(_ project: Project, to document: URL) throws {
        let data = try ProjectDocumentCodec.encode(project)
        let folder = document.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        _ = try ProjectDocumentCodec.decode(data)
        let root = mediaDirectory(for: backup)
        let base = backup.deletingPathExtension().lastPathComponent + "-Recovered"
        var destination = root.appendingPathComponent(base).appendingPathExtension("jl")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent(base + "-\(suffix)").appendingPathExtension("jl")
            suffix += 1
        }
        try ProjectDocumentCodec.writeEncoded(data, to: destination, exclusive: true)
        return destination
    }
}
