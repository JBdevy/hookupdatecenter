#if os(macOS)
import SwiftUI
import Network
import Combine

/// UDP is asynchronous and isolated from the audio render callbacks.
private final class ResolumeOSC {
    private let connection: NWConnection
    init(settings: ResolumeSettings) {
        connection = NWConnection(host: NWEndpoint.Host(settings.host), port: NWEndpoint.Port(rawValue: UInt16(settings.oscPort))!, using: .udp)
        connection.start(queue: DispatchQueue(label: "CatLive.Resolume.OSC", qos: .userInitiated))
    }
    deinit { connection.cancel() }
    func send(_ address: String, integer: Int32? = nil, absolute: Float? = nil) async throws {
        try Task.checkCancellation()
        var bytes = Data()
        func string(_ value: String) {
            bytes.append(contentsOf: value.utf8); bytes.append(0)
            while bytes.count % 4 != 0 { bytes.append(0) }
        }
        string(address)
        if let absolute { string(",sf"); string("a"); var bits = absolute.bitPattern.bigEndian; withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) } }
        else { string(",i"); var bits = (integer ?? 1).bigEndian; withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    func apply(_ action: ResolumeFollower.Action, previousDeck: Int?) async throws {
        if action.speed == 0 { try await send("/composition/speed", absolute: 0) }
        if let cue = action.cue {
            if previousDeck != cue.deck {
                try await send("/composition/decks/\(cue.deck)/select")
                try await Task.sleep(nanoseconds: 70_000_000)
            }
            let address = "/composition/columns/\(cue.column)/connect"
            try await send(address)
            // Always release a pressed OSC button, even if a project switch cancels the task.
            do { try await Task.sleep(nanoseconds: 45_000_000) }
            catch { Task { try? await self.send(address, integer: 0) }; throw error }
            try await send(address, integer: 0)
        }
        if action.speed == 1 { try await send("/composition/speed", absolute: 1) }
    }
}

@MainActor final class ResolumeController: ObservableObject {
    static let shared = ResolumeController()
    @Published private(set) var error = ""
    @Published private(set) var active = false
    private weak var show: ShowController?
    private var subscription: AnyCancellable?
    private var pending = false
    private var timer: Timer?
    private var settings: ResolumeSettings?
    private var session: UUID?
    private var revision: UInt64?
    private var map = ResolumeMap(assignments: [:], cues: [])
    private var follower = ResolumeFollower()
    private var selectedDeck: Int?
    private var socket: ResolumeOSC?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func bind(_ show: ShowController) {
        if self.show === show { settings = nil; configure(); return }
        stop(); self.show = show
        subscription = show.objectWillChange.sink { [weak self] _ in
            guard let self, !self.pending else { return }
            self.pending = true
            DispatchQueue.main.async { [weak self] in self?.pending = false; self?.configure() }
        }
        configure()
    }
    private func configure() {
        guard let show else { stop(); return }
        let next = show.snapshot.project.resolume ?? ResolumeSettings()
        if settings != next || session != show.projectSessionID {
            stop(); settings = next; session = show.projectSessionID; revision = nil
            guard next.enabled else { return }
            socket = ResolumeOSC(settings: next); active = true; error = ""
            let timer = Timer(timeInterval: 0.035, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        guard active, revision != show.projectRevision else { return }
        revision = show.projectRevision
        // Playback never assigns new columns implicitly: keep the exported deck layout stable.
        map = ResolumeMap.build(project: show.snapshot.project, settings: next, createMissing: false)
    }
    private func tick() {
        guard task == nil, let show, let socket, active else { return }
        let transport = show.snapshot.transport
        let action = follower.update(map: map, song: transport.songId, position: transport.position,
                                     playing: transport.playing, time: ProcessInfo.processInfo.systemUptime)
        guard action.cue != nil || action.speed != nil else { return }
        let token = generation, previous = selectedDeck
        task = Task { [weak self] in
            do {
                try await socket.apply(action, previousDeck: previous)
                guard let self, self.generation == token else { return }
                if let cue = action.cue { self.selectedDeck = cue.deck }
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.stop(); self.error = error.localizedDescription
            }
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        if let socket { Task { try? await socket.send("/composition/speed", absolute: 1) } }
        socket = nil; active = false; follower = ResolumeFollower(); selectedDeck = nil
    }
}

struct ResolumeSettingsView: View {
    let show: ShowController
    @State private var settings: ResolumeSettings
    @ObservedObject private var runtime = ResolumeController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var status = ""
    @State private var confirmCreate = false
    init(show: ShowController) { self.show = show; _settings = State(initialValue: show.snapshot.project.resolume ?? ResolumeSettings()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(verbatim: "Resolume").font(.jarasTitle2.bold()); Spacer(); Button("Close") { dismiss() }.disabled(busy) }
            Divider()
            HStack {
                Text("Host"); TextField("127.0.0.1", text: $settings.host).frame(width: 170)
                Text("OSC"); TextField("7000", value: $settings.oscPort, formatter: Self.portFormatter).frame(width: 70)
                Text("Webserver"); TextField("8080", value: $settings.webPort, formatter: Self.portFormatter).frame(width: 70)
            }
            Toggle("Include markers in the Resolume map", isOn: $settings.includeMarkers)
            Toggle("Follow CatLive transport", isOn: $settings.enabled).tint(JarasTheme.green)
            Text("Enable OSC Input in Resolume Preferences (port 7000). For automatic composition creation, enable the Webserver (port 8080) in Resolume Arena 7.22 or later.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Before creating the composition, save your work in Resolume and open a new empty composition. CatLive creates one deck per song and one column per marker. Place your videos in these columns afterward.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Create / update map") { saveMap() }
                Button("Create Resolume project…") { confirmCreate = true }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            if !status.isEmpty { Text(LocalizedStringKey(status)).font(.jarasCallout).textSelection(.disabled).fixedSize(horizontal: false, vertical: true) }
            if !runtime.error.isEmpty { Text(LocalizedStringKey(runtime.error)).foregroundStyle(.red).font(.jarasCaption) }
            Spacer(minLength: 0)
            Divider()
            HStack { Text("The map and connection settings are saved with this CatLive project.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary); Spacer(); Button("Apply") { if saveMap() { dismiss() } }.keyboardShortcut(.defaultAction).disabled(busy) }
        }.padding(24).frame(width: 680, height: 520)
            .foregroundStyle(JarasTheme.text).background(JarasTheme.background)
            .interactiveDismissDisabled(busy)
            .confirmationDialog("Create a new Resolume composition?", isPresented: $confirmCreate) {
                Button("Create Resolume project…") { create() }
            } message: { Text("Open a new empty composition in Resolume first. Existing compositions containing media will not be replaced.") }
    }
    private static let portFormatter: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .none; f.minimum = 1; f.maximum = 65535; return f }()
    @discardableResult private func saveMap() -> Bool {
        do {
            settings.host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
            try settings.validate()
            let map = ResolumeMap.build(project: show.snapshot.project, settings: settings)
            if settings.includeMarkers { settings.withMarkers = map.assignments } else { settings.regionsOnly = map.assignments }
            show.setResolume(settings)
            guard show.snapshot.project.resolume == settings else { status = show.message; return false }
            status = "Resolume map saved. Save the CatLive project to keep these changes."
            runtime.bind(show); return true
        } catch { status = error.localizedDescription; return false }
    }
    private func create() {
        guard !busy, saveMap() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "avc") ?? .data]
        panel.nameFieldStringValue = show.snapshot.project.name + ".avc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = show.snapshot.project, config = settings
        busy = true; status = "Creating Resolume composition…"; runtime.stop()
        Task {
            defer { busy = false; runtime.bind(show) }
            do {
                try await ResolumeComposition(settings: config).create(project: project, destination: url)
                status = "Resolume composition created. Place your videos in the generated columns."
            } catch { status = error.localizedDescription }
        }
    }
}
import UniformTypeIdentifiers
#endif
