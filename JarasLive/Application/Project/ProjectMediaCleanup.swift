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
        let paths = candidates.sorted()
        var reportedPercent = 20
        for (index, path) in paths.enumerated() {
            // Limit UI notifications even when a session owns thousands of files.
            defer {
                let percent = 20 + (index + 1) * 80 / paths.count
                if percent > reportedPercent { reportedPercent = percent; progress(Double(percent) / 100) }
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1, ["Steams", "Stems", "Videos"].contains(String(components[0])),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !path.contains("\\") else { continue }
            let source = root.appendingPathComponent(path)
            guard source.standardizedFileURL == source.resolvingSymlinksInPath(), fm.fileExists(atPath: source.path),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let references = backups.indices.filter { backups[$0].1.mediaPaths.contains(path) }
            if !references.isEmpty {
                let relative = "backups/Media/" + UUID().uuidString + "/" + source.lastPathComponent
                let archived = root.appendingPathComponent(relative)
                try fm.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A hard link keeps recovery audio without another PCM copy where supported.
                do { try fm.linkItem(at: source, to: archived) }
                catch { try fm.copyItem(at: source, to: archived) }
                for index in references {
                    var backup = backups[index].1
                    for song in backup.songs.indices {
                        for track in backup.songs[song].tracks.indices {
                            if backup.songs[song].tracks[track].audioFile?.path == path { backup.songs[song].tracks[track].audioFile?.path = relative }
                            for clip in backup.songs[song].tracks[track].clips.indices where backup.songs[song].tracks[track].clips[clip].audioFile?.path == path {
                                backup.songs[song].tracks[track].clips[clip].audioFile?.path = relative
                            }
                        }
                    }
                    try ProjectDocumentCodec.writeEncoded(ProjectDocumentCodec.encode(backup), to: backups[index].0)
                    backups[index].1 = backup
                }
            }
            try fm.removeItem(at: source)
            var directory = source.deletingLastPathComponent()
            let mediaRoot = root.appendingPathComponent(String(components[0]))
            while directory != mediaRoot && directory.path.hasPrefix(mediaRoot.path + "/") {
                guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { break }
                try fm.removeItem(at: directory); directory.deleteLastPathComponent()
            }
        }
        progress(1)
    }
}
