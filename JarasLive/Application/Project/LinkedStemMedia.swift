import Foundation

/// A project stores a portable relative reference. Access to the source folder
/// comes from a local folder selection, including its Files bookmark on iPad.
final class LinkedStemMedia: @unchecked Sendable {
    static let shared = LinkedStemMedia()
    private struct Grant: Codable {
        let bookmark: Data
        let subfolder: String
    }
    private let defaults: UserDefaults
    private let key = "CatLive.linkedStemFolders.v1"
    private let lock = NSLock()
    private var grants: [String: Grant]
    private var idsByFolder: [String: String] = [:]
    private var foldersByID: [String: URL] = [:]
    private var scopes: [String: URL] = [:]
    private var sourceFiles = Set<String>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grants = defaults.data(forKey: key).flatMap { try? PropertyListDecoder().decode([String: Grant].self, from: $0) } ?? [:]
    }
    deinit { for url in scopes.values { url.stopAccessingSecurityScopedResource() } }

    static func isReference(_ path: String) -> Bool {
        path.hasPrefix("Stems/LinkedMedia/") || path.hasPrefix("Videos/LinkedMedia/")
    }
    private func retainAccess(_ url: URL) {
        if scopes[url.path] == nil, url.startAccessingSecurityScopedResource() { scopes[url.path] = url }
    }
    private func folder(id: String) -> URL? {
        if let url = foldersByID[id] { return url }
        guard let grant = grants[id] else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        retainAccess(root)
        if stale, let data = try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            grants[id] = Grant(bookmark: data, subfolder: grant.subfolder)
            if let encoded = try? PropertyListEncoder().encode(grants) { defaults.set(encoded, forKey: key) }
        }
        let url = grant.subfolder.isEmpty ? root : root.appendingPathComponent(grant.subfolder, isDirectory: true)
        foldersByID[id] = url; idsByFolder[url.path] = id
        return url
    }
    func reference(to file: URL, accessRoot: URL, video: Bool = false) throws -> String {
        let directory = file.deletingLastPathComponent().standardizedFileURL
        let root = accessRoot.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path == root.path || directory.path.hasPrefix(prefix) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let name = file.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\\"), !name.contains(":") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        lock.lock(); defer { lock.unlock() }
        let id: String
        if let existing = idsByFolder[directory.path] { id = existing }
        else {
            id = UUID().uuidString
            let data = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            grants[id] = Grant(bookmark: data, subfolder: directory.path == root.path ? "" : String(directory.path.dropFirst(prefix.count)))
            defaults.set(try PropertyListEncoder().encode(grants), forKey: key)
            foldersByID[id] = directory; idsByFolder[directory.path] = id
            retainAccess(root)
        }
        sourceFiles.insert(file.standardizedFileURL.path)
        return (video ? "Videos/LinkedMedia/" : "Stems/LinkedMedia/") + id + "/" + name
    }
    func resolve(_ path: String, in directory: URL) -> URL {
        let local = directory.appendingPathComponent(path, isDirectory: false)
        guard Self.isReference(path) else { return local }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 4, UUID(uuidString: String(pieces[2])) != nil,
              !pieces[3].isEmpty, pieces[3] != ".", pieces[3] != "..", !pieces[3].contains("\\"), !pieces[3].contains(":"),
              !FileManager.default.fileExists(atPath: local.path) else { return local }
        lock.lock(); defer { lock.unlock() }
        guard let folder = folder(id: String(pieces[2])) else { return local }
        let source = folder.appendingPathComponent(String(pieces[3]), isDirectory: false)
        sourceFiles.insert(source.standardizedFileURL.path)
        return source
    }
    func waveform(inSourceFolderOf file: URL) -> URL? {
        lock.lock(); let linked = sourceFiles.contains(file.standardizedFileURL.path); lock.unlock()
        guard linked else { return nil }
        return file.deletingLastPathComponent().appendingPathComponent("WF", isDirectory: true)
            .appendingPathComponent(file.lastPathComponent + ".waveform", isDirectory: false)
    }
}

extension URL {
    func projectMedia(_ path: String) -> URL {
        LinkedStemMedia.isReference(path) ? LinkedStemMedia.shared.resolve(path, in: self) : appendingPathComponent(path, isDirectory: false)
    }
}
