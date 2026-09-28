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
    public static func files(for document: URL) throws -> [URL] {
        let folder = document.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let prefix = document.deletingPathExtension().lastPathComponent + "--"
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { url in
                guard url.pathExtension.lowercased() == "bkjl" else { return false }
                let name = url.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(prefix) else { return false }
                let stamp = name.dropFirst(prefix.count)
                return stamp.count == 20 && stamp.allSatisfy { $0.isASCII && $0.isNumber }
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public static func save(_ project: Project, to document: URL) throws {
        let data = try ProjectDocumentCodec.encode(project)
        let folder = document.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = try files(for: document)
        let last = previous.last.flatMap { Int64($0.deletingPathExtension().lastPathComponent.suffix(20)) } ?? 0
        let stamp = max(last + 1, Int64(Date().timeIntervalSince1970 * 1_000_000))
        let name = document.deletingPathExtension().lastPathComponent + "--" + String(format: "%020lld", stamp) + ".bkjl"
        let backup = folder.appendingPathComponent(name)
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
