import SwiftUI
import UniformTypeIdentifiers
struct TransportView: View {
    @State private var showingExport = false
    @ObservedObject var show: ShowController
    var mediaDirectory: URL? = nil
    var toggleNavigation: () -> Void = {}
    var openSettings: () -> Void = {}
    var mixerCollapsed = false
    var setlistCollapsed = false
    var toggleMixer: () -> Void = {}
    var toggleSetlist: () -> Void = {}
    var body: some View {
        GeometryReader { geometry in
            let width = max(1230, geometry.size.width)
            let spacing = min(6, max(3, (width - 1230) / 43))
            transportContent(spacing: spacing)
                .frame(width: width, height: 82, alignment: .leading)
        }.frame(height: 82).clipped()
            .sheet(isPresented: $showingExport) { AudioExportView(project: show.snapshot.project, song: show.current, mediaDirectory: mediaDirectory) }
    }
    private func transportContent(spacing: CGFloat) -> some View {
        let transport = show.snapshot.transport
        let controlPadding = 5 + spacing / 2
        let controlFont = 11 + spacing / 8
        return HStack(spacing: spacing) {
            VStack(spacing: 2) {
                Button(action: toggleNavigation) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 18)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Menu")
                PanelCollapseButton(collapsed: mixerCollapsed, title: "Tracks", label: mixerCollapsed ? "Expandir Track-Mixer" : "Recolher Track-Mixer", tooltip: mixerCollapsed ? "Restaurar largura anterior do Track-Mixer" : "Ocultar Track-Mixer", action: toggleMixer)
            }.frame(width: 44)
            MasterStrip(show: show).frame(width: 190)
            VStack(spacing: 5) {
                HStack(spacing: spacing) {
                    transportDisplay
                    HStack(spacing: 3) {
                        ForEach(["GrandMA2", "Resolume"], id: \.self) { title in
                            Button {} label: {
                                Text(verbatim: title).font(.system(size: 10, weight: .semibold)).frame(width: 64, height: 25).contentShape(Rectangle())
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6)))
                            }.buttonStyle(.plain).accessibilityLabel(title)
                        }
                        Button { showingExport = true } label: {
                            Text("Export").font(.system(size: 10, weight: .semibold)).frame(width: 82, height: 25).contentShape(Rectangle())
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.8)))
                        }.buttonStyle(.plain).jarasHelp("Export").accessibilityLabel("Export")
                        Button(action: openSettings) {
                            Image(systemName: "gearshape").frame(width: 32, height: 25).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Configurações")
                    }
                }
                HStack(spacing: spacing / 2) {
                    Button { show.send(transport.playing ? .stop : .play) } label: {
                        Label { Text(verbatim: transport.playing ? "Stop" : "Play") } icon: {
                            Image(systemName: transport.playing ? "stop.fill" : "play.fill").frame(width: 12)
                        }.frame(width: 60)
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: transport.playing, horizontalPadding: controlPadding, fontSize: controlFont)).jarasHelp(ControlMappings.shared.shortcutHelp(.playStop))
                    Spacer(minLength: 0)
                    Button { show.send(.pause) } label: { Image(systemName: "pause.fill") }
                        .accessibilityLabel("Pause").jarasHelp("Pause").disabled(!transport.playing)
                    Spacer(minLength: 0)
                    Button { show.send(transport.subPlay.playing ? .subStop : .subPlay) } label: {
                        Label("Sub Play", systemImage: transport.subPlay.playing ? "pause.fill" : "play.fill").fixedSize()
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.yellow, active: transport.subPlay.playing, horizontalPadding: controlPadding, fontSize: controlFont))
                        .disabled(!transport.playing).jarasHelp(ControlMappings.shared.shortcutHelp(.subPlayStop))
                    Spacer(minLength: 0)
                    RepeatControl(active: transport.loop.enabled) { show.send(.toggleLoop) }
                    Spacer(minLength: 0)
                    TransportRecordButton(show: show)
                    Spacer(minLength: 0)
                    TempoControl(show: show)
                    #if os(macOS)
                    Spacer(minLength: 0)
                    TeleprompterTimerControl()
                    Spacer(minLength: 0)
                    TeleprompterToggleButton(show: show, directory: mediaDirectory)
                    Spacer(minLength: 0)
                    TeleprompterPreviewButton()
                    Spacer(minLength: 0)
                    VideoToggleButton()
                    Spacer(minLength: 0)
                    RemoteToggleButton()
                    #endif
                    Spacer(minLength: 0)
                    ProjectSaveButton(pending: show.hasUnsavedChanges, saving: show.saving, message: show.message) { Task { await show.save() } }
                    Spacer(minLength: 0)
                    PanelCollapseButton(collapsed: setlistCollapsed, title: "Setlist", label: setlistCollapsed ? "Expandir Setlist" : "Recolher Setlist", tooltip: setlistCollapsed ? "Restaurar largura anterior do Setlist" : "Ocultar Setlist", action: toggleSetlist)
                        .frame(width: 56, height: 32, alignment: .bottom)
                }
            }.frame(maxWidth: .infinity)

        }
        .buttonStyle(TransportButtonStyle(horizontalPadding: controlPadding, fontSize: controlFont)).padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity).background(JarasTheme.panel)
    }
    private var transportDisplay: some View {
        let transport = show.snapshot.transport
        let parts = show.current?.parts ?? []
        let selected = parts.first { $0.id == (transport.playing ? transport.regionId : show.focusedRegion ?? transport.regionId) }
        let rootID = selected?.parentRegionID ?? selected?.id
        let runningSong = transport.playing ? show.current?.playingSetlistRegion(transport.regionId, position: transport.position, expanded: Set(rootID.map { [$0] } ?? [])) : nil
        let current = transport.ignoreNextRegionId.flatMap { id in parts.first { $0.id == id } } ?? runningSong ?? selected
        let nextInternal = transport.playing && transport.ignoreNextAfter == nil ? show.current?.nextDrawerRegion(transport.regionId, position: transport.position) : nil
        let queued = transport.subPlay.playing
            ? parts.first { transport.subPlay.position >= $0.startTime && transport.subPlay.position < $0.endTime }
            : parts.first { $0.id == transport.queuedRegionId }
        let upcoming = nextInternal ?? queued
        let seconds = max(0, Int(transport.position))
        return HStack(spacing: 0) {
            CurrentSongDisplay(name: current?.displayName ?? show.current?.name ?? "—", playing: transport.playing, ignoring: transport.ignoreNextAfter != nil)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9)
            Rectangle().fill(JarasTheme.line).frame(width: 1)
            Text(upcoming?.displayName ?? "—").foregroundStyle(JarasTheme.yellow)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9)
                .accessibilityLabel(nextInternal != nil ? "Next song" : transport.subPlay.playing ? "Sub Play" : "Queued song")
            Rectangle().fill(JarasTheme.line).frame(width: 1)
            Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                .monospacedDigit().frame(width: 100).accessibilityLabel("Transport time")
        }.font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(height: 25)
            .background(JarasTheme.display).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(JarasTheme.line))
    }
}

private struct CurrentSongDisplay: View {
    let name: String
    let playing: Bool
    let ignoring: Bool
    var body: some View {
        if ignoring {
            TimelineView(.periodic(from: .now, by: 0.5)) { tick in
                HStack(spacing: 6) {
                    Text(name).lineLimit(1).opacity(Int(tick.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0.3)
                    Text(verbatim: "Ignore Next").font(.system(size: 9, weight: .bold)).foregroundStyle(JarasTheme.yellow).fixedSize()
                }.foregroundStyle(JarasTheme.green)
            }
        } else { Text(name).foregroundStyle(playing ? JarasTheme.green : JarasTheme.text) }
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
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(collapsed ? Color.red : JarasTheme.green)
                .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(label))
            .accessibilityValue(collapsed ? "Hidden" : "Shown").jarasHelp(tooltip)
    }
}

private struct TempoControl: View {
    @ObservedObject var show: ShowController
    @State private var editing = false
    @State private var bpmDraft = "120"
    @State private var beats = "4"
    @State private var unit = "4"
    @State private var invalidBPM = false
    @State private var bpmShake = 0.0
    @FocusState private var meterFocus: Int?
    @FocusState private var bpmFocus: Bool
    private var bpmText: String { String(format: "%g", show.current?.bpm ?? 120) }
    var body: some View {
        HStack(spacing: 3) {
            TextField("4", text: $beats).focused($meterFocus, equals: 0)
                .frame(width: 28).accessibilityLabel("Beats per bar")
                .onSubmit { commitMeter(); meterFocus = nil }
            Text(verbatim: "/").foregroundStyle(JarasTheme.text).frame(width: 8).fixedSize()
            TextField("4", text: $unit).focused($meterFocus, equals: 1)
                .frame(width: 28).accessibilityLabel("Beat unit")
                .onSubmit { commitMeter(); meterFocus = nil }
            Button {
                show.tapTempo()
            } label: {
                VStack(spacing: 0) {
                    Text(bpmText).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text("BPM").font(.system(size: 8))
                }.frame(width: 55, height: 32).background(JarasTheme.display)
                    .clipShape(RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("BPM · Tap tempo")
                .jarasHelp("Tap tempo · Right-click to edit BPM")
                .immediateRightClick { bpmDraft = bpmText; invalidBPM = false; editing = true }
            VStack(spacing: 2) {
                tempoStep(1, symbol: "plus")
                tempoStep(-1, symbol: "minus")
            }
        }.textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
            .font(.system(size: 12, design: .monospaced))
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.55), lineWidth: 1).allowsHitTesting(false))
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
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 15).background(JarasTheme.display)
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
    @State private var dimmed = false
    @State private var confirmingSave = false
    var body: some View {
        Button { confirmingSave = true } label: {
            Label(LocalizedStringKey(saving ? "Salvando…" : pending ? "Save" : "Salvo"), systemImage: pending ? "square.and.arrow.down" : "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 82, height: 30)
                .foregroundStyle(pending ? JarasTheme.green : JarasTheme.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(pending ? JarasTheme.green.opacity(0.16) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(pending ? JarasTheme.green.opacity(0.7) : JarasTheme.line))
                .opacity(pending && dimmed ? 0.4 : 1)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!pending || saving)
            .keyboardShortcut("s", modifiers: .command)
            .alert("Do you want to save this project?", isPresented: $confirmingSave) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { action() }.keyboardShortcut(.defaultAction)
            }
            .jarasHelp(message.isEmpty ? "Save" : message)
            .onAppear { animate(pending) }
            .onChange(of: pending) { animate($0) }
    }
    private func animate(_ active: Bool) {
        if active { withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) { dimmed = true } }
        else { withAnimation(nil) { dimmed = false } }
    }
}
struct TransportButtonStyle: ButtonStyle {
    var color = JarasTheme.panel
    var active = false
    var horizontalPadding: CGFloat = 9
    var fontSize: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, horizontalPadding).frame(height: 32)
            .foregroundStyle(active ? Color.black : JarasTheme.text)
            .background(active ? color : color.opacity(configuration.isPressed ? 0.7 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? color : Color.white.opacity(0.45)))
    }
}
struct TransportPreview: PreviewProvider { static var previews: some View { TransportView(show: try! AppContainer(preview: true).show).frame(width: 980) } }

private struct RepeatControl: View {
    let active: Bool
    let action: () -> Void
    @State private var pulse = false
    var body: some View {
        Button(action: action) { Image(systemName: "repeat") }
            .buttonStyle(TransportButtonStyle(color: active ? JarasTheme.yellow : JarasTheme.panel, active: active))
            .opacity(active && pulse ? 0.45 : 1)
            .accessibilityLabel("Repeat").jarasHelp("Repeat (R)")
            .onAppear { animate() }.onChange(of: active) { _ in animate() }
    }
    private func animate() {
        pulse = false
        if active { withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

#if os(macOS)
private struct VideoToggleButton: View {
    @ObservedObject private var video = VideoPlayback.shared
    var body: some View {
        Button { video.toggle() } label: { Label("Video",systemImage: "video").lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(minWidth: 62) }
            .buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: video.visible))
            .overlay(VideoOptionsInput(controller: video))
            .jarasHelp("Show / hide video")
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
    @State private var active = false
    var body: some View {
        Button { active.toggle() } label: {
            Label { Text(verbatim: "Remote") } icon: { Image(systemName: "network") }
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(TransportButtonStyle(color: active ? JarasTheme.green : Color(hex: 0xc44545), active: true))
            .accessibilityLabel("Remote").accessibilityValue(active ? "On" : "Off")
    }
}
