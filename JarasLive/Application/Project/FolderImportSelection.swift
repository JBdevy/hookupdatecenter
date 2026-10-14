import Foundation

/// Maintains the order of checked folders independently of the search filter.
struct FolderImportSelection: Equatable {
    let folders: [URL]
    private(set) var selected: [URL] = []
    init(_ urls: [URL]) {
        var seen = Set<URL>()
        folders = urls.filter { seen.insert($0.standardizedFileURL).inserted }
    }
    var allSelected: Bool { !folders.isEmpty && selected.count == folders.count }
    func position(of url: URL) -> Int? { selected.firstIndex(of: url).map { $0 + 1 } }
    mutating func toggle(_ url: URL) {
        guard folders.contains(url) else { return }
        if let index = selected.firstIndex(of: url) { selected.remove(at: index) }
        else { selected.append(url) }
    }
    mutating func toggleAll() {
        if allSelected { selected.removeAll() }
        else {
            let checked = Set(selected)
            selected.append(contentsOf: folders.filter { !checked.contains($0) })
        }
    }
    func matching(_ query: String) -> [URL] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? folders : folders.filter { $0.lastPathComponent.localizedStandardContains(query) }
    }
}

/// Copies legacy, app-owned projects to a user-owned directory. Never removes
/// the originals or overwrites a project already present at the destination.
enum NativeProjectFolderStorage {
    struct Prepared: Sendable {
        let directory: URL
        let movedDocuments: [URL: URL]
        let documents: [URL]
    }
    static func externalRoot(_ root: URL, container: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let home = container.standardizedFileURL.resolvingSymlinksInPath().path
        guard root.path != home, !root.path.hasPrefix(home + "/") else {
            throw failure("Choose a folder outside the CatLive app folder. Files inside the app are removed when it is deleted.")
        }
        return root
    }
    static func prepare(root: URL, legacy: URL, container: URL) throws -> Prepared {
        let fm = FileManager.default
        let root = try externalRoot(root, container: container)
        let directory = root.lastPathComponent == "CatLive" ? root.appendingPathComponent("Projects", isDirectory: true)
            : root.appendingPathComponent("CatLive/Projects", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var moved: [URL: URL] = [:]
        if fm.fileExists(atPath: legacy.path) {
            for source in try directories(legacy) {
                let projects = try projectFiles(source)
                guard !projects.isEmpty else { continue }
                var target = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                var suffix = 0
                while fm.fileExists(atPath: target.path) {
                    if fm.contentsEqual(atPath: source.path, andPath: target.path) { break }
                    suffix += 1
                    target = directory.appendingPathComponent(source.lastPathComponent + String(format: "-%03d", suffix), isDirectory: true)
                }
                if !fm.fileExists(atPath: target.path) {
                    let staging = directory.appendingPathComponent(".copy-" + UUID().uuidString, isDirectory: true)
                    do {
                        try fm.copyItem(at: source, to: staging)
                        guard fm.contentsEqual(atPath: source.path, andPath: staging.path) else {
                            throw failure("Could not verify the project copy. The original project was preserved.")
                        }
                        try fm.moveItem(at: staging, to: target)
                    } catch {
                        try? fm.removeItem(at: staging)
                        throw error
                    }
                }
                for document in projects { moved[document.standardizedFileURL] = target.appendingPathComponent(document.lastPathComponent) }
            }
        }
        var documents = try directories(directory).flatMap { try projectFiles($0) }
        // A .ziplive import uses the user's exact destination. Discover these
        // ordinary projects again when access is granted after reinstalling.
        documents += try projectFiles(root)
        for folder in try directories(root) where UUID(uuidString: String(folder.lastPathComponent.suffix(36))) != nil {
            documents += try projectFiles(folder)
        }
        documents = Array(Set(documents)).sorted { $0.path < $1.path }
        return Prepared(directory: directory, movedDocuments: moved, documents: documents)
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CatLive.ProjectFolder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func directories(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private static func projectFiles(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                guard $0.pathExtension.lowercased() == "jl" else { return false }
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
    }
}
