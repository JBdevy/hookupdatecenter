import SwiftUI

struct AdvancedView: View {
    @ObservedObject var show: ShowController
    let documents: ProjectDocuments?
    @Environment(\.dismiss) private var dismiss
    private enum Tab: String, CaseIterable {
        case timeProject = "TimeProject", timeline = "Timeline", record = "Record", reRender = "Re-render", video = "Video", setlist = "Setlist"
        var icon: String { switch self { case .timeProject: return "metronome"; case .timeline: return "square.grid.3x3"; case .record: return "record.circle"; case .reRender: return "waveform"; case .video: return "video"; case .setlist: return "list.bullet" } }
    }
    @State private var tab = Tab.timeProject
    @State private var bpm: String
    @State private var beats: String
    @State private var unit: String
    @State private var settings: ProjectTimeSettings
    @State private var invalidField: Int?
    @State private var shake = 0.0
    @FocusState private var focus: Int?

    init(show: ShowController, documents: ProjectDocuments? = nil) {
        self.show = show; self.documents = documents
        let timing = GlobalProjectTiming.load() ?? show.current.map { GlobalProjectTiming(song: $0) } ?? GlobalProjectTiming()
        _bpm = State(initialValue: String(format: "%g", timing.bpm))
        _beats = State(initialValue: String(timing.beats))
        _unit = State(initialValue: String(timing.unit))
        _settings = State(initialValue: timing.settings)
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
                            Label { Text(LocalizedStringKey(item.rawValue)).lineLimit(2).minimumScaleFactor(0.8) } icon: { Image(systemName: item.icon) }
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
                    if tab == .timeline { AdvancedTimelineSettings(documents: documents) }
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
        if show.configureProjectTime(bpm: tempo, beats: numerator, unit: denominator, settings: settings) {
            GlobalProjectTiming(bpm: tempo, beats: numerator, unit: denominator, settings: settings).save()
            dismiss()
        }
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

private struct AdvancedTimelineSettings: View {
    let documents: ProjectDocuments?
    @State private var confirmingCleanup = false
    @AppStorage("jaras.timeline.gridlines") private var gridlines = GlobalProjectTiming.load()?.settings.divisions != 0
    var body: some View {
        VStack(spacing: 18) {
            Picker("Gridline", selection: $gridlines) {
                Text("Enabled").tag(true)
                Text("Disabled").tag(false)
            }
            SetlistTextColorRow(title: "Timeline background", key: "jaras.timeline.background", defaultColor: TimelineAppearanceDefaults.background, showsReset: true)
            SetlistTextColorRow(title: "Primary grid color", key: "jaras.timeline.primaryGrid", defaultColor: TimelineAppearanceDefaults.primaryGrid, showsReset: true)
            SetlistTextColorRow(title: "Secondary grid color", key: "jaras.timeline.secondaryGrid", defaultColor: TimelineAppearanceDefaults.secondaryGrid, showsReset: true)
            SetlistTextColorRow(title: "Playback cursor color", key: "jaras.timeline.playCursor", defaultColor: TimelineAppearanceDefaults.playCursor, showsReset: true)
            SetlistTextColorRow(title: "Edit cursor color", key: "jaras.timeline.editCursor", defaultColor: TimelineAppearanceDefaults.editCursor, showsReset: true)
            SetlistTextColorRow(title: "Sub Play cursor color", key: "jaras.timeline.subPlayCursor", defaultColor: TimelineAppearanceDefaults.subPlayCursor, showsReset: true)
            if let documents {
                Divider()
                HStack {
                    Text("Clean up files deleted from the timeline")
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingCleanup = true }
                        .disabled(!documents.canCleanTimelineMedia)
                }
                .sheet(isPresented: $confirmingCleanup) { TimelineMediaCleanupConfirmation(documents: documents) }
            }
        }
    }
}

private struct AdvancedSetlistColors: View {
    @AppStorage("jaras.setlist.idMode") private var idMode = "playlist"
    @AppStorage("jaras.setlist.fontStyle") private var fontStyle = 0
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
            SetlistTextColorRow(title: "All Regions song text", key: "jaras.setlist.allRegionsTextColor", defaultColor: 0xffffff)
            SetlistTextColorRow(title: "Playlist song text", key: "jaras.setlist.playlistTextColor", defaultColor: 0x00ff9a)
            SetlistTextColorRow(title: "Unified drawer song text", key: "jaras.setlist.unifiedTextColor", defaultColor: 0xffeb3b)
        }
    }
}

private struct SetlistTextColorRow: View {
    let title: String
    let defaultColor: Int
    let showsReset: Bool
    @ObservedObject private var color: AppearanceColor
    @State private var editing = false
    init(title: String, key: String, defaultColor: Int, showsReset: Bool = false) {
        self.title = title
        self.defaultColor = defaultColor
        self.showsReset = showsReset
        self.color = AppearanceColor.shared(key, default: defaultColor)
    }
    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            Button { editing = true } label: {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: UInt32(color.value)))
                    .frame(width: 44, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(JarasTheme.secondary))
            }.buttonStyle(.plain).accessibilityLabel(Text(LocalizedStringKey(title)))
                .popover(isPresented: $editing) {
                    NameColorEditor(title: title, initialName: "", initialColor: UInt32(color.value),
                        save: { _, value in color.save(Int(value)) }, close: { editing = false }, nameEditable: false, showsName: false,
                        previewColor: { if color.value != Int($0) { color.value = Int($0) } })
                }
            if showsReset {
                Button("Reset") { color.save(defaultColor) }
                    .font(.caption)
                    .disabled(color.value == defaultColor)
                    .accessibilityLabel(Text("Reset") + Text(" ") + Text(LocalizedStringKey(title)))
            }
        }
    }
}

private struct TimelineMediaCleanupConfirmation: View {
    @ObservedObject var documents: ProjectDocuments
    @Environment(\.dismiss) private var dismiss
    @State private var availableAt = ProcessInfo.processInfo.systemUptime + 3
    @State private var remaining = 3
    @State private var working = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Clean up files deleted from the timeline", systemImage: "trash")
                .font(.headline).foregroundStyle(.red)
            Text("This saves the project and permanently removes audio and video files deleted from the timeline from its Stems and Videos folders. Files still in use are kept. Recovery backups retain their media. The editing undo history will be cleared. This cleanup cannot be undone.")
            if let url = documents.currentURL {
                Text(verbatim: url.deletingLastPathComponent().path).font(.caption)
                    .textSelection(.enabled).foregroundStyle(JarasTheme.secondary)
            }
            if !error.isEmpty { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(role: .destructive, action: clean) {
                    if remaining > 0 { Text("Delete in \(remaining)s") } else { Text("Delete") }
                }.buttonStyle(StageButtonStyle(color: .red))
                    .disabled(remaining > 0 || working || !documents.canCleanTimelineMedia)
            }
        }.padding(24).frame(width: 480).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .interactiveDismissDisabled(working)
            .task {
                while !Task.isCancelled {
                    remaining = max(0, Int(ceil(availableAt - ProcessInfo.processInfo.systemUptime)))
                    if remaining == 0 { break }
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
            }
    }
    private func clean() {
        guard ProcessInfo.processInfo.systemUptime >= availableAt, !working else { return }
        working = true; error = ""
        Task { @MainActor in
            do { try await documents.cleanTimelineMedia(); dismiss() }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
