import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deletes an explicit inventory of this document's files, never its container.
/// Shared sources and files whose ownership cannot be established are retained.
public struct ProjectFolderDeletion: Identifiable, Sendable {
    public let id = UUID()
    public let document: URL
    public let directory: URL
    public var target: URL { document }
    public var deletesDirectory: Bool { false }
    private let directoryIdentity: String
    private let documentIdentity: String
    private let files: [URL: String]
    private let availableAt: TimeInterval
    public var remainingSeconds: Int { max(0, Int(ceil(availableAt - ProcessInfo.processInfo.systemUptime))) }

    public init(document: URL) throws {
        let document = document.standardizedFileURL
        guard document.isFileURL, document.pathExtension.lowercased() == "jl" else {
            throw ProjectError.invalid("Choose a CatLive project to delete.")
        }
        self.document = document
        directory = document.deletingLastPathComponent()
        try Self.validateLocation(document)
        directoryIdentity = try Self.identity(directory)
        documentIdentity = try Self.identity(document, contents: true)
        files = try Self.inventory(document)
        availableAt = ProcessInfo.processInfo.systemUptime + 3
    }
    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL == document
    }
    public func validate() throws {
        guard remainingSeconds == 0 else { throw ProjectError.invalid("Wait 3 seconds before deleting the project.") }
        try Self.validateLocation(document)
        guard try Self.identity(directory) == directoryIdentity,
              try Self.identity(document, contents: true) == documentIdentity else {
            throw ProjectError.invalid("The project folder changed. Open the confirmation again.")
        }
    }
    public func remove() throws {
        try validate()
        // Recheck references after the countdown: a newly saved sibling can
        // claim a shared stem. Never expand the list approved in the dialog.
        let current = try Self.inventory(document)
        let fm = FileManager.default
        for (url, identity) in files.sorted(by: { $0.key.path < $1.key.path }) where current[url] == identity {
            guard Self.localFile(url, inside: directory),
                  try Self.identity(url, contents: true) == identity else { continue }
            try fm.removeItem(at: url)
            var parent = url.deletingLastPathComponent()
            while parent != directory && parent.path.hasPrefix(directory.path + "/") {
                // rmdir only removes an empty directory, even if another file
                // appears between the check and the removal.
                guard parent.path.withCString({ rmdir($0) }) == 0 else { break }
                parent.deleteLastPathComponent()
            }
        }
        try fm.removeItem(at: document)
    }
    private static func identity(_ url: URL, contents: Bool = false) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let base = "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? ""):\(a[.creationDate] ?? "")"
        return contents ? base + ":\(a[.modificationDate] ?? ""):\(a[.size] ?? "")" : base
    }
    private static func validateLocation(_ document: URL) throws {
        let folder = document.deletingLastPathComponent()
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL,
              try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              localFile(document, inside: folder) else {
            throw ProjectError.invalid("Choose a CatLive project file, not a symbolic link.")
        }
    }
    private static func localFile(_ url: URL, inside root: URL) -> Bool {
        let standard = url.standardizedFileURL
        return standard.path.hasPrefix(root.path + "/") &&
            standard == standard.resolvingSymlinksInPath().standardizedFileURL &&
            (try? standard.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    private static func inventory(_ document: URL) throws -> [URL: String] {
        let fm = FileManager.default, root = document.deletingLastPathComponent()
        let project = try ProjectDocumentCodec.decode(Data(contentsOf: document))
        var owned = project.mediaPaths, protected = Set<String>(), candidates = Set<URL>()
        var uncertain = false, sharedIdentity = false
        let manifest = root.appendingPathComponent(".catlive-media-\(project.id.uuidString).json")
        if localFile(manifest, inside: root),
           let paths = try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: manifest)) {
            owned.formUnion(paths); candidates.insert(manifest)
        }
        let siblings = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for sibling in siblings where sibling.pathExtension.lowercased() == "jl" && sibling.standardizedFileURL.path != document.path {
            guard localFile(sibling, inside: root),
                  let other = try? ProjectDocumentCodec.decode(Data(contentsOf: sibling)) else { uncertain = true; continue }
            protected.formUnion(other.mediaPaths)
            sharedIdentity = sharedIdentity || other.id == project.id
            let otherManifest = root.appendingPathComponent(".catlive-media-\(other.id.uuidString).json")
            if fm.fileExists(atPath: otherManifest.path) {
                if localFile(otherManifest, inside: root),
                   let paths = try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: otherManifest)) {
                    protected.formUnion(paths)
                } else { uncertain = true }
            }
        }
        let backupRoot = root.appendingPathComponent("backups")
        if backupRoot == backupRoot.resolvingSymlinksInPath().standardizedFileURL,
           fm.fileExists(atPath: backupRoot.path) {
            for backup in try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) where backup.pathExtension.lowercased() == "bkjl" {
                guard localFile(backup, inside: root),
                      let saved = try? ProjectDocumentCodec.decode(Data(contentsOf: backup)) else { uncertain = true; continue }
                if saved.id == project.id && !sharedIdentity {
                    candidates.insert(backup); owned.formUnion(saved.mediaPaths)
                } else { protected.formUnion(saved.mediaPaths) }
            }
        }
        if sharedIdentity || uncertain { candidates.remove(manifest) }
        if !uncertain {
            for path in owned.subtracting(protected) {
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count > 1, !path.contains("\\"),
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      ["Stems", "Videos"].contains(String(components[0])) || path.hasPrefix("backups/Media/") else { continue }
                candidates.insert(root.appendingPathComponent(path))
                if components[0] == "Stems" {
                    candidates.insert(root.appendingPathComponent("Stems/WF/" + components.dropFirst().joined(separator: "/") + ".waveform"))
                }
            }
        }
        var result: [URL: String] = [:]
        for url in candidates where localFile(url, inside: root) { result[url] = try identity(url, contents: true) }
        return result
    }
}
