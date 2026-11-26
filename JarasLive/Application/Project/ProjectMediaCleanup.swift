import Foundation

public enum ProjectMediaCleanup {
    private static func inventoryURL(project: Project, document: URL) -> URL {
        document.deletingLastPathComponent().appendingPathComponent(".catlive-media-\(project.id.uuidString).json")
    }
    private static func rememberedPaths(project: Project, document: URL) throws -> Set<String> {
        let url = inventoryURL(project: project, document: document)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
    }
    /// Records ownership without removing any media, including across restarts.
    public static func remember(project: Project, document: URL, knownPaths: Set<String>) throws {
        let previous = try rememberedPaths(project: project, document: document)
        let paths = previous.union(knownPaths).union(project.mediaPaths)
        guard paths != previous else { return }
        try JSONEncoder().encode(paths).write(to: inventoryURL(project: project, document: document), options: .atomic)
    }
    /// Cleanup is called only after saving the current document successfully.
    /// Remove its old backups first, then unused owned media. Other projects,
    /// their backups and active readers keep their sources.
    public static func removeDeletedFiles(project: Project, document: URL, knownPaths: Set<String>, protectedURLs: Set<URL> = [], progress: @Sendable (Double) -> Void = { _ in }) throws {
        progress(0)
        let fm = FileManager.default
        let root = document.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path) else { progress(1); return }
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        var owned = try rememberedPaths(project: project, document: document).union(knownPaths)
        var protectedPaths = Set(project.mediaPaths.map(key))
        let protected = Set(protectedURLs.map { key($0.standardizedFileURL.resolvingSymlinksInPath().path) })
        let siblings = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for url in siblings where url.pathExtension.lowercased() == "jl" && url.standardizedFileURL != document.standardizedFileURL {
            let other = try ProjectDocumentCodec.decode(Data(contentsOf: url))
            protectedPaths.formUnion(other.mediaPaths.map(key))
        }
        progress(0.1)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        var backups: [URL] = []
        if fm.fileExists(atPath: backupRoot.path) {
            guard backupRoot.standardizedFileURL == backupRoot.resolvingSymlinksInPath() else {
                throw CocoaError(.fileReadNoPermission)
            }
            for url in try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) where url.pathExtension.lowercased() == "bkjl" {
                guard url.standardizedFileURL == url.resolvingSymlinksInPath() else { throw CocoaError(.fileReadNoPermission) }
                // Decode all before deleting anything; an unreadable backup fails closed.
                let backup = try ProjectDocumentCodec.decode(Data(contentsOf: url))
                if backup.id == project.id {
                    backups.append(url)
                    owned.formUnion(backup.mediaPaths)
                } else {
                    protectedPaths.formUnion(backup.mediaPaths.map(key))
                }
            }
        }
        var removable: [(source: URL, mediaRoot: URL)] = []
        var seen = Set<String>()
        for path in owned.sorted() {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let archive = components.count > 2 && components[0] == "backups" && components[1] == "Media"
            guard components.count > 1, (["Stems", "Videos"].contains(String(components[0])) || archive),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !path.contains("\\"),
                  !protectedPaths.contains(key(path)), seen.insert(key(path)).inserted else { continue }
            let source = root.appendingPathComponent(path)
            guard !protected.contains(key(source.standardizedFileURL.resolvingSymlinksInPath().path)),
                  source.standardizedFileURL == source.resolvingSymlinksInPath(), fm.fileExists(atPath: source.path),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            removable.append((source, archive ? backupRoot.appendingPathComponent("Media") : root.appendingPathComponent(String(components[0]))))
        }
        // Keep ownership across a partial failure so a later cleanup can retry.
        try remember(project: project, document: document, knownPaths: owned)
        progress(0.2)
        // No source is deleted until every obsolete backup has been removed.
        // A failure leaves the remaining backups' media intact.
        for (index, url) in backups.enumerated() {
            try fm.removeItem(at: url)
            progress(0.2 + 0.3 * Double(index + 1) / Double(backups.count))
        }
        progress(0.5)
        for (index, item) in removable.enumerated() {
            try fm.removeItem(at: item.source)
            var directory = item.source.deletingLastPathComponent()
            while directory != item.mediaRoot && directory.path.hasPrefix(item.mediaRoot.path + "/") {
                guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { break }
                try fm.removeItem(at: directory); directory.deleteLastPathComponent()
            }
            progress(0.5 + 0.49 * Double(index + 1) / Double(removable.count))
        }
        progress(1)
    }
}
