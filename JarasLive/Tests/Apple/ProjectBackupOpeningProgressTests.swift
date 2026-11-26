import Foundation
@testable import JarasApplication

private func require(_ value: Bool, _ message: String = "") { precondition(value, message) }

private final class RestoreLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProjectBackups.RestoreProgress] = []
    func append(_ entry: ProjectBackups.RestoreProgress) { lock.lock(); defer { lock.unlock() }; entries.append(entry) }
    var values: [ProjectBackups.RestoreProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}

let done = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("catlive-backup-progress-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Original"), document = source.appendingPathComponent("Show.jl")
        try fm.createDirectory(at: source.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        var project = Project.empty(name: "Backup progress")
        var track = Track(id: UUID(), name: "Audio", role: .keys)
        track.clips = (1...3).map {
            AudioClip(id: UUID(), name: "Take \($0)", startTime: Double($0), duration: 1,
                      audioFile: AudioFile(path: "Stems/take\($0).wav"))
        }
        project.songs[0].tracks = [track]
        for n in 1...3 { try Data(repeating: UInt8(n), count: 4096).write(to: source.appendingPathComponent("Stems/take\(n).wav")) }
        try ProjectBackups.save(project, to: document)
        let backup = try ProjectBackups.files(for: document)[0]
        let original = try Data(contentsOf: document), backupBytes = try Data(contentsOf: backup)
        let log = RestoreLog()
        let recovered = try ProjectBackups.restore(backup) { log.append($0) }
        let updates = log.values
        require(updates.first?.fraction == 0 && updates.last?.fraction == 1)
        require(zip(updates, updates.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        require(Set(updates.map(\.completedFiles)) == Set(0...4))
        require(try Data(contentsOf: document) == original)
        require(try Data(contentsOf: backup) == backupBytes)
        for n in 1...3 {
            require(try Data(contentsOf: recovered.deletingLastPathComponent().appendingPathComponent("Stems/take\(n).wav")) == Data(repeating: UInt8(n), count: 4096))
        }
        let before = try Set(fm.contentsOfDirectory(atPath: root.path))
        let cancelled = Task.detached {
            try ProjectBackups.restore(backup) { progress in
                if progress.completedFiles == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; fatalError("Cancelled recovery must not commit") }
        catch is CancellationError {}
        require(try Set(fm.contentsOfDirectory(atPath: root.path)) == before,
                     "Cancellation must remove only its incomplete recovered folder")
        require(try Data(contentsOf: document) == original && Data(contentsOf: backup) == backupBytes)
        print("BACKUP_RESTORE_PROGRESS_MEDIA_COPY_CANCELLATION_AND_ORIGINALS_PRESERVED_OK")
        done.signal()
    } catch { print(error); exit(1) }
}
done.wait()
