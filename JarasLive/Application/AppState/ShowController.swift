import Foundation
import Combine
@MainActor public final class ShowController: ObservableObject {
    @Published public private(set) var snapshot: ShowSnapshot
    @Published public var message = ""
    @Published public var section = "Repertórios"
    public var current: Song? { snapshot.project.songs.first { $0.id == snapshot.transport.songId } }
    public var next: Song? { snapshot.project.songs.first { $0.id == snapshot.nextSongId } }
    public var isPlaying: Bool { snapshot.transport.playing || snapshot.transport.subPlay.playing }
    public var canExecute: () -> Bool = { true }
    public var onStop: () -> Void = {}
    private let executor: any CommandExecutor, persistence: any ProjectPersistence
    private var timer: Timer?, lastTime = ProcessInfo.processInfo.systemUptime
    private var saveTask: Task<Void, Never>?
    private var finishing = false
    public init(executor: any CommandExecutor, persistence: any ProjectPersistence) throws {
        self.executor = executor; self.persistence = persistence
        try executor.load(Project.demo()); snapshot = try executor.snapshot()
    }
    public func restore() async {
        do { if let project = try await persistence.load() { try executor.load(project); snapshot = try executor.snapshot() } else { try await persistence.save(snapshot.project) } } catch { message = error.localizedDescription }
    }
    public func startClock() {
        guard timer == nil, isPlaying else { return }; lastTime = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    public func tick() {
        let now = ProcessInfo.processInfo.systemUptime; let delta = now - lastTime; lastTime = now
        guard isPlaying else { return }
        executor.advance(delta)
        do { let update = try executor.playbackSnapshot(); snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId; if !isPlaying { timer?.invalidate(); timer = nil; onStop() } } catch { message = error.localizedDescription }
    }
    public func send(_ command: ShowCommand, target: UUID? = nil, value: Double = 0) {
        tick()
        guard [.stop, .stopAll, .subStop].contains(command) || (canExecute() && !finishing) else { return }
        do {
            try executor.execute(command, target: target, value: value)
            lastTime = ProcessInfo.processInfo.systemUptime
            if [.volume,.pan,.mute,.solo].contains(command) { snapshot = try executor.snapshot() }
            else { let update = try executor.playbackSnapshot(); snapshot.transport = update.transport; snapshot.nextSongId = update.nextSongId }
            if isPlaying { startClock() } else { timer?.invalidate(); timer = nil; onStop() }
            if [.volume,.pan,.mute,.solo].contains(command) { scheduleSave() }
        } catch { message = error.localizedDescription }
    }
    public func addTrack(name: String, role: TrackRole) {
        guard canExecute(), !finishing else { return }
        do { try executor.addTrack(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role); snapshot = try executor.snapshot(); scheduleSave() } catch { message = error.localizedDescription }
    }
    public func choose(_ song: Song) { send(isPlaying ? .queue : .select, target: song.id) }
    public func finishCurrentSong(_ value: Bool) { finishing = value; executor.finishCurrentSong(value) }
    public func save() async {
        var project = snapshot.project; project.updatedAt = ISO8601DateFormatter().string(from: Date())
        do { try await persistence.save(project); message = "Projeto salvo." } catch { message = error.localizedDescription }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        let project = snapshot.project, persistence = self.persistence
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation(); try await persistence.save(project) } catch is CancellationError {} catch { self?.message = error.localizedDescription }
        }
    }
    public func importProject(_ data: Data) throws {
        let project = try JSONDecoder().decode(Project.self, from: data); try project.validate()
        try executor.load(project); snapshot = try executor.snapshot(); scheduleSave()
    }
}
