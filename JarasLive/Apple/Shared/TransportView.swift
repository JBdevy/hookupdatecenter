import SwiftUI
import UniformTypeIdentifiers
struct TransportView: View {
    @State private var showingExport = false
    @State private var showingAdvanced = false
    @ObservedObject var show: ShowController
    var documents: ProjectDocuments? = nil
    var remotePresentation = false
    var mediaDirectory: URL? = nil
    var toggleNavigation: () -> Void = {}
    var openSettings: () -> Void = {}
    var mixerCollapsed = false
    var setlistCollapsed = false
    var toggleMixer: () -> Void = {}
    var toggleSetlist: () -> Void = {}
    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            let width = remotePresentation ? geometry.size.width : max(1296, geometry.size.width)
            #else
            let width = geometry.size.width
            #endif
            let spacing = min(6, max(3, (width - 1296) / 43))
            transportContent(spacing: spacing)
                .frame(width: width, height: 86, alignment: .leading)
        }.frame(height: 86).clipped()
            .sheet(isPresented: $showingExport) { AudioExportView(project: show.snapshot.project, song: show.current, mediaDirectory: mediaDirectory) }
            .sheet(isPresented: $showingAdvanced) { AdvancedView(show: show, documents: documents) }
    }
    private func transportContent(spacing: CGFloat) -> some View {
        let transport = show.snapshot.transport
        let controlPadding = 5 + spacing / 2
        let controlFont = 11 + spacing / 8
        #if os(macOS)
        let playbackSpacing = spacing / 2 + 2
        let remainingSpacing = max(0, spacing / 2 - 1)
        #else
        let playbackSpacing = spacing / 2
        let remainingSpacing = spacing / 2
        #endif
        return HStack(spacing: spacing) {
            #if !os(macOS)
            VStack(spacing: 5) {
                Button(action: toggleNavigation) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 18)).frame(width: TransportControlMetrics.width, height: 25).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Menu")
                PanelCollapseButton(collapsed: mixerCollapsed, title: "Tracks", label: mixerCollapsed ? "Expandir Track-Mixer" : "Recolher Track-Mixer", tooltip: mixerCollapsed ? "Restaurar largura anterior do Track-Mixer" : "Ocultar Track-Mixer", action: toggleMixer)
                    .frame(height: 43)
            }.frame(width: TransportControlMetrics.width)
            #endif
            MasterStrip(show: show).frame(width: 190)
            VStack(spacing: 5) {
                HStack(spacing: spacing) {
                    transportDisplay
                    HStack(spacing: 3) {
                        RegionTunerControl(show: show)
                        Button { showingAdvanced = true } label: {
                            Text(verbatim: "Advanced").font(.system(size: 10, weight: .semibold)).frame(width: 68, height: 25).contentShape(Rectangle())
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6)))
                        }.buttonStyle(.plain).accessibilityLabel("Advanced").jarasHelp("Advanced")
                        #if os(macOS)
                        if !remotePresentation {
                        ForEach(["Resolume"], id: \.self) { title in
                            Button {} label: {
                                Text(verbatim: title).font(.system(size: 10, weight: .semibold)).frame(width: 64, height: 25).contentShape(Rectangle())
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6)))
                            }.buttonStyle(.plain).accessibilityLabel(title)
                        }
                        }
                        #endif
                        Button { showingExport = true } label: {
                            Text("Export").font(.system(size: 10, weight: .semibold)).frame(width: 82, height: 25).contentShape(Rectangle())
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.8)))
                        }.buttonStyle(.plain).jarasHelp("Export").accessibilityLabel("Export")
                        Button(action: openSettings) {
                            Image(systemName: "gearshape").frame(width: 32, height: 25).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Configurações")
                    }
                }
                HStack(spacing: remainingSpacing) {
                    HStack(spacing: playbackSpacing) {
                    Button { show.send(transport.playing ? .stop : .play) } label: {
                        Label { Text(verbatim: transport.playing ? "Stop" : "Play") } icon: {
                            Image(systemName: transport.playing ? "stop.fill" : "play.fill").frame(width: 12)
                        }
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: transport.playing, fontSize: TransportControlMetrics.font, width: TransportControlMetrics.width, height: TransportControlMetrics.height)).jarasHelp(ControlMappings.shared.shortcutHelp(.playStop))
                    Button { show.send(.pause) } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(TransportButtonStyle(fontSize: TransportControlMetrics.font, width: TransportControlMetrics.width, height: TransportControlMetrics.height))
                        .accessibilityLabel("Pause").jarasHelp("Pause").disabled(!transport.playing)
                    Button { show.send(transport.subPlay.playing ? .subStop : .subPlay) } label: {
                        HStack(spacing: 2) {
                            Image(systemName: transport.subPlay.playing ? "pause.fill" : "play.fill")
                            Text("Sub Play")
                        }
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.yellow, active: transport.subPlay.playing, fontSize: TransportControlMetrics.font, width: TransportControlMetrics.width, height: TransportControlMetrics.height))
                        .disabled(!transport.playing).jarasHelp(ControlMappings.shared.shortcutHelp(.subPlayStop))
                    RepeatControl(active: transport.loop.enabled) { show.send(.toggleLoop) }
                    TransportRecordButton(show: show)
                    MetronomeControl(show: show)
                    }.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    TempoControl(show: show)
                    #if os(macOS)
                    Spacer(minLength: 0)
                    if !remotePresentation {
                    TeleprompterTimerControl()
                    Spacer(minLength: 0)
                    TeleprompterToggleButton(show: show, directory: mediaDirectory, index: 1)
                    TeleprompterToggleButton(show: show, directory: mediaDirectory, index: 2)
                    TPNoticeButton()
                    Spacer(minLength: 0)
                    TeleprompterPreviewButton()
                    Spacer(minLength: 0)
                    VideoToggleButton()
                    Spacer(minLength: 0)
                    RemoteToggleButton(show: show)
                    }
                    #endif
                    Spacer(minLength: 0)
                    ProjectSaveButton(pending: show.hasUnsavedChanges, saving: show.saving, message: show.message) { Task { await show.save() } }
                    Spacer(minLength: 0)
                    PanelCollapseButton(collapsed: setlistCollapsed, title: "Setlist", label: setlistCollapsed ? "Expandir Setlist" : "Recolher Setlist", tooltip: setlistCollapsed ? "Restaurar largura anterior do Setlist" : "Ocultar Setlist", action: toggleSetlist)
                        .frame(width: TransportControlMetrics.width, height: TransportControlMetrics.height)
                }
            }.frame(maxWidth: .infinity)


        }
        .buttonStyle(TransportButtonStyle(horizontalPadding: controlPadding, fontSize: controlFont)).padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity).background(JarasTheme.panel)
    }
    private var transportDisplay: some View {
        let transport = show.snapshot.transport
        let displays = TransportSongDisplays(song: show.current, transport: transport, focusedRegion: show.focusedRegion)
        let seconds = max(0, Int(transport.position))
        return HStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    SongNameDisplay(title: transport.playing ? "Now playing" : "Selected song", name: displays.current?.displayName ?? show.current?.name,
                        bpm: displays.currentBPM, color: transport.playing ? JarasTheme.green : JarasTheme.text)
                        .frame(width: max(0, (geometry.size.width - 1) * 0.75))
                        .accessibilityLabel("Current song")
                    Rectangle().fill(JarasTheme.line).frame(width: 1)
                    FooterInformationDisplay(show: show, embedded: true)
                        .frame(width: max(0, (geometry.size.width - 1) * 0.25))
                }
            }
            Rectangle().fill(JarasTheme.line).frame(width: 1)
            Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                .monospacedDigit().frame(width: 100).accessibilityLabel("Transport time")
        }.font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(height: 25)
            .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line))
    }
}

#if os(macOS)
struct FooterPlaylistDisplay: View {
    @ObservedObject var show: ShowController
    var height: CGFloat = 25
    private var duration: String {
        // listedRegions contains the selected playlist's root regions only;
        // children inside a special region already belong to its full span.
        let total = show.listedRegions.reduce(0.0) { sum, region in
            let seconds = region.endTime - region.startTime
            return sum + (seconds.isFinite ? max(0, seconds) : 0)
        }
        let seconds = Int(min(Double(Int.max / 2), total))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var body: some View {
        let transport = show.snapshot.transport
        let displays = TransportSongDisplays(song: show.current, transport: transport, focusedRegion: show.focusedRegion)
        FooterSongDisplays(next: displays.next?.displayName, nextBPM: displays.nextBPM,
            queued: displays.queued?.displayName, queuedBPM: displays.queuedBPM, subPlaying: transport.subPlay.playing, duration: duration, height: height)
    }
}
#endif

struct FooterInformationDisplay: View {
    @ObservedObject var show: ShowController
    var documents: ProjectDocuments? = nil
    var embedded = false
    private var displayHeight: CGFloat { embedded ? 25 : 21 }
    private var hasMultiLoop: Bool {
        guard let song = show.current else { return false }
        let transport = show.snapshot.transport
        let region = transport.playing ? show.pitchRegion : song.parts.first { $0.id == (show.focusedRegion ?? transport.regionId) }
        guard let region else { return false }
        if region.totalLoop == true || !(region.multiLoops ?? []).isEmpty { return true }
        if let parent = region.parentRegionID {
            return song.parts.contains { $0.id == parent && ($0.totalLoop == true || !($0.multiLoops ?? []).isEmpty) }
        }
        return song.parts.contains { $0.parentRegionID == region.id && ($0.totalLoop == true || !($0.multiLoops ?? []).isEmpty) }
    }
    private var information: String {
        if show.snapshot.transport.loop.enabled { return "Loop Ativo" }
        if show.snapshot.transport.ignoreNextAfter != nil { return "Ignore Next" }
        if hasMultiLoop { return JarasLocalization.string("This song has an active multiloop") }
        return ""
    }
    // Follow the transport clock, so the pulse stays on the beat through
    // tempo changes, seeks and loop wraps without another UI timer.
    static func loopBeatPhase(transport: TransportState, song: Song?) -> Int? {
        guard transport.playing, transport.loop.enabled,
              let marker = song?.activeTempoMarker(at: transport.position), let bpm = marker.tempoBPM else { return nil }
        let beat = max(0, transport.position - marker.position) * bpm / 60
        let index = Int(beat)
        return beat - Double(index) < 0.45 ? 0 : (index.isMultiple(of: 2) ? 1 : 3)
    }
    var body: some View {
        let message = information
        TransportInformationMessage(message: message,
            beatPhase: Self.loopBeatPhase(transport: show.snapshot.transport, song: show.current),
            steady: hasMultiLoop && show.snapshot.transport.ignoreNextAfter == nil && !show.snapshot.transport.loop.enabled,
            height: displayHeight, cornerRadius: embedded ? 0 : 4)
        .font(.system(size: 10, weight: .bold)).lineLimit(1).truncationMode(.tail)
            .overlay { if !embedded { RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false) } }
            .accessibilityLabel("Information").accessibilityValue(message)
    }
}

/// Shared notice colors and pulse for the Mac, iPad and iPhone.
struct TransportInformationMessage: View {
    let message: String
    var beatPhase: Int? = nil
    var steady = false
    var height: CGFloat = 25
    var cornerRadius: CGFloat = 0
    var body: some View {
        Group {
            if let phase = beatPhase {
                pulse(bright: phase == 0, green: phase == 1)
            } else if steady || message.isEmpty {
                Text(verbatim: message.isEmpty ? " " : message).foregroundStyle(JarasTheme.green)
                    .frame(maxWidth: .infinity).frame(height: height)
                    .background(JarasTheme.display, in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { tick in
                    let phase = Int(tick.date.timeIntervalSinceReferenceDate * 2) % 4
                    pulse(bright: phase.isMultiple(of: 2), green: phase == 1)
                }
            }
        }
    }
    private func pulse(bright: Bool, green: Bool) -> some View {
        Text(verbatim: message)
            .foregroundStyle(bright ? Color.red : green ? JarasTheme.green : JarasTheme.yellow)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(bright ? JarasTheme.yellow : Color.black, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct SongNameDisplay: View {
    let title: String
    let name: String?
    let bpm: Double?
    var color: Color = JarasTheme.yellow
    var fontScale: CGFloat = 1
    var labelFontScale: CGFloat? = nil
    var body: some View {
        HStack(spacing: 5 * fontScale) {
            Text(LocalizedStringKey(title)).font(.system(size: 10 * (labelFontScale ?? fontScale), weight: .bold, design: .rounded)).italic()
                .foregroundStyle(JarasTheme.secondary).fixedSize()
            Image(systemName: "chevron.right").font(.system(size: 9 * (labelFontScale ?? fontScale), weight: .bold)).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: (name ?? "—") + (bpm.map { " - " + String(format: "%g", $0) + " bpm" } ?? ""))
                .font(.system(size: 12 * fontScale, weight: .semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).clipped()
    }
}

struct FooterSongDisplays: View {
    let next: String?
    let nextBPM: Double?
    let queued: String?
    let queuedBPM: Double?
    let subPlaying: Bool
    let duration: String
    var height: CGFloat = 25
    // Grow text continuously, keeping room for song names in each column.
    private var fontScale: CGFloat { max(1, sqrt(height / 25)) }
    private var labelFontScale: CGFloat { 1 + (fontScale - 1) * 0.35 }
    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 2)
            HStack(spacing: 0) {
                SongNameDisplay(title: "Next song label", name: next, bpm: nextBPM, fontScale: fontScale, labelFontScale: labelFontScale).frame(width: width * 0.45)
                Rectangle().fill(JarasTheme.line).frame(width: 1)
                SongNameDisplay(title: subPlaying ? "Sub Play" : "Queued", name: queued, bpm: queuedBPM, fontScale: fontScale, labelFontScale: labelFontScale).frame(width: width * 0.45)
                Rectangle().fill(JarasTheme.line).frame(width: 1)
                Text(verbatim: duration).font(.system(size: 12 * fontScale, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(JarasTheme.yellow).lineLimit(1).minimumScaleFactor(0.3)
                    .frame(width: width * 0.10, height: height).accessibilityLabel("Playlist duration")
            }
        }.frame(height: height).background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false))
    }
}

private struct PanelCollapseButton: View {
    let collapsed: Bool
    let title: String
    let label: String
    let tooltip: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(verbatim: title).font(.system(size: 9, weight: .bold))
                .foregroundStyle(collapsed ? Color.white : Color.black)
                .frame(maxWidth: .infinity).frame(height: TransportControlMetrics.height)
                .background(collapsed ? Color.red : JarasTheme.green)
                .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityValue(collapsed ? "Hidden" : "Shown").jarasHelp(tooltip)
    }
}

private struct TempoControl: View {
    @ObservedObject var show: ShowController
    var documents: ProjectDocuments? = nil
    @State private var editing = false
    @State private var bpmDraft = "120"
    @State private var beats = "4"
    @State private var unit = "4"
    @State private var invalidBPM = false
    @State private var bpmShake = 0.0
    @FocusState private var meterFocus: Int?
    @FocusState private var bpmFocus: Bool
    private var bpmText: String {
        String(format: "%g", show.tempoControlBPM)
    }
    var body: some View {
        HStack(spacing: 3) {
            TextField("4", text: $beats).focused($meterFocus, equals: 0)
                .frame(width: 30).accessibilityLabel("Beats per bar")
                .onSubmit { commitMeter(); meterFocus = nil }
            Text(verbatim: "/").foregroundStyle(JarasTheme.text).frame(width: 8).fixedSize()
            TextField("4", text: $unit).focused($meterFocus, equals: 1)
                .frame(width: 30).accessibilityLabel("Beat unit")
                .onSubmit { commitMeter(); meterFocus = nil }
            Button {
                show.tapTempo()
            } label: {
                VStack(spacing: 0) {
                    Text(bpmText).font(.system(size: 15, weight: .semibold, design: .monospaced))
                    Text("BPM").font(.system(size: 8))
                }.frame(width: 58, height: 35).background(JarasTheme.display)
                    .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("BPM · Tap tempo")
                .jarasHelp("Tap tempo · Right-click to edit BPM")
                .immediateRightClick { bpmDraft = bpmText; invalidBPM = false; editing = true }
            VStack(spacing: 2) {
                tempoStep(1, symbol: "plus")
                tempoStep(-1, symbol: "minus")
            }
        }.textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .padding(4)
            .background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line).allowsHitTesting(false))
            .onAppear(perform: refreshMeter)
            .onChange(of: meterFocus) { _ in commitMeter() }
            .onChange(of: show.current?.meterBeats) { _ in refreshMeter() }
            .onChange(of: show.current?.meterUnit) { _ in refreshMeter() }
            .onChange(of: show.snapshot.project.id) { _ in show.resetTapTempo(); refreshMeter() }
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("BPM").font(.headline)
                    TextField("BPM", text: $bpmDraft).textFieldStyle(.roundedBorder).focused($bpmFocus).onSubmit(commitBPM)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalidBPM ? Color.red : .clear, lineWidth: 1.5))
                        .modifier(InputValidationShake(animatableData: bpmShake))
                    if invalidBPM { Text("Enter a BPM between 60 and 300.").font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Apply", action: commitBPM).keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 260).background(JarasTheme.panel).onAppear { bpmFocus = true }
            }
    }
    private func tempoStep(_ delta: Double, symbol: String) -> some View {
        Button { show.resetTapTempo(); show.adjustTempo(delta) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 25, height: 16).background(JarasTheme.display)
                .clipShape(RoundedRectangle(cornerRadius: 3)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(delta > 0 ? "Increase BPM" : "Decrease BPM")
            .jarasHelp(delta > 0 ? "Increase BPM · Right-click to map" : "Decrease BPM · Right-click to map")
            .immediateRightClick { ControlMappings.shared.begin(track: nil, command: delta > 0 ? "tempoUp" : "tempoDown") }
    }
    private func refreshMeter() { beats = String(show.current?.meterBeats ?? 4); unit = String(show.current?.meterUnit ?? 4) }
    private func commitMeter() {
        if let value = Int(beats) { show.setMeterBeats(value) }
        if let value = Int(unit) { show.setMeterUnit(value) }
        refreshMeter()
    }
    private func commitBPM() {
        guard let value = Double(bpmDraft.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            rejectBPM(bpmText); return
        }
        let limited = min(300, max(60, value))
        guard limited == value else { rejectBPM(String(format: "%g", limited)); return }
        show.resetTapTempo(); show.setTempo(value); editing = false
    }
    private func rejectBPM(_ replacement: String) {
        bpmDraft = replacement; invalidBPM = true; bpmFocus = true
        withAnimation(.linear(duration: 0.35)) { bpmShake += 1 }

    }
}
private struct ProjectSaveButton: View {
    let pending: Bool
    let saving: Bool
    let message: String
    let action: () -> Void
    @State private var confirmingSave = false
    var body: some View {
        Button { confirmingSave = true } label: {
            Label(LocalizedStringKey(saving ? "Salvando…" : pending ? "Save" : "Salvo"), systemImage: pending ? "square.and.arrow.down" : "checkmark")
                .font(.system(size: TransportControlMetrics.font, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: TransportControlMetrics.width, height: TransportControlMetrics.height)
                .foregroundStyle(pending ? JarasTheme.green : JarasTheme.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(pending ? JarasTheme.green.opacity(0.16) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(pending ? JarasTheme.green.opacity(0.7) : JarasTheme.line))
                .modifier(JarasSavePulse(active: pending))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!pending || saving)
            .keyboardShortcut("s", modifiers: .command)
            .alert(Text(verbatim: confirmingSave ? JarasLocalization.string("Do you want to save this project?") : ""), isPresented: $confirmingSave) {
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.cancelAction)
                Button("Save") { action() }.keyboardShortcut(.defaultAction)
            }
            .jarasHelp(message.isEmpty ? "Save" : message)
    }
}
private struct JarasSavePulse: ViewModifier {
    let active: Bool
    @State private var bright = true
    func body(content: Content) -> some View {
        content
            .opacity(active ? (bright ? 1 : 0.48) : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .none, value: bright)
            .onAppear { bright = !active }
            .onChange(of: active) { bright = !$0 }
    }
}
enum TransportControlMetrics {
    static let width: CGFloat = 60
    static let height: CGFloat = 26
    static let font: CGFloat = 10
}
struct TransportButtonStyle: ButtonStyle {
    var color = JarasTheme.panel
    var active = false
    var horizontalPadding: CGFloat = 9
    var fontSize: CGFloat = 12
    var width: CGFloat? = nil
    var height: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.75)
            .fixedSize(horizontal: width == nil, vertical: false)
            .padding(.horizontal, width == nil ? horizontalPadding : 0)
            .frame(width: width, height: height)
            .foregroundStyle(active ? Color.black : JarasTheme.text)
            .background(active ? color : color.opacity(configuration.isPressed ? 0.7 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? color : Color.white.opacity(0.45)))
    }
}
struct TransportPreview: PreviewProvider { static var previews: some View { TransportView(show: try! AppContainer(preview: true).show).frame(width: 980) } }

private struct MetronomeControl: View {
    @ObservedObject var show: ShowController
    var documents: ProjectDocuments? = nil
    @ObservedObject private var settings = MetronomeSettings.shared
    @State private var configuring = false
    private var pulse: Bool {
        guard settings.enabled, show.snapshot.transport.playing, let song = show.current else { return true }
        let position = show.snapshot.transport.position
        let section = song.tempoSection(at: position)
        let beat = max(0, position - section.start) * section.bpm / 60 * Double(section.unit) / 4
        return beat.truncatingRemainder(dividingBy: 1) < 0.35
    }
    var body: some View {
        Button { settings.enabled.toggle() } label: { Image(systemName: "metronome") }
            .buttonStyle(TransportButtonStyle(color: settings.enabled ? JarasTheme.yellow : Color(hex: 0xc44545), active: true, fontSize: TransportControlMetrics.font, width: 30, height: 35))
            .opacity(pulse ? 1 : 0.45)
            .accessibilityLabel("Metronome").accessibilityValue(settings.enabled ? "On" : "Off")
            .jarasHelp("Metronome · Right-click to configure")
            .immediateRightClick { configuring = true }
            .sheet(isPresented: $configuring) { MetronomeEditor() }
    }
}
private struct MetronomeEditor: View {
    @ObservedObject private var settings = MetronomeSettings.shared
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importingA = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Metronome").font(.title2.bold())
            Picker("Click sound", selection: $settings.preset) {
                Text("Digital").tag("Digital")
                Text("Wood").tag("Wood")
                Text("Clave").tag("Clave")
                Text(verbatim: "User").tag("User")
            }
            Picker("Click mode", selection: $settings.mode) {
                Text(verbatim: "A–B").tag(0)
                Text("Only A").tag(1)
                Text("Only B").tag(2)
            }.pickerStyle(.segmented)
            Picker("Output", selection: $settings.output) {
                let choices = OutputPatch.choices(channels: audio.channels, includeMaster: false)
                if !choices.contains(settings.output) {
                    Text(settings.output.title + " — " + JarasLocalization.string("Unavailable")).tag(settings.output)
                }
                ForEach(choices, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            if settings.preset == "User" {
                fileRow(a: true)
                fileRow(a: false)
            }
            volume("Click A", value: $settings.gainA)
            volume("Click B", value: $settings.gainB)
            Text("A: first beat · B: remaining beats").font(.caption).foregroundStyle(.secondary)
            if !settings.error.isEmpty { Text(verbatim: settings.error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 400)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let files): if let url = files.first { settings.importSound(url, a: importingA) }
                case .failure(let error): settings.error = error.localizedDescription
                }
            }
    }
    private func fileRow(a: Bool) -> some View {
        let path = a ? settings.pathA : settings.pathB
        return HStack {
            Text(verbatim: a ? "A" : "B").bold().frame(width: 20)
            TextField("Audio file", text: .constant(path.isEmpty ? "" : String(URL(fileURLWithPath: path).lastPathComponent.dropFirst(37))))
                .textFieldStyle(.roundedBorder).disabled(true)
            Button { importingA = a; importing = true } label: { Image(systemName: "plus") }
                .accessibilityLabel(a ? "Load click A" : "Load click B")
        }
    }
    private func volume(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).frame(width: 48, alignment: .leading)
            Slider(value: value, in: -60...6)
            Text(verbatim: value.wrappedValue <= -60 ? "−∞ dB" : String(format: "%+.2f dB", value.wrappedValue))
                .monospacedDigit().frame(width: 80, alignment: .trailing)
        }
    }
}

private struct RepeatControl: View {
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "repeat") }
            .buttonStyle(TransportButtonStyle(color: active ? JarasTheme.yellow : .red, active: active, fontSize: TransportControlMetrics.font, width: 30, height: TransportControlMetrics.height))
            .modifier(JarasBlink(active: active, interval: 0.55, lowOpacity: 0.45))
            .accessibilityLabel("Repeat").jarasHelp("Repeat (R)")
    }
}

#if os(macOS)
private struct VideoToggleButton: View {
    @ObservedObject private var video = VideoPlayback.shared
    var body: some View {
        Button { video.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "video")
                Text("Video")
            }
            .font(.system(size: TransportControlMetrics.font, weight: .semibold))
            .lineLimit(1)
            .frame(width: TransportControlMetrics.width, height: TransportControlMetrics.height)
            .foregroundStyle(video.visible ? Color.black : JarasTheme.text)
            .background(RoundedRectangle(cornerRadius: 5).fill(video.visible ? JarasTheme.green : Color(hex: 0xc44545)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(video.visible ? JarasTheme.green : Color(hex: 0xc44545)))
            .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .overlay(VideoOptionsInput(controller: video))
            .jarasHelp(ControlMappings.shared.shortcutHelp(.toggleVideo))
    }
}
private struct VideoOptionsInput: NSViewRepresentable {
    let controller: VideoPlayback
    func makeNSView(context: Context) -> VideoOptionsTarget { VideoOptionsTarget() }
    func updateNSView(_ view: VideoOptionsTarget, context: Context) {
        view.controller = controller; view.action = { [weak view] in view?.openMenu() }
    }
}
private final class VideoOptionsTarget: RightClickTargetView {
    weak var controller: VideoPlayback?
    override var priority: Int { 20 }
    func openMenu() {
        guard let event = NSApp.currentEvent, let controller else { return }
        let menu = NSMenu()
        let stretch = NSMenuItem(title: "Stretch", action: #selector(toggleStretch), keyEquivalent: "")
        stretch.target = self; stretch.state = controller.stretch ? .on : .off
        menu.addItem(stretch)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func toggleStretch() { if let controller { controller.setStretch(!controller.stretch) } }
}
#endif

private struct RemoteToggleButton: View {
    let show: ShowController
    @ObservedObject private var remote = DAWRemoteSession.shared
    @State private var settings = false
    var body: some View {
        Button {
            #if os(macOS)
            if remote.enabled { remote.setHostEnabled(false); settings = false }
            else { DAWRemoteHostBridge.bind(show); remote.setHostEnabled(true) }
            #endif
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "network")
                Text(verbatim: "Remote")
            }.lineLimit(1)
        }.buttonStyle(TransportButtonStyle(color: remote.enabled ? JarasTheme.green : Color(hex: 0xc44545), active: true, fontSize: TransportControlMetrics.font, width: TransportControlMetrics.width, height: TransportControlMetrics.height))
            .accessibilityLabel("Remote").accessibilityValue(remote.enabled ? "On" : "Off")
            #if os(macOS)
            .popover(isPresented: $settings) { DAWRemoteHostView() }
            .immediateRightClick { settings = true }
            .onChange(of: remote.connected) { if $0 { settings = false } }
            #endif
    }
}

struct DesktopMultiLoopBypassButton: View {
    @ObservedObject var show: ShowController
    var body: some View {
        MultiLoopBypassButton(active: show.snapshot.transport.multiLoopsBypassed == true) {
            show.send(.toggleMultiLoopBypass)
        }
    }
}
struct MultiLoopBypassButton: View {
    let active: Bool
    let action: () -> Void
    private var buttonColor: Color {
        Color(hex: active ? 0xffd600 : 0xff3030)
    }
    var body: some View {
        Button(action: action) {
            Text(verbatim: "B\nY\nP\nA\nS\nS")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.black)
                .frame(width: 30, height: 82)
                .background(buttonColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .modifier(JarasBlink(active: active, interval: 0.15, lowOpacity: 0.2))
        }.buttonStyle(.plain)
            .accessibilityLabel("Bypass de todos os Multiloops")
            .accessibilityValue(active ? "Ligado" : "Desligado")
            .jarasHelp("Bypass de todos os Multiloops")
    }
}
