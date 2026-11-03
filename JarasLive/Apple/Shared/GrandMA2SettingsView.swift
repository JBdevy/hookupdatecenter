#if os(macOS)
import SwiftUI

struct GrandMA2SettingsView: View {
    let show: ShowController
    @State private var settings: GrandMA2Settings
    @State private var connection: ResolumeSettings
    @State private var regions: [GrandMA2Map.Region] = []
    @State private var selected = Set<UUID>()
    @State private var ports: [IntegrationConnection.Port] = []
    @State private var advanced = false
    @State private var busy = false
    @State private var status = ""
    @ObservedObject private var runtime = ResolumeController.shared
    @Environment(\.workspaceEditorDismiss) private var close
    init(show: ShowController) {
        self.show = show
        _settings = State(initialValue: GrandMA2Settings(project: show.snapshot.project))
        var value = show.snapshot.project.resolume ?? ResolumeSettings()
        value.integrationEnabled = true
        _connection = State(initialValue: value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(verbatim: "grandMA2").font(.jarasTitle2.bold()); Spacer(); Button("Close") { close?() }.disabled(busy) }
            Text("Select songs and create the grandMA2 macros on the Integration computer. Timecode: 30 FPS.")
                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Integration IP")
                TextField("192.168.1.20", text: Binding(get: { connection.integrationHost ?? "" }, set: { connection.integrationHost = $0 })).frame(width: 170)
                Button("Connect / refresh MIDI") { refreshPorts() }.disabled(busy)
            }
            HStack {
                Toggle("Send MTC to grandMA2", isOn: Binding(get: { connection.integrationMTCEnabled == true }, set: { connection.integrationMTCEnabled = $0 }))
                Picker("MIDI output", selection: Binding(get: { connection.integrationMIDIOutput ?? "" }, set: { connection.integrationMIDIOutput = $0 })) {
                    Text("Automatic").tag("")
                    ForEach(ports) { Text(verbatim: $0.name).tag($0.id) }
                    if let saved = connection.integrationMIDIOutput, !saved.isEmpty, !ports.contains(where: { $0.id == saved }) { Text(verbatim: saved).tag(saved) }
                }
            }
            DisclosureGroup("Advanced configuration", isExpanded: $advanced) {
                HStack {
                    number("First sequence", value: $settings.sequence)
                    number("Page", value: $settings.page)
                    number("First executor", value: $settings.executor)
                    number("First timecode", value: $settings.timecode)
                    number("MTC Slot", value: $settings.slot)
                }.padding(.top, 8)
            }
            HStack {
                Button("Select all") { selected = Set(regions.map(\.id)) }
                Button("Clear selection") { selected.removeAll() }
                Spacer()
                Text("Cues").frame(width: 40)
                Text("MTC start").frame(width: 110)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(regions) { region in
                        HStack {
                            Toggle(isOn: Binding(get: { selected.contains(region.id) }, set: { if $0 { selected.insert(region.id) } else { selected.remove(region.id) } })) {
                                Text(verbatim: region.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(verbatim: "\(region.cues.count)").frame(width: 40)
                            Text(verbatim: Self.timecode(region.start)).monospacedDigit().frame(width: 110)
                        }.padding(.horizontal, 10).frame(height: 32)
                        Divider()
                    }
                }
            }.frame(maxHeight: .infinity).background(Color.black.opacity(0.25)).cornerRadius(6)
            Text("In grandMA2, import the “Import all” macro from the generated folder and run it once.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty { Text(verbatim: status).font(.jarasCallout).textSelection(.enabled).lineLimit(3) }
            if !runtime.error.isEmpty { Text(LocalizedStringKey(runtime.error)).foregroundStyle(.red).font(.jarasCaption).lineLimit(2) }
            HStack {
                Button("Save map to project") { _ = save() }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Create grandMA2 macros") { create() }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                    .foregroundStyle(Color.black).background(JarasTheme.green).cornerRadius(6)
                    .disabled(busy || selected.isEmpty)
            }
        }.padding(24).frame(width: 720, height: 650)
            .foregroundStyle(JarasTheme.text).background(JarasTheme.background)
            .onAppear { refreshMap() }
    }
    private func number(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.jarasCaption); TextField("1", value: value, formatter: Self.integer).frame(width: 116) }
    }
    private static let integer: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .none; f.usesGroupingSeparator = false; return f }()
    private static func timecode(_ value: Double) -> String {
        let n = Int((value * 30).rounded()); return String(format: "%02d:%02d:%02d:%02d", n / 108000, n / 1800 % 60, n / 30 % 60, n % 30)
    }
    private func refreshMap() {
        do { regions = try GrandMA2Map.build(project: show.snapshot.project, settings: settings).plan.regions; selected = Set(regions.map(\.id)) }
        catch { status = JarasLocalization.string(error.localizedDescription) }
    }
    private func save() -> GrandMA2Map? {
        do {
            connection.integrationHost = connection.integrationHost?.trimmingCharacters(in: .whitespacesAndNewlines)
            try connection.validate()
            let map = try GrandMA2Map.build(project: show.snapshot.project, settings: settings, selected: selected)
            show.setGrandMA2(map, connection: connection)
            guard show.snapshot.project.windowsLighting == map.persisted, show.snapshot.project.resolume == connection else { status = show.message; return nil }
            regions = map.plan.regions
            runtime.bind(show)
            status = JarasLocalization.string("Lighting map saved. Save the CatLive project to keep these changes.")
            return map
        } catch { status = JarasLocalization.string(error.localizedDescription); return nil }
    }
    private func refreshPorts() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try connection.validate()
                ports = try await IntegrationConnection(settings: connection, name: show.snapshot.project.name).ports()
                status = JarasLocalization.string("CatLive Integration found. Select the MIDI output and apply.")
            } catch { status = JarasLocalization.string(error.localizedDescription) }
        }
    }
    private func create() {
        guard !show.snapshot.transport.playing else { status = JarasLocalization.string("Stop playback before creating files"); return }
        guard !busy, let map = save() else { return }
        busy = true; status = JarasLocalization.string("Creating grandMA2 macros on CatLive Integration…")
        Task {
            defer { busy = false }
            do {
                let folder = try await runtime.createRemoteGrandMA2(map: map)
                status = JarasLocalization.string("Macros saved on the Integration computer:") + " " + folder
            } catch { status = JarasLocalization.string(error.localizedDescription) }
        }
    }
}
#endif
