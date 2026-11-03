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
    private var integration: IntegrationConnection?
    private var disconnectTask: Task<Void, Never>?
    private var previousRemotePosition: Double?
    private var previousRemoteClock: Double = 0
    private var remoteJump: UInt64 = 0
    private var retryAfter: Double = 0
    private var timelineStarts: [String: Double] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func bind(_ show: ShowController) {
        if self.show === show { configure(); return }
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
            guard next.enabled || next.usesIntegration else { return }
            if next.usesIntegration { integration = IntegrationConnection(settings: next, name: show.snapshot.project.name) }
            else { socket = ResolumeOSC(settings: next) }
            active = true; error = ""
            let timer = Timer(timeInterval: 0.035, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        guard active, revision != show.projectRevision else { return }
        revision = show.projectRevision
        // Playback never assigns new columns implicitly: keep the exported deck layout stable.
        map = ResolumeMap.build(project: show.snapshot.project, settings: next, createMissing: false)
        timelineStarts = [:]
        if let lighting = show.snapshot.project.windowsLighting, let data = try? JSONEncoder().encode(lighting),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let starts = raw["starts"] as? [String: [String: Any]] {
            for (id, value) in starts { timelineStarts[id.uppercased()] = value["start"] as? Double ?? 0 }
        }
    }
    private func tick() {
        guard task == nil, let show, active else { return }
        let transport = show.snapshot.transport
        if let integration {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= retryAfter else { return }
            if let previousRemotePosition, transport.position < previousRemotePosition - 0.08 || transport.position > previousRemotePosition + max(0.35, now - previousRemoteClock + 0.25) { remoteJump += 1 }
            previousRemotePosition = transport.position; previousRemoteClock = now
            let cue = map.cue(song: transport.songId, at: transport.position), token = generation, jump = remoteJump
            let closing = disconnectTask
            let position = transport.position + (transport.songId.flatMap { timelineStarts[$0.uuidString] } ?? 0)
            task = Task { [weak self] in
                do {
                    await closing?.value
                    try Task.checkCancellation()
                    try await integration.update(position: position, playing: transport.playing, deck: cue?.deck, column: cue?.column, jump: jump)
                    guard let self, self.generation == token else { return }; self.error = ""; self.task = nil
                } catch {
                    guard let self, self.generation == token else { return }
                    self.error = error.localizedDescription; self.task = nil; self.retryAfter = ProcessInfo.processInfo.systemUptime + 1
                }
            }
            return
        }
        guard let socket else { return }
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
        if let integration {
            let previous = disconnectTask
            disconnectTask = Task { await previous?.value; await integration.disconnect() }
        }
        settings = nil; session = nil
        integration = nil; previousRemotePosition = nil; previousRemoteClock = 0; remoteJump = 0; retryAfter = 0
    }
    func createRemoteComposition(project: Project) async throws -> String {
        guard let integration else { throw NSError(domain: "CatLive Integration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connect CatLive Integration first"]) }
        await disconnectTask?.value
        return try await integration.create(project: project)
    }
    func createRemoteGrandMA2(map: GrandMA2Map) async throws -> String {
        guard let integration else { throw NSError(domain: "CatLive Integration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connect CatLive Integration first"]) }
        await disconnectTask?.value
        return try await integration.createGrandMA2(map: map)
    }
}

struct ResolumeSettingsView: View {
    let show: ShowController
    @State private var settings: ResolumeSettings
    @ObservedObject private var runtime = ResolumeController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceEditorDismiss) private var closeEditor
    @State private var busy = false
    @State private var status = ""
    @State private var confirmCreate = false
    @State private var remotePorts: [IntegrationConnection.Port] = []
    init(show: ShowController) { self.show = show; _settings = State(initialValue: show.snapshot.project.resolume ?? ResolumeSettings()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(verbatim: "Resolume").font(.jarasTitle2.bold()); Spacer(); Button("Close") { (closeEditor ?? { dismiss() })() }.disabled(busy) }
            Divider()
            Toggle("Use CatLive Integration on another computer", isOn: Binding(get: { settings.usesIntegration }, set: { settings.integrationEnabled = $0 }))
            if settings.usesIntegration {
                HStack {
                    Text("Integration IP"); TextField("192.168.1.20", text: Binding(get: { settings.integrationHost ?? "" }, set: { settings.integrationHost = $0 })).frame(width: 170)
                    Button("Connect / refresh MIDI") { refreshRemote() }
                }
                HStack {
                    Toggle("Send MTC to grandMA2", isOn: Binding(get: { settings.integrationMTCEnabled == true }, set: { settings.integrationMTCEnabled = $0 }))
                    Picker("MIDI output", selection: Binding(get: { settings.integrationMIDIOutput ?? "" }, set: { settings.integrationMIDIOutput = $0 })) {
                        Text("Automatic").tag("")
                        ForEach(remotePorts) { Text(verbatim: $0.name).tag($0.id) }
                        if let selected = settings.integrationMIDIOutput, !selected.isEmpty, !remotePorts.contains(where: { $0.id == selected }) { Text(verbatim: selected).tag(selected) }
                    }
                }
            }
            HStack {
                if !settings.usesIntegration { Text("Host"); TextField("127.0.0.1", text: $settings.host).frame(width: 170) }
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
            HStack { Text("The map and connection settings are saved with this CatLive project.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary); Spacer(); Button("Apply") { if saveMap() { (closeEditor ?? { dismiss() })() } }.keyboardShortcut(.defaultAction).disabled(busy) }
        }.padding(24).frame(width: 680, height: settings.usesIntegration ? 660 : 560)
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
            settings.integrationHost = settings.integrationHost?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if settings.usesIntegration {
            guard !show.snapshot.transport.playing else { status = "Stop playback before creating the composition"; return }
            busy = true; status = "Creating composition on CatLive Integration…"
            Task {
                defer { busy = false }
                do { let file = try await runtime.createRemoteComposition(project: show.snapshot.project); status = JarasLocalization.string("Composition saved on the Integration computer:") + " " + file }
                catch { status = error.localizedDescription }
            }
            return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "avc") ?? .data]
        panel.nameFieldStringValue = LightingExportName.fileStem(show.snapshot.project.name) + ".avc"
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
    private func refreshRemote() {
        Task {
            do {
                try settings.validate()
                remotePorts = try await IntegrationConnection(settings: settings, name: show.snapshot.project.name).ports()
                status = "CatLive Integration found. Select the MIDI output and apply."
            } catch { status = error.localizedDescription }
        }
    }
}
import UniformTypeIdentifiers
#endif
