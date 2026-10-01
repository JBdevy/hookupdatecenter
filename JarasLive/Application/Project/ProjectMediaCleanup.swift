import Foundation

public enum ProjectMediaCleanup {
    /// Only files previously owned by this document can become candidates.
    /// Other documents are protected. Backup-only sources are kept with backups,
    /// so closing the editor does not make the ten recovery saves unusable.
    public static func close(project: Project, document: URL, knownPaths: Set<String>, progress: @Sendable (Double) -> Void = { _ in }) throws {
        progress(0)
        let fm = FileManager.default
        let root = document.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        var candidates = knownPaths.subtracting(project.mediaPaths)
        guard !candidates.isEmpty else { progress(1); return }
        let siblings = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for url in siblings where url.pathExtension.lowercased() == "jl" && url.standardizedFileURL != document.standardizedFileURL {
            // An unreadable sibling fails closed: never guess whether its audio is unused.
            let other = try ProjectDocumentCodec.decode(Data(contentsOf: url))
            candidates.subtract(other.mediaPaths)
        }
        progress(0.1)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        var backups: [(URL, Project)] = []
        if fm.fileExists(atPath: backupRoot.path) {
            for url in try fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) where url.pathExtension.lowercased() == "bkjl" {
                backups.append((url, try ProjectDocumentCodec.decode(Data(contentsOf: url))))
            }
        }
        progress(0.2)
        // Index backup references once. Re-encoding every complete backup for
        // every removed stem made a large project take minutes to close.
        var referencedPaths = Set<String>()
        for (_, backup) in backups { referencedPaths.formUnion(backup.mediaPaths) }
        let paths = candidates.sorted()
        var replacements: [String: String] = [:]
        var removable: [(source: URL, mediaRoot: URL)] = []
        var reportedPercent = 20
        func report(_ percent: Int) {
            if percent > reportedPercent { reportedPercent = percent; progress(Double(percent) / 100) }
        }
        for (index, path) in paths.enumerated() {
            defer { report(20 + (index + 1) * 35 / paths.count) }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1, ["Steams", "Stems", "Videos"].contains(String(components[0])),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !path.contains("\\") else { continue }
            let source = root.appendingPathComponent(path)
            guard source.standardizedFileURL == source.resolvingSymlinksInPath(), fm.fileExists(atPath: source.path),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            if referencedPaths.contains(path) {
                let relative = "backups/Media/" + UUID().uuidString + "/" + source.lastPathComponent
                let archived = root.appendingPathComponent(relative)
                try fm.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try fm.linkItem(at: source, to: archived) }
                catch { try fm.copyItem(at: source, to: archived) }
                replacements[path] = relative
            }
            removable.append((source, root.appendingPathComponent(String(components[0]))))
        }
        report(55)
        // Commit every replacement before removing any source. If a backup
        // cannot be written, all originals remain available for recovery.
        for (index, entry) in backups.enumerated() {
            defer { report(55 + (index + 1) * 20 / backups.count) }
            let (url, original) = entry
            var backup = original, changed = false
            for song in backup.songs.indices {
                for track in backup.songs[song].tracks.indices {
                    if let path = backup.songs[song].tracks[track].audioFile?.path, let relative = replacements[path] {
                        backup.songs[song].tracks[track].audioFile?.path = relative; changed = true
                    }
                    for clip in backup.songs[song].tracks[track].clips.indices {
                        if let path = backup.songs[song].tracks[track].clips[clip].audioFile?.path, let relative = replacements[path] {
                            backup.songs[song].tracks[track].clips[clip].audioFile?.path = relative; changed = true
                        }
                    }
                }
            }
            if changed {
                let dates = try fm.attributesOfItem(atPath: url.path).filter { $0.key == .creationDate || $0.key == .modificationDate }
                try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(backup), to: url)
                try fm.setAttributes(dates, ofItemAtPath: url.path)
            }
        }
        report(75)
        for (index, item) in removable.enumerated() {
            try fm.removeItem(at: item.source)
            var directory = item.source.deletingLastPathComponent()
            while directory != item.mediaRoot && directory.path.hasPrefix(item.mediaRoot.path + "/") {
                guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { break }
                try fm.removeItem(at: directory); directory.deleteLastPathComponent()
            }
            // Reserve 100% for successful completion of the entire cleanup.
            report(75 + (index + 1) * 24 / removable.count)
        }
        progress(1)
    }
}
