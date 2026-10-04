import SwiftUI
struct SettingsView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var show: ShowController
    let backend: any BackendClient
    @AppStorage("jaras.language") private var language = "en"
    @ObservedObject private var audio = AudioDeviceSettings.shared
    enum Section: String, CaseIterable { case general = "General", audio = "Audio", midi = "MIDI", actions = "Actions", mappings = "Mappings", plugins = "Plugins", account = "Account"
        var icon: String { switch self { case .general: return "slider.horizontal.3"; case .audio: return "speaker.wave.2"; case .midi: return "pianokeys"; case .actions: return "keyboard"; case .mappings: return "switch.2"; case .plugins: return "puzzlepiece.extension"; case .account: return "person.crop.circle" } }
    }
    private var availableSections: [Section] {
        #if os(iOS)
        Section.allCases.filter { $0 != .account && $0 != .plugins }
        #else
        Section.allCases
        #endif
    }
    @ObservedObject private var mappings = ControlMappings.shared
    @State private var section: Section
    @State private var signingIn = false
    @State private var pendingDevice: AuthorizedDevice?
    init(auth: AuthService, show: ShowController, backend: any BackendClient, initialSection: Section = .general) {
        self.auth = auth; self.show = show; self.backend = backend
        _section = State(initialValue: initialSection)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(availableSections, id: \.self) { item in
                    Button { section = item } label: {
                        Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                            .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(section == item ? JarasTheme.accent.opacity(0.15) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(10).frame(width: 144).background(JarasTheme.panel)
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LocalizedStringKey(section.rawValue)).font(.title2.bold())
                    switch section {
                    case .general:
                        Text("Language").font(.headline)
                        Picker("Language", selection: $language) { Text("English").tag("en"); Text("Português").tag("pt-BR") }.pickerStyle(.segmented).labelsHidden()
                    case .audio:
                        Text("Audio device — Input").font(.headline)
                        Picker("Audio device — Input", selection: Binding(get: { audio.inputUID }, set: { audio.selectInput($0) })) {
                            Text(verbatim: "None").tag("")
                            if !audio.inputUID.isEmpty && audio.inputDevice == nil { Text("Disconnected").tag(audio.inputUID) }
                            ForEach(audio.inputDevices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        Text("Audio device — Output").font(.headline)
                        Picker("Output device", selection: Binding(get: { audio.selectedUID.isEmpty ? "none" : audio.selectedUID }, set: { audio.select($0) })) {
                            Text(verbatim: "None").tag("none")
                            ForEach(audio.devices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        Text("\(audio.channels) output channels").foregroundStyle(JarasTheme.secondary)
                        Text("Sample rate").font(.headline)
                        Picker("Sample rate", selection: Binding(get: { audio.sampleRate }, set: { audio.setSampleRate($0) })) {
                            ForEach(audio.sampleRateChoices, id: \.self) { rate in Text(String(format: "%.0f Hz", rate)).tag(rate) }
                        }.labelsHidden()
                        Text("Buffer size").font(.headline)
                        Picker("Buffer size", selection: Binding(get: { audio.bufferFrames }, set: { audio.setBuffer($0) })) {
                            ForEach(audio.bufferChoices, id: \.self) { frames in Text("\(frames) samples").tag(frames) }
                        }.labelsHidden()
                        Text("Smaller buffers reduce latency and use more CPU.").font(.caption).foregroundStyle(JarasTheme.secondary)
                        Button("Refresh devices") { audio.refresh(); audio.refreshSampleRate(); audio.refreshBuffer() }
                        if !audio.error.isEmpty { Text(LocalizedStringKey(audio.error)).foregroundStyle(.red).font(.caption) }
                    case .midi:
                        Text("MIDI inputs").font(.headline)
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
                        Text("MIDI output").font(.headline)
                        Picker("MIDI output", selection: Binding(get: { audio.midiOutput }, set: { audio.selectMIDIOutput($0) })) {
                            Text("None").tag(Int32(0))
                            if audio.midiOutput != 0 && !audio.midiOutputs.contains(where: { $0.id == audio.midiOutput }) {
                                Text(audio.midiOutputTitle).tag(audio.midiOutput)
                            }
                            ForEach(audio.midiOutputs) { device in Text(device.name).tag(device.id) }
                        }.padding(10).background(JarasTheme.panel).cornerRadius(6)
                        if audio.midiOutputs.isEmpty { Text("No MIDI outputs").foregroundStyle(JarasTheme.secondary) }
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
                        Text(auth.licenseTitle ?? "Entre na sua conta").font(.headline)
                        if let result = auth.loginResult, result.entitlement.planId != "trial" {
                            Text(result.account.email).foregroundStyle(JarasTheme.secondary)
                        }
                        Button("Login / Trocar conta") { signingIn = true }.buttonStyle(StageButtonStyle()).disabled(auth.busy || show.isPlaying)
                        Text("\(auth.devices.filter { $0.status == .active }.count) / \(auth.loginResult?.entitlement.maxDevices ?? 4) dispositivos").font(.caption)
                        ForEach(auth.devices.filter { $0.status == .active }) { device in
                            DeviceAccountRow(device: device, current: device.id == auth.installation.id) { pendingDevice = device }.disabled(auth.busy)
                        }
                        Button("Atualizar dispositivos") { Task { await auth.refreshDevices() } }.disabled(auth.busy)
                        Button("Validar agora") { Task { await auth.revalidate() } }.buttonStyle(StageButtonStyle()).disabled(auth.busy)
                        Button("Sair e liberar dispositivo") { Task { await auth.logout() } }.buttonStyle(StageButtonStyle(color: .red)).disabled(show.isPlaying || auth.busy)
                        if !auth.message.isEmpty { Text(LocalizedStringKey(auth.message)).font(.caption).foregroundStyle(JarasTheme.yellow) }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.foregroundStyle(JarasTheme.text)
        .sheet(isPresented: $signingIn) {
            LoginView(auth: auth, backend: backend, offersTrial: false, onAuthorized: { signingIn = false }).frame(width: 550, height: 620)
        }
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
