import SwiftUI

struct AdvancedView: View {
    @ObservedObject var show: ShowController
    @Environment(\.dismiss) private var dismiss
    private enum Tab: String, CaseIterable {
        case timeProject = "TimeProject", record = "Record", reRender = "Re-render", video = "Video", setlist = "Setlist"
        var icon: String { switch self { case .timeProject: return "metronome"; case .record: return "record.circle"; case .reRender: return "waveform"; case .video: return "video"; case .setlist: return "list.bullet" } }
    }
    @State private var tab = Tab.timeProject
    @State private var bpm: String
    @State private var beats: String
    @State private var unit: String
    @State private var settings: ProjectTimeSettings
    @State private var invalidField: Int?
    @State private var shake = 0.0
    @FocusState private var focus: Int?

    init(show: ShowController) {
        self.show = show
        let song = show.current
        _bpm = State(initialValue: String(format: "%g", song?.bpm ?? 120))
        _beats = State(initialValue: String(song?.meterBeats ?? 4))
        _unit = State(initialValue: String(song?.meterUnit ?? 4))
        _settings = State(initialValue: song?.projectTime ?? ProjectTimeSettings())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Advanced").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Close")
            }.padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Label { Text(LocalizedStringKey(item.rawValue)) } icon: { Image(systemName: item.icon) }
                                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).frame(height: 36)
                                .background(tab == item ? JarasTheme.green.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(item.rawValue)
                    }
                    Spacer()
                }.padding(10).frame(width: 136).background(JarasTheme.panel)
                Divider()
                ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LocalizedStringKey(tab.rawValue)).font(.title3.bold())
                    if tab == .timeProject { timingControls }
                    if tab == .video { AdvancedVideoSettings() }
                    if tab == .setlist { AdvancedSetlistColors() }
                    if tab == .record || tab == .reRender { MediaProcessingFormatEditor(scope: tab == .record ? "record" : "rerender").id(tab.rawValue) }
                    Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                if let invalidField {
                    Text(LocalizedStringKey(invalidField == 0 ? "Enter a BPM between 60 and 300." : "Invalid time signature."))
                        .font(.caption).foregroundStyle(.red)
                } else if !show.message.isEmpty { Text(LocalizedStringKey(show.message)).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if tab == .timeProject { Button("Apply", action: apply).keyboardShortcut(.defaultAction) }
            }.padding(14).fixedSize(horizontal: false, vertical: true)
        }.frame(width: 760, height: 420).foregroundStyle(JarasTheme.text).background(JarasTheme.background)
    }
    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Text(verbatim: "BPM:")
                timingField($bpm, index: 0, width: 60, label: "BPM")
                Text("Time signature")
                HStack(spacing: 4) {
                    timingField($beats, index: 1, width: 34, label: "Beats per bar")
                    Text(verbatim: "/")
                    timingField($unit, index: 2, width: 34, label: "Beat unit")
                }
                Text("Gridline")
                Picker("Gridline", selection: Binding(get: { settings.divisions != 0 }, set: { settings.divisions = $0 ? 4 : 0 })) {
                    Text("Enabled").tag(true)
                    Text("Disabled").tag(false)
                }.labelsHidden().frame(width: 108).accessibilityLabel("Gridline")
            }.font(.system(size: 12))
            HStack(spacing: 14) {
                Text("Project timebase")
                Picker("Project timebase", selection: $settings.timebase) {
                    ForEach(ProjectTimebase.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Project timebase")
            }
            Toggle("Timebase affects automation item length", isOn: $settings.affectsAutomationLength)
                .toggleStyle(.automatic)
        }
    }
    private func timingField(_ text: Binding<String>, index: Int, width: CGFloat, label: String) -> some View {
        TextField("", text: text).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            .frame(width: width).focused($focus, equals: index).accessibilityLabel(LocalizedStringKey(label))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalidField == index ? .red : .clear, lineWidth: 1.5))
            .modifier(InputValidationShake(animatableData: invalidField == index ? shake : 0))
            .onSubmit(apply)
    }
    private func reject(_ field: Int) {
        invalidField = field; focus = field
        withAnimation(.linear(duration: 0.35)) { shake += 1 }
    }
    private func apply() {
        guard let tempo = Double(bpm.replacingOccurrences(of: ",", with: ".")), tempo.isFinite else { bpm = String(format: "%g", show.current?.bpm ?? 120); reject(0); return }
        let clamped = min(300, max(60, tempo))
        guard tempo == clamped else { bpm = String(format: "%g", clamped); reject(0); return }
        guard let numerator = Int(beats), (1...32).contains(numerator) else { reject(1); return }
        guard let denominator = Int(unit), TimelineTempo.beatUnits.contains(denominator) else { reject(2); return }
        invalidField = nil
        if show.configureProjectTime(bpm: tempo, beats: numerator, unit: denominator, settings: settings) { dismiss() }
    }
}

struct TempoMarkerEditor: View {
    let marker: TimelineMarker
    let save: (TimelineMarker) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bpm: String
    @State private var beats: String
    @State private var unit: String
    @State private var timebase: TempoMarkerTimebase
    @State private var invalid = false
    @State private var shake = 0.0
    init(marker: TimelineMarker, save: @escaping (TimelineMarker) -> Void) {
        self.marker = marker; self.save = save
        _bpm = State(initialValue: String(format: "%g", marker.tempoBPM ?? 120))
        _beats = State(initialValue: String(marker.tempoBeats ?? 4)); _unit = State(initialValue: String(marker.tempoUnit ?? 4))
        _timebase = State(initialValue: marker.tempoTimebase ?? .global)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tempo marker").font(.headline)
            HStack(spacing: 10) {
                Text(verbatim: "BPM")
                TextField("BPM", text: $bpm).frame(width: 72).accessibilityLabel("BPM")
                Text("Time signature")
                TextField("Beats per bar", text: $beats).frame(width: 36)
                Text(verbatim: "/")
                TextField("Beat unit", text: $unit).frame(width: 36)
            }.textFieldStyle(.roundedBorder)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalid ? .red : .clear))
                .modifier(InputValidationShake(animatableData: shake))
            if invalid { Text("Invalid tempo or time signature.").font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Timebase")
                Picker("Timebase", selection: $timebase) {
                    ForEach(TempoMarkerTimebase.allCases, id: \.self) { mode in Text(LocalizedStringKey(mode.title)).tag(mode) }
                }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Timebase")
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply", action: apply).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 420).foregroundStyle(JarasTheme.text).background(JarasTheme.background)
    }
    private func apply() {
        guard let value = Double(bpm.replacingOccurrences(of: ",", with: ".")), value.isFinite, TimelineTempo.bpmRange.contains(value),
              let beats = Int(beats), (1...32).contains(beats), let unit = Int(unit), TimelineTempo.beatUnits.contains(unit) else {
            if let value = Double(bpm), value.isFinite { bpm = String(format: "%g", min(300, max(60, value))) }
            invalid = true; withAnimation(.linear(duration: 0.35)) { shake += 1 }; return
        }
        var edited = marker; edited.name = "TEMPO"; edited.color = 0x999999
        edited.tempoBPM = value; edited.tempoBeats = beats; edited.tempoUnit = unit
        edited.tempoTimebase = timebase
        save(edited); dismiss()
    }
}

private struct AdvancedSetlistColors: View {
    @AppStorage("jaras.setlist.idMode") private var idMode = "playlist"
    @AppStorage("jaras.setlist.fontStyle") private var fontStyle = 0
    @AppStorage("jaras.setlist.allRegionsTextColor") private var allRegions = 0xffffff
    @AppStorage("jaras.setlist.playlistTextColor") private var playlists = 0xb9e229
    @AppStorage("jaras.setlist.unifiedTextColor") private var unified = 0xff6f00
    var body: some View {
        VStack(spacing: 18) {
            Picker("Setlist ID mode", selection: $idMode) {
                Text("Playlist ID").tag("playlist")
                Text("Region ID").tag("region")
            }
            Picker("Setlist font", selection: $fontStyle) {
                Text("Regular").tag(0)
                Text("Bold").tag(1)
                Text("Bold italic").tag(2)
            }
            SetlistTextColorRow(title: "All Regions song text", value: $allRegions)
            SetlistTextColorRow(title: "Playlist song text", value: $playlists)
            SetlistTextColorRow(title: "Unified drawer song text", value: $unified)
        }
    }
}

private struct SetlistTextColorRow: View {
    let title: String
    @Binding var value: Int
    @State private var editing = false
    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            Button { editing = true } label: {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: UInt32(value)))
                    .frame(width: 44, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(JarasTheme.secondary))
            }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title)))
                .popover(isPresented: $editing) {
                    NameColorEditor(title: title, initialName: "", initialColor: UInt32(value),
                        save: { _, color in value = Int(color) }, close: { editing = false }, nameEditable: false, showsName: false,
                        previewColor: { value = Int($0) })
                }
        }
    }
}
