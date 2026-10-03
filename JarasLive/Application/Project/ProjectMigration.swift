import Foundation
#if os(macOS)

/// Shared destination and media handling for DAW migrations.
public enum ProjectMigration {
    public struct Result: Sendable {
        public var project: Project
        public var media: [Media]
        public var warnings: [String]
    }
    public struct Media: Sendable {
        public let relativePath: String
        public let source: URL?
    }
    private static func invalid(_ detail: String) -> ProjectError { .invalid(detail) }
    /// Creates a separate CatLive document. An absent source is intentional, not a
    /// copy failure: its clip and path are saved and recovered by the normal UI.
    public static func save(_ result: Result, to destination: URL) throws {
        try ProjectDirectoryPolicy.validate(destination)
        guard destination.pathExtension.lowercased() == "jl", !FileManager.default.fileExists(atPath: destination.path) else {
            throw invalid("Choose a new .jl project filename.")
        }
        try result.project.validate()
        let referenced = Set(result.project.songs.flatMap(\.tracks).flatMap(\.clips).compactMap { $0.audioFile?.path })
        guard result.media.allSatisfy({ referenced.contains($0.relativePath) }) else { throw invalid("Invalid imported media path.") }
        let fm = FileManager.default
        var copied: [URL] = []
        do {
            for media in result.media {
                try Task.checkCancellation()
                guard let source = media.source else { continue }
                let target = destination.deletingLastPathComponent().appendingPathComponent(media.relativePath)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target); copied.append(target)
            }
            let data = try ProjectDocumentCodec.encode(result.project)
            try ProjectDocumentCodec.writeEncoded(data, to: destination, exclusive: true)
        } catch {
            for target in copied { try? fm.removeItem(at: target) }
            throw error
        }
    }
}
#endif
