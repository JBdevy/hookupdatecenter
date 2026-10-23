import SwiftUI
struct SettingsView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var show: ShowController
    let backend: any BackendClient
    @AppStorage("jaras.language") private var language = "en"
    @AppStorage(InterfaceScale.key) private var interfaceScale = 1.0
    #if os(macOS)
    @AppStorage("jaras.startup.sound") private var startupSound = true
    @ObservedObject private var showMode = MacShowMode.shared
    #endif
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @ObservedObject private var recorder = TrackRecording.shared
    private var audioConfigurationLocked: Bool { recorder.recording || recorder.busy || show.isPlaying }
    enum Section: String, CaseIterable { case general = "General", audio = "Audio", midi = "MIDI", actions = "Actions", mappings = "Mappings", plugins = "Plugins", account = "Account"
        var icon: String { switch self { case .general: return "slider.horizontal.3"; case .audio: return "speaker.wave.2"; case .midi: return "pianokeys"; case .actions: return "keyboard"; case .mappings: return "switch.2"; case .plugins: return "puzzlepiece.extension"; case .account: return "person.crop.circle" } }
    }
    private var availableSections: [Section] {
        #if os(iOS)
        [.general, .audio, .midi, .actions]
        #else
        Section.allCases
        #endif
    }
    @ObservedObject private var mappings = ControlMappings.shared
    @State private var localSection: Section
    private var selection: Binding<Section>?
    private var section: Section { selection?.wrappedValue ?? localSection }
    @State private var signingIn = false
    @State private var pendingDevice: AuthorizedDevice?
    init(auth: AuthService, show: ShowController, backend: any BackendClient, initialSection: Section = .general,
         selection: Binding<Section>? = nil) {
        self.auth = auth; self.show = show; self.backend = backend
        self.selection = selection
        _localSection = State(initialValue: initialSection)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(availableSections, id: \.self) { item in
                    Button {
                        if let selection { selection.wrappedValue = item } else { localSection = item }
                    } label: {
                        Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                            .font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(section == item ? JarasTheme.accent.opacity(0.15) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(10).frame(width: 144).background(JarasTheme.panel)
            Divider()
            GeometryReader { viewport in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LocalizedStringKey(section.rawValue)).font(.jarasTitle2.bold())
                    switch section {
                    case .general:
                        Text("Language").font(.jarasHeadline)
                        Picker("Language", selection: $language) { Text("English").tag("en"); Text("Português").tag("pt-BR") }.pickerStyle(.segmented).labelsHidden()
                        #if os(macOS)
                        Text("Interface scale").font(.jarasHeadline)
                        Picker("Interface scale", selection: Binding(get: { InterfaceScale.percent(interfaceScale) }, set: { interfaceScale = Double($0) / 100 })) {
                            ForEach(InterfaceScale.percentages, id: \.self) { percent in Text(verbatim: "\(percent)%").tag(percent) }
                        }.labelsHidden().frame(width: 176)
                        Text("Startup sound").font(.jarasHeadline)
                        Picker("Startup sound", selection: $startupSound) {
                            Text("Disabled").tag(false)
                            Text("Enabled").tag(true)
                        }.labelsHidden().frame(width: 176)
                        Text("Show Mode").font(.jarasHeadline)
                        Picker("Show Mode", selection: Binding(get: { showMode.enabled }, set: { showMode.setEnabled($0) })) {
                            Text("Disabled").tag(false)
                            Text("Enabled").tag(true)
                        }.labelsHidden().frame(width: 176).disabled(showMode.busy || !showMode.loaded)
                        Text("When enabled, the Mac lid can be closed without stopping playback.")
                            .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if showMode.busy { ProgressView().controlSize(.small) }
                        if !showMode.error.isEmpty {
                            Text(verbatim: showMode.error).font(.jarasCaption).foregroundStyle(.red)
                            Button("Retry") { showMode.refresh() }
                        }
                        Color.clear.frame(height: 0).task { showMode.refresh() }
                        #endif
                    case .audio:
                        if audioConfigurationLocked {
                            Label("Stop the transport before changing the audio device.", systemImage: "pause.circle.fill")
                                .font(.jarasCallout.weight(.medium)).foregroundStyle(JarasTheme.yellow)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                        Text("Audio device — Input").font(.jarasHeadline)
                        Picker("Audio device — Input", selection: Binding(get: { audio.inputUID }, set: { if !audioConfigurationLocked { audio.selectInput($0) } })) {
                            Text(verbatim: "None").tag("")
                            if !audio.inputUID.isEmpty && audio.inputDevice == nil { Text("Disconnected").tag(audio.inputUID) }
                            ForEach(audio.inputDevices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().frame(maxWidth: .infinity).disabled(audioConfigurationLocked)
                        Text("Audio device — Output").font(.jarasHeadline)
                        Picker("Output device", selection: Binding(get: { audio.selectedUID.isEmpty ? "none" : audio.selectedUID }, set: { if !audioConfigurationLocked { audio.select($0) } })) {
                            Text(verbatim: "None").tag("none")
                            if !audio.selectedUID.isEmpty && audio.selectedUID != "none" && !audio.devices.contains(where: { $0.id == audio.selectedUID }) {
                                Text("Disconnected").tag(audio.selectedUID)
                            }
                            ForEach(audio.devices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().frame(maxWidth: .infinity).disabled(audioConfigurationLocked)
                        Text("\(audio.channels) output channels").foregroundStyle(JarasTheme.secondary)
                        Text("Sample rate").font(.jarasHeadline)
                        Picker("Sample rate", selection: Binding(get: { audio.sampleRate }, set: { if !audioConfigurationLocked { audio.setSampleRate($0) } })) {
                            ForEach(audio.sampleRateChoices, id: \.self) { rate in Text(String(format: "%.0f Hz", rate)).tag(rate) }
                        }.labelsHidden().disabled(audioConfigurationLocked)
                        Text("Buffer size").font(.jarasHeadline)
                        Picker("Buffer size", selection: Binding(get: { audio.bufferFrames }, set: { if !audioConfigurationLocked { audio.setBuffer($0) } })) {
                            ForEach(audio.bufferChoices, id: \.self) { frames in Text("\(frames) samples").tag(frames) }
                        }.labelsHidden().disabled(audioConfigurationLocked)
                        Text("Smaller buffers reduce latency and use more CPU.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        Button("Refresh devices") { audio.refresh(); audio.refreshSampleRate(); audio.refreshBuffer() }
                        if !audio.error.isEmpty { Text(LocalizedStringKey(audio.error)).foregroundStyle(.red).font(.jarasCaption) }
                        }
                    case .midi:
                        Text("MIDI inputs").font(.jarasHeadline)
                        if audio.midiSources.isEmpty { Text("No MIDI inputs").foregroundStyle(JarasTheme.secondary) }
                        ForEach(0..<3, id: \.self) { slot in
                            Picker("MIDI \(slot + 1)", selection: Binding(get: { audio.midiSlots[slot] }, set: { audio.selectMIDI($0, slot: slot) })) {
                                Text("None").tag(Int32(0))
                                if audio.midiSlots[slot] != 0 && !audio.midiDevices.contains(where: { $0.id == audio.midiSlots[slot] }) {
                                    Text(audio.midiSlotTitle(slot)).tag(audio.midiSlots[slot])
                                }
                                ForEach(audio.midiDevices.filter { device in !audio.midiSlots.enumerated().contains { $0.offset != slot && $0.element == device.id } }) { device in Text(device.name).tag(device.id) }
                            }.padding(10).background(JarasTheme.panel).cornerRadius(6)
                        }
                        #if os(macOS)
                        Text("MIDI output").font(.jarasHeadline)
                        Picker("MIDI output", selection: Binding(get: { audio.midiOutput }, set: { audio.selectMIDIOutput($0) })) {
                            Text("None").tag(Int32(0))
                            if audio.midiOutput != 0 && !audio.midiOutputs.contains(where: { $0.id == audio.midiOutput }) {
                                Text(audio.midiOutputTitle).tag(audio.midiOutput)
                            }
                            ForEach(audio.midiOutputs) { device in Text(device.name).tag(device.id) }
                        }.padding(10).background(JarasTheme.panel).cornerRadius(6)
                        if audio.midiOutputs.isEmpty { Text("No MIDI outputs").foregroundStyle(JarasTheme.secondary) }
                        #endif
                        Button("Refresh devices") { audio.refreshMIDI() }
                    case .actions:
                        DAWActionsList(show: show)
                    case .mappings:
                        ControlMappingsList()
                    case .plugins:
                        #if os(macOS)
                        PluginSettings()
                        #else
                        Text("VST3 plugins are available on desktop.").foregroundStyle(JarasTheme.secondary)
                        #endif
                    case .account:
                        Text(auth.licenseTitle ?? "Entre na sua conta").font(.jarasHeadline)
                        if let result = auth.loginResult, result.entitlement.planId != "trial" {
                            Text(result.account.email).foregroundStyle(JarasTheme.secondary)
                        }
                        Button("Login / Trocar conta") { signingIn = true }.buttonStyle(StageButtonStyle()).disabled(auth.busy || show.isPlaying)
                        Text("\(auth.devices.filter { $0.status == .active }.count) / \(auth.loginResult?.entitlement.maxDevices ?? 4) dispositivos").font(.jarasCaption)
                        ForEach(auth.devices.filter { $0.status == .active }) { device in
                            DeviceAccountRow(device: device, current: device.id == auth.installation.id) { pendingDevice = device }.disabled(auth.busy)
                        }
                        Button("Atualizar dispositivos") { Task { await auth.refreshDevices() } }.disabled(auth.busy)
                        Button("Sair e liberar dispositivo") { Task { await auth.logout() } }.buttonStyle(StageButtonStyle(color: .red)).disabled(show.isPlaying || auth.busy)
                        if !auth.message.isEmpty { Text(LocalizedStringKey(auth.message)).font(.jarasCaption).foregroundStyle(JarasTheme.yellow) }
                    }
                }.padding(24).frame(width: viewport.size.width, alignment: .leading)
            }
            }
        }.foregroundStyle(JarasTheme.text)
        .sheet(isPresented: $signingIn) {
            LoginView(auth: auth, backend: backend, offersTrial: false, onAuthorized: { signingIn = false }).frame(width: 550, height: 620)
        }
        .onDisappear { mappings.editing = nil }
        .task(id: section) { if section == .account { await auth.refreshDevices() } }
        .alert("Remover dispositivo?", isPresented: Binding(get: { pendingDevice != nil }, set: { if !$0 { pendingDevice = nil } }), presenting: pendingDevice) { device in
            Button("Cancelar", role: .cancel) { pendingDevice = nil }
            Button("Remover", role: .destructive) { Task { await auth.removeDevice(device) }; pendingDevice = nil }
        } message: { device in
            Text(device.id == auth.installation.id ? "Você sairá da conta neste computador. O áudio será interrompido e a licença ficará disponível." : "Remover \(device.deviceName) e liberar sua licença para outro computador?")
        }
        .overlay {
            if mappings.editing != nil {
                ZStack { Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { mappings.editing = nil }; ControlMappingEditor() }
            }
        }
    }
}

#if os(macOS)
/// The same persistent pmset switch used by Hook Center. Query first: another
/// application may already have changed this computer-wide setting.
@MainActor final class MacShowMode: ObservableObject {
    static let shared = MacShowMode()
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var error = ""
    typealias Runner = @Sendable (String, [String]) throws -> String
    private let run: Runner
    init(run: @escaping Runner = { try MacShowMode.execute($0, $1) }) { self.run = run }
    nonisolated static func isEnabled(_ output: String) -> Bool {
        output.range(of: #"\b(?:SleepDisabled|disablesleep)\s+1\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    func refresh() { update(nil) }
    func setEnabled(_ value: Bool) { update(value) }
    private func update(_ desired: Bool?) {
        guard !busy else { return }
        busy = true; error = ""
        let run = self.run
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    if let desired {
                        _ = try run("/usr/bin/osascript", ["-e", "do shell script \"/usr/bin/pmset -a disablesleep \(desired ? 1 : 0)\" with administrator privileges"])
                    }
                    let active = Self.isEnabled(try run("/usr/bin/pmset", ["-g"]))
                    if let desired, active != desired {
                        throw NSError(domain: "CatLive.ShowMode", code: 1, userInfo: [NSLocalizedDescriptionKey: JarasLocalization.string("The system did not confirm the Show Mode change.")])
                    }
                    return active
                }.value
                enabled = value; loaded = true
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    nonisolated static func execute(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), failure = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = failure
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: failure.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CatLive.ShowMode", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Unable to change Show Mode." : error])
        }
        return text
    }
}
#endif
