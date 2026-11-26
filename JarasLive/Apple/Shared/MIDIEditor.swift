import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)

@MainActor final class MIDIEditorWindows: NSObject, NSWindowDelegate {
    static let shared = MIDIEditorWindows()
    private var windows: [UUID: NSWindow] = [:]
    func closeAll() {
        // Reopening a copy can preserve every UUID. Retire the editing session
        // explicitly so its note selection and pending sheets cannot survive.
        let closing = Array(windows.values)
        windows.removeAll()
        for window in closing { window.close() }
    }
    func open(show: ShowController, item: UUID) {
        guard let track = show.current?.tracks.first(where: { $0.clips.contains { $0.id == item && $0.midi != nil } }) else { return }
        if let window = windows[item] { window.title = track.name; ProjectionWindow.presentWorkspaceWindow(window); return }
        let window = NSWindow(contentRect: CGRect(x: 120, y: 160, width: 980, height: 610), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = track.name; window.minSize = CGSize(width: 760,height: 440)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ItemMIDIEditor(show: show, project: show.snapshot.project.id,
            item: item, updateTitle: { [weak window] in window?.title = $0 }, close: { [weak window] in window?.close() }).interfaceScaled())
        InterfaceScaling.shared.register(window)
        windows[item] = window; window.center(); ProjectionWindow.presentWorkspaceWindow(window)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

private struct ItemMIDIEditor: View {
    @ObservedObject var show: ShowController
    let project: UUID
    let item: UUID
    let updateTitle: (String) -> Void
    let close: () -> Void
    var body: some View {
        let transport = show.snapshot.transport
        MIDIEditor(show: show, project: project, item: item,
            cursor: transport.playing ? transport.position : transport.editPosition ?? transport.position, updateTitle: updateTitle, close: close)
    }
}

#endif

struct RecordingPianoPreview: View {
    @ObservedObject private var recorder = TrackRecording.shared
    @ObservedObject private var selectionUpdates: ShowTrackSelectionPresentation
    @State private var manualTime: ManualTime?
    @State private var pitchOffset: Double?
    @State private var cache = PreviewProjectCache()
    @State private var toolbar = ToolbarState()
    let show: ShowController
    let active: Bool

    init(show: ShowController, active: Bool = true) {
        self.show = show
        self.active = active
        _selectionUpdates = ObservedObject(wrappedValue: show.trackSelectionPresentation)
    }

    private let keyboardWidth: CGFloat = 42
    private let rulerHeight: CGFloat = 23
    private let scrollbarSize: CGFloat = 13

    private struct TimeScope: Equatable {
        let song: UUID?
        let playing: Bool
        let session: UUID?
        let pass: Int?
    }
    private struct ManualTime {
        let scope: TimeScope
        let left: Double
        let cursor: Double
    }
    private struct ToolbarState: Equatable {
        var item: UUID?
        var editable = false
    }

    var body: some View {
        MIDIEditor(show: show, project: show.snapshot.project.id, item: toolbar.item,
            previewEditable: toolbar.editable, close: {}, preview: { controls in
                active ? AnyView(playbackGrid(controls)) : AnyView(Color.clear)
            }).accessibilityLabel("MIDI Preview")
    }

    private func playbackGrid(_ controls: MIDIPreviewEditorControls) -> some View {
        TimelinePlaybackLayer(show: show, minimumInterval: 1.0 / 30) { playback in
            let transport = show.timelinePlaybackTransport
            let playing = transport.playing || transport.paused == true
            let cursor = playing ? playback.mainPosition : transport.editPosition ?? transport.position
            let pass = recorder.midiPreviewPass(at: cursor)
            let takes = pass?.currentPassReady == true ? LiveRecordingPreview.shared.takes.values.filter { $0.midiHistory != nil } : []
            let song = show.current
            let item = recorder.recording ? nil : song?.tracks.first { $0.id == show.selectedTrackForActions }?.clips.lazy
                .filter { $0.midi != nil && $0.startTime <= cursor && cursor < $0.startTime + $0.duration }
                .max { $0.startTime < $1.startTime }
            let beat = song.map { meter in
                let section = meter.tempoSection(at: cursor)
                return section.barSeconds / Double(section.beats)
            } ?? 0.5
            let scope = TimeScope(song: transport.songId, playing: playing, session: pass?.session, pass: pass?.index)
            let editable = !playing && !transport.subPlay.playing && !recorder.recording && item?.frozenMIDI != true
            let state = ToolbarState(item: item?.id, editable: editable && item != nil)
            previewGrid(controls, playing: playing, cursor: cursor, song: song, item: item,
                        beat: beat, scope: scope, passStart: pass?.start, recording: recorder.recording,
                        editable: editable, takes: Array(takes))
                // The clock repaints the grid. Controls update at an item or
                // playback-state boundary, keeping the toolbar out of each frame.
                .onAppear { if toolbar != state { toolbar = state } }
                .onChange(of: state) { toolbar = $0 }
        }
    }

    private func previewGrid(_ controls: MIDIPreviewEditorControls, playing: Bool, cursor: Double, song: Song?,
                             item: AudioClip?, beat: Double, scope: TimeScope, passStart: Double?, recording: Bool,
                             editable: Bool, takes: [RecordingPreviewTake]) -> some View {
        let keyHeight = controls.height
        return TimelineCursorAppearance(playback: playing, secondary: false, merged: false) { cursorColor in
                GeometryReader { window in
                    let gridWidth = max(1, window.size.width - scrollbarSize)
                    let gridHeight = max(1, window.size.height - scrollbarSize)
                    let timeSpan = max(1, gridWidth - keyboardWidth) * beat / controls.zoom
                    let center = timeSpan * 0.5
                    let firstTime = playing ? min(cursor, passStart ?? -timeSpan / 2) : -timeSpan / 2
                    let lastTime = max(firstTime + timeSpan, cursor + timeSpan - center, recording ? 0 : song?.duration ?? 0)
                    let maximumLeft = max(firstTime, lastTime - timeSpan)
                    let scroll = manualTime.flatMap {
                        $0.scope == scope && (!playing || cursor + 0.03 >= $0.cursor) ? $0.left : nil
                    }
                    let automaticLeft = playing
                        ? cache.playbackOrigin(scope: scope, cursor: cursor, span: timeSpan)
                        : cursor - center
                    let followLeft = min(maximumLeft, max(firstTime, automaticLeft))
                    let left = min(maximumLeft, max(firstTime, scroll ?? followLeft))
                    let _ = cache.rememberViewport(scope: scope, left: left)
                    let scrollTime: (Double) -> Void = { value in
                        let target = min(maximumLeft, max(firstTime, value))
                        guard abs(target - left) > 0.000001 else { return }
                        manualTime = playing && abs(target - followLeft) < 0.000001 ? nil :
                            ManualTime(scope: scope, left: target, cursor: cursor)
                    }
                    let visibleKeys = min(128, Double(max(1, gridHeight - rulerHeight) / keyHeight))
                    let histories = takes.compactMap(\.midiHistory)
                    let playbackNotes = cache.notes(song: song, item: item, revision: show.projectRevision)
                    let latestPlayback = playbackNotes.last { $0.start <= cursor }.map {
                        RecordedNoteSpan(pitch: $0.pitch, start: $0.start)
                    }
                    let latestNote = histories.compactMap(\.latestNoteOn).max { $0.start < $1.start } ?? (playing ? latestPlayback : nil)
                    let ticks = cache.ticks(song: song, revision: show.projectRevision, left: left, span: timeSpan,
                                            scale: max(1, gridWidth - keyboardWidth) / timeSpan)
                    let preferredPitch = 67 - visibleKeys / 2
                    let topPitch = min(128 - visibleKeys, max(0, pitchOffset ?? preferredPitch))
                    let followNote: (RecordedNoteSpan?) -> Void = { note in
                        guard let note else { return }
                        let row = Double(127 - note.pitch)
                        if row < topPitch + 1 || row + 2 > topPitch + visibleKeys {
                            pitchOffset = min(128 - visibleKeys, max(0, row - visibleKeys / 2))
                        }
                    }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Canvas { context, size in
                                draw(context, size: size, takes: takes, notes: editable && item != nil ? [] : playbackNotes.filter { controls.filter == 0 || $0.channel == controls.filter }, ticks: ticks, left: left, timeSpan: timeSpan,
                                     topPitch: topPitch, cursor: cursor, color: cursorColor, recording: recording, keyHeight: keyHeight)
                            }
                            .overlay {
                                MIDIPreviewInput(controls: controls, clip: editable ? item : nil, segments: editable ? cache.itemSegments : [],
                                    cursor: cursor, left: left, pixelsPerSecond: max(1, gridWidth - keyboardWidth) / timeSpan,
                                    topPitch: topPitch, keys: keyboardWidth, ruler: rulerHeight, zoomAt: { next, x in
                                    if !playing || manualTime != nil {
                                        let anchor = max(0, x - keyboardWidth) * beat
                                        let target = left + anchor * (1 / controls.zoom - 1 / next)
                                        manualTime = ManualTime(scope: scope, left: target, cursor: cursor)
                                    }
                                    controls.changeZoom(next)
                                }, scroll: { delta in
                                    if delta.x != 0 {
                                        scrollTime(left - delta.x * timeSpan / max(1, gridWidth - keyboardWidth))
                                    }
                                    if delta.y != 0 {
                                        pitchOffset = min(128 - visibleKeys, max(0, topPitch - delta.y / keyHeight))
                                    }
                                }, click: { point, flags in
                                    guard point.x >= keyboardWidth, let song = show.current else { return }
                                    let scale = max(1, gridWidth - keyboardWidth) / timeSpan
                                    let time = TimelineTempo.snap(left + (point.x - keyboardWidth) / scale, song: song,
                                        pixelsPerSecond: scale, enabled: TimelineSnapPreference.enabled && !flags.contains(.shift),
                                        includeItemEdges: true)
                                    if !playing {
                                        manualTime = ManualTime(scope: scope, left: left, cursor: time)
                                    }
                                    #if os(macOS)
                                    let editPreference = TimelineEditPreferences.desktop
                                    #else
                                    let editPreference = TimelineEditPreferences.native
                                    #endif
                                    show.send(point.y < rulerHeight ? TimelineEditPreferences.seekCommand(editPreference) : .editSeek, value: time)
                                })
                            }.frame(width: gridWidth, height: gridHeight)
                            MIDIPreviewScrollBar(vertical: true, position: topPitch, first: 0, last: 128,
                                                 visible: visibleKeys, step: 1) { pitchOffset = $0 }
                                .frame(width: scrollbarSize, height: gridHeight)
                        }
                        HStack(spacing: 0) {
                            Color(white: 0.14).frame(width: keyboardWidth, height: scrollbarSize)
                            MIDIPreviewScrollBar(vertical: false, position: left, first: firstTime, last: lastTime,
                                                 visible: timeSpan, step: beat, changed: scrollTime)
                            .frame(width: max(1, gridWidth-keyboardWidth), height: scrollbarSize)
                            Color(white: 0.14).frame(width: scrollbarSize, height: scrollbarSize)
                        }
                    }
                    .onChange(of: scope) { _ in manualTime = nil }
                    .onAppear { followNote(latestNote) }
                    .onChange(of: latestNote, perform: followNote)
                    .onChange(of: cursor) { value in
                        if let manualTime, playing ? value + 0.03 < manualTime.cursor : abs(value - manualTime.cursor) > 0.000001 {
                            self.manualTime = nil
                        }
                    }
                }
        }
    }

    private final class PreviewProjectCache {
        private var identity: UUID?, songID: UUID?, revision: UInt64?
        private(set) var itemSegments: [AudioClip] = []
        private var noteValues: [MIDIPlaybackNote] = []
        private var tempo: [TimelineTempoSection] = []
        private var labels = TimelineTimeRuler.MusicalLabels(sections: [])
        private var viewport: (scope: TimeScope, left: Double)?
        func playbackOrigin(scope: TimeScope, cursor: Double, span: Double) -> Double {
            // Keep the current viewport until the needle reaches its center.
            // A seek or a new recording pass outside it reveals the new position.
            if let viewport, viewport.scope.song == scope.song,
               viewport.scope.session == scope.session, viewport.scope.pass == scope.pass,
               cursor >= viewport.left, cursor < viewport.left + span {
                return max(viewport.left, cursor - span / 2)
            }
            return cursor - span * 0.1
        }
        func rememberViewport(scope: TimeScope, left: Double) {
            viewport = (scope, left)
        }
        private func prepare(_ song: Song?, revision: UInt64) {
            guard songID != song?.id || self.revision != revision else { return }
            identity = nil; songID = song?.id; self.revision = revision
            noteValues = []; tempo = []
        }
        func notes(song: Song?, item: AudioClip?, revision: UInt64) -> [MIDIPlaybackNote] {
            prepare(song, revision: revision)
            guard identity != item?.id else { return noteValues }
            identity = item?.id
            itemSegments = item.flatMap { song?.tempoAudioSegments($0) } ?? []
            if var item, let song {
                item.muted = false; item.gain = 1; item.fadeIn = nil; item.fadeOut = nil
                noteValues = song.midiPlaybackNotes(in: item)
            } else { noteValues = [] }
            return noteValues
        }
        func ticks(song: Song?, revision: UInt64, left: Double, span: Double, scale: Double) -> [TimelineTimeRuler.Tick] {
            prepare(song, revision: revision)
            let end = left + span
            guard let song, end > 0 else { return [] }
            if (tempo.last?.end ?? 0) < end {
                tempo = song.tempoSections(until: max(song.duration, end + 120))
                labels = TimelineTimeRuler.MusicalLabels(sections: tempo)
            }
            return TimelineTimeRuler.ticks(in: tempo, from: max(0, left), to: end,
                                           pixelsPerSecond: scale, divisions: 4, musical: labels)
        }
    }

    private func draw(_ context: GraphicsContext, size: CGSize, takes: [RecordingPreviewTake],
                      notes: [MIDIPlaybackNote], ticks: [TimelineTimeRuler.Tick],
                      left: Double, timeSpan: Double, topPitch: Double,
                      cursor: Double, color: Color, recording: Bool, keyHeight: CGFloat) {
        let width = max(1, size.width - keyboardWidth)
        func x(_ time: Double) -> CGFloat { keyboardWidth + (time - left) * width / timeSpan }
        func y(_ pitch: Int) -> CGFloat { rulerHeight + (Double(127 - pitch) - topPitch) * keyHeight }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.14)))
        var keys = context
        keys.clip(to: Path(CGRect(x: 0, y: rulerHeight, width: size.width, height: max(0, size.height-rulerHeight))))
        let highest = 127 - Int(topPitch)
        let lowest = max(0, highest - Int(ceil(size.height / keyHeight)))
        for pitch in lowest...highest {
            let black = [1, 3, 6, 8, 10].contains(pitch % 12)
            let row = CGRect(x: 0, y: y(pitch), width: size.width, height: keyHeight)
            keys.fill(Path(row), with: .color(Color(white: black ? 0.10 : 0.15)))
            keys.fill(Path(CGRect(x: 0, y: row.minY, width: 40, height: keyHeight-0.5)),
                      with: .color(Color(white: black ? 0.20 : 0.75)))
            if pitch % 12 == 0 {
                keys.draw(Text(verbatim: "C\(pitch/12-1)").font(.system(size: 9)).foregroundColor(.black),
                          at: CGPoint(x: 21, y: row.midY))
            }
        }
        var grid = context
        grid.clip(to: Path(CGRect(x: keyboardWidth, y: 0, width: width, height: size.height)))
        grid.fill(Path(CGRect(x: keyboardWidth, y: 0, width: width, height: rulerHeight)), with: .color(Color(white: 0.105)))
        for tick in ticks {
            let edge = x(tick.time)
            let top = tick.primary ? 0 : rulerHeight - 7
            let bottom = tick.drawsInGrid ? size.height : rulerHeight
            grid.fill(Path(CGRect(x: edge, y: top, width: 1, height: max(0, bottom-top))), with: .color(.white.opacity(tick.primary ? 0.31 : 0.17)))
            if !tick.label.isEmpty {
                grid.draw(Text(verbatim: tick.label).font(.jarasSystem(size: 10, weight: .semibold)).foregroundColor(.white),
                          at: CGPoint(x: edge + 3, y: 2), anchor: .topLeading)
            }
        }
        if !recording {
            var content = grid
            content.clip(to: Path(CGRect(x: keyboardWidth, y: rulerHeight, width: width, height: max(0, size.height-rulerHeight))))
            for note in notes where note.end > left && note.start < left + timeSpan {
                let bounds = CGRect(x: x(note.start), y: y(note.pitch) + 1, width: max(1, x(note.end) - x(note.start)), height: keyHeight - 2)
                content.fill(Path(roundedRect: bounds, cornerRadius: 2), with: .color(JarasTheme.green))
                RecordingPreviewTake.drawNoteLabel(in: &content, rect: bounds, pitch: note.pitch, velocity: note.velocity)
            }
        }
        if recording, cursor >= left {
            var notes = keys
            notes.clip(to: Path(CGRect(x: keyboardWidth, y: rulerHeight, width: width, height: max(0, size.height-rulerHeight))))
            for take in takes {
                take.drawNotes(in: &notes, from: left, to: min(cursor, left+timeSpan), x: x, y: y,
                               height: keyHeight-1, color: JarasTheme.green, labels: true)
            }
        }
        let needle = x(cursor)
        if cursor >= left && cursor <= left+timeSpan {
            grid.fill(Path(CGRect(x: needle-0.75, y: rulerHeight, width: 1.5, height: size.height-rulerHeight)), with: .color(color))
            grid.fill(Path(TimelineNeedleHead.path(centerX: needle, top: 0, tip: rulerHeight)), with: .color(color))
        }
    }
}

private struct MIDIPreviewEditorControls {
    let zoom, height: Double
    let changeZoom, changeHeight: (Double) -> Void
    let velocity, filter: Int
    let selected: Set<UUID>
    let select: (Set<UUID>) -> Void
    let commit: ([MIDINote]) -> Void
    let insertChord: (LibraryMIDIChord) -> Bool
    let undo, redo: () -> Void
}
#if os(macOS)
private struct MIDIPreviewInput: NSViewRepresentable {
    let controls: MIDIPreviewEditorControls
    let clip: AudioClip?
    let segments: [AudioClip]
    let cursor, left, pixelsPerSecond, topPitch: Double
    let keys, ruler: CGFloat
    let zoomAt: (Double, CGFloat) -> Void
    let scroll: (CGPoint) -> Void
    let click: (CGPoint, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.wheelHeight = controls.height
        view.heightChanged = controls.changeHeight
        view.wheelScale = controls.zoom
        view.zoomAt = zoomAt
        view.scroll = scroll
        view.click = click
        if view.previewItem != clip?.id { view.cancelPreviewGesture(); view.previewItem = clip?.id }
        view.isEditable = clip != nil
        view.creationVelocity = controls.velocity
        view.channelFilter = controls.filter
        view.insertChord = controls.insertChord
        view.commit = controls.commit; view.selectionChanged = controls.select
        view.undoEdit = controls.undo; view.redoEdit = controls.redo
        view.previewLayout = .init(left: left, pixelsPerSecond: pixelsPerSecond, topPitch: topPitch, keys: keys, ruler: ruler)
        if let clip {
            view.update(clip: clip, selected: controls.selected, scale: controls.zoom, keyHeight: controls.height,
                        cursor: cursor, width: view.bounds.width, segments: segments)
        }
        view.needsDisplay = true
    }

    final class InputView: MIDIPianoCanvas {
        var previewItem: UUID?
        var wheelHeight = 18.0
        var heightChanged: ((Double) -> Void)?
        var wheelScale = 100.0
        var zoomAt: ((Double, CGFloat) -> Void)?
        private var wheelGesture = MIDIPianoWheelGesture()
        var scroll: ((CGPoint) -> Void)?
        var click: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
        private var canInteract: Bool {
            window?.attachedSheet == nil && !NativeTimelineInputGate.shared.isBlocked(window)
        }

        override func scrollWheel(with event: NSEvent) {
            guard canInteract else { return }
            guard let motion = wheelGesture.motion(for: event) else { return }
            let scale = convert(CGSize(width: 1, height: 1), to: nil)
            switch motion {
            case .height(let factor):
                let range = Self.heightRange
                wheelHeight = min(range.upperBound,max(range.lowerBound,wheelHeight * factor))
                heightChanged?(wheelHeight)
            case .vertical(let delta):
                scroll?(CGPoint(x: 0, y: delta / max(0.01, abs(scale.height))))
            case .horizontal(let delta):
                scroll?(CGPoint(x: delta / max(0.01, abs(scale.width)), y: 0))
            case .zoom(let factor):
                let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, wheelScale * factor))
                guard next != wheelScale else { return }
                wheelScale = next
                zoomAt?(next, convert(event.locationInWindow, from: nil).x)
            }
        }

        private var emptyPress: CGPoint?

        override func mouseDown(with event: NSEvent) {
            emptyPress = nil
            guard canInteract, !event.modifierFlags.contains(.control) else { return }
            let point = convert(event.locationInWindow, from: nil)
            if isEditable, let layout = previewLayout, point.y >= layout.ruler, point.x >= layout.keys {
                if event.clickCount == 1 && !hasNote(at: point) { emptyPress = point }
                super.mouseDown(with: event)
            } else {
                click?(point, event.modifierFlags)
            }
        }
        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let press = emptyPress, hypot(point.x-press.x, point.y-press.y) > 3 { emptyPress = nil }
            super.mouseDragged(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            if let press = emptyPress, isEditable, canInteract { click?(press, event.modifierFlags) }
            emptyPress = nil
        }
        override func draw(_ dirtyRect: NSRect) {
            guard isEditable, let layout = previewLayout else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: bounds.intersection(CGRect(x: layout.keys, y: layout.ruler,
                width: max(0,bounds.width-layout.keys), height: max(0,bounds.height-layout.ruler)))).addClip()
            drawNotes(in: dirtyRect)
        }
    }
}

private struct MIDIPreviewScrollBar: NSViewRepresentable {
    let vertical: Bool
    let position: Double
    let first: Double
    let last: Double
    let visible: Double
    let step: Double
    let changed: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScroller {
        let bar = NSScroller(frame: CGRect(x: 0, y: 0, width: vertical ? 13 : 100, height: vertical ? 100 : 13))
        bar.scrollerStyle = .legacy
        bar.controlSize = .small
        bar.target = context.coordinator
        bar.action = #selector(Coordinator.move(_:))
        bar.setAccessibilityLabel(JarasLocalization.string(vertical ? "MIDI Preview pitch" : "MIDI Preview time"))
        return bar
    }
    func updateNSView(_ bar: NSScroller, context: Context) {
        context.coordinator.control = self
        let total = last-first
        let travel = max(0, total-visible)
        bar.isEnabled = travel > 0.000001
        bar.knobProportion = total > 0 ? min(1, visible/total) : 1
        bar.doubleValue = bar.isEnabled ? min(1, max(0, (position-first)/travel)) : 0
    }
    final class Coordinator: NSObject {
        var control: MIDIPreviewScrollBar
        init(_ control: MIDIPreviewScrollBar) { self.control = control }
        @objc func move(_ bar: NSScroller) {
            let next: Double
            switch bar.hitPart {
            case .decrementLine: next = control.position-control.step
            case .incrementLine: next = control.position+control.step
            case .decrementPage: next = control.position-control.visible
            case .incrementPage: next = control.position+control.visible
            default: next = control.first + bar.doubleValue * (control.last-control.first-control.visible)
            }
            control.changed(max(control.first, min(next, control.last-control.visible)))
        }
    }
}

final class MIDIPreviewVisibility: ObservableObject {
    @Published private(set) var active = false
    func setActive(_ value: Bool) {
        if active != value { active = value }
    }
}

struct DesktopRecordingPianoPreview: View {
    let show: ShowController
    @ObservedObject var visibility: MIDIPreviewVisibility
    var body: some View {
        RecordingPianoPreview(show: show, active: visibility.active)
    }
}

@MainActor final class RecordingPianoWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var detached = false
    var visible: Bool { visibility.active }
    private var panel: NSWindow?
    let visibility = MIDIPreviewVisibility()
    func present(_ show: ShowController) {
        if panel == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "MIDI Preview"
            window.contentMinSize = NSSize(width: 360, height: 200)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: DesktopRecordingPianoPreview(show: show, visibility: visibility).interfaceScaled())
            InterfaceScaling.shared.register(window)
            if !window.setFrameUsingName("CatLiveMIDIPreview") { window.center() }
            window.setFrameAutosaveName("CatLiveMIDIPreview")
            ProjectionWindow.followWorkspaceWindow(window, independent: true)
            panel = window
        }
        if !detached { detached = true }
        visibility.setActive(true)
        if let panel { ProjectionWindow.presentWorkspaceWindow(panel, activates: false) }
    }
    func hide() {
        panel?.orderOut(nil)
        visibility.setActive(false)
    }
    func dock() {
        panel?.delegate = nil; panel?.close(); panel = nil
        visibility.setActive(false)
        if detached { detached = false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}
#endif

private enum MIDIPianoLimits {
    static let zoom = 24.0...360.0
    static let height = 10.0...42.0
}

private struct MIDIEditor: View {
    let show: ShowController
    @ObservedObject private var projectPresentation: ShowProjectPresentation
    let project: UUID
    let item: UUID?
    let updateTitle: ((String) -> Void)?
    let cursor: Double
    let previewEditable: Bool
    let close: () -> Void
    let preview: ((MIDIPreviewEditorControls) -> AnyView)?
    init(show: ShowController, project: UUID, item: UUID?, cursor: Double = 0,
         previewEditable: Bool = false, updateTitle: ((String) -> Void)? = nil, close: @escaping () -> Void,
         preview: ((MIDIPreviewEditorControls) -> AnyView)? = nil) {
        self.show = show
        _projectPresentation = ObservedObject(wrappedValue: show.projectPresentation)
        self.project = project
        self.item = item
        self.updateTitle = updateTitle
        self.cursor = cursor
        self.previewEditable = previewEditable
        self.close = close
        self.preview = preview
    }
    private var followsGrid: Bool { preview != nil }
    private static let emptyPreview = AudioClip(id: UUID(), name: "", startTime: 0, duration: 0, midi: MIDIItem())
    private var editable: Bool {
        guard let clip, clip.frozenMIDI != true, show.canControl(), !TrackRecording.shared.recording else { return false }
        guard followsGrid else { return true }
        guard previewEditable else { return false }
        let t = show.timelinePlaybackTransport, pos = show.timelinePlaybackTransport.editPosition ?? show.timelinePlaybackTransport.position
        return !t.playing && t.paused != true && !t.subPlay.playing && row?.id == show.selectedTrackForActions && clip.startTime <= pos && pos < clip.startTime + clip.duration
    }
    @State private var selected = Set<UUID>()
    @State private var scale = 100.0
    @State private var keyHeight = 18.0
    @State private var zoomMemory: Double?
    @State private var heightMemory: Double?
    @State private var creationVelocity = 100
    @State private var strength = 1.0
    @State private var quantizeLengths = false
    @State private var quantizeOpen = false
    @State private var channel = 0
    private var row: Track? {
        guard let item, let song = show.current else { return nil }
        if followsGrid { return song.tracks.first { $0.id == show.selectedTrackForActions } }
        return song.tracks.first { $0.clips.contains { $0.id == item } }
    }
    private var clip: AudioClip? { row?.clips.first { $0.id == item } }
    private func insertChord(_ chord: LibraryMIDIChord) -> Bool {
        guard editable, let clip, var midi = clip.midi, let song = show.current else { return false }
        let transport = show.timelinePlaybackTransport
        let cursor = transport.editPosition ?? transport.position
        guard cursor >= clip.startTime, cursor < clip.startTime + clip.duration else { return false }
        let section = song.tempoSection(at: cursor)
        let segments = song.tempoAudioSegments(clip)
        func sourceBeat(_ position: Double) -> Double {
            let part = segments.last { $0.startTime <= position } ?? clip
            return (part.sourceOffset + (position - part.startTime) * part.audioRate) * midi.sourceBPM / 60
        }
        let start = sourceBeat(cursor)
        let notes = chord.notes(start: start, length: sourceBeat(cursor + section.barSeconds) - start,
                                velocity: creationVelocity, channel: max(1, channel))
        midi.notes += notes
        show.setMIDIItem(clip.id, midi: midi)
        selected = Set(notes.map(\.id))
        return true
    }

    private func gridBinding<T>(_ key: WritableKeyPath<MIDIGrid,T>, _ fallback: T) -> Binding<T> {
        Binding(get: { clip?.midi?.grid[keyPath: key] ?? fallback }, set: { value in
            guard editable, let item, var midi = clip?.midi else { return }; midi.grid[keyPath:key] = value; show.setMIDIItem(item,midi:midi)
        })
    }
    private func changeScale(_ value: Double) {
        scale = min(MIDIPianoLimits.zoom.upperBound, max(MIDIPianoLimits.zoom.lowerBound, value))
        if scale > MIDIPianoLimits.zoom.lowerBound + 0.000001 { zoomMemory = nil }
    }
    private func changeHeight(_ value: Double) {
        let range = MIDIPianoLimits.height
        keyHeight = min(range.upperBound, max(range.lowerBound, value))
        if keyHeight > range.lowerBound { heightMemory = nil }
    }
    private var zoomControls: some View {
        let zoom = MIDIPianoLimits.zoom, height = MIDIPianoLimits.height
        return DesktopZoomControls(
            height: .init(label: "Note height", toggleLabel: "Toggle note height", id: "piano-note-height",
                          value: Binding(get: { keyHeight }, set: changeHeight), range: height, active: heightMemory != nil, toggle: {
                              if let saved = heightMemory { keyHeight = saved; heightMemory = nil }
                              else if keyHeight > height.lowerBound { heightMemory = keyHeight; keyHeight = height.lowerBound }
                          }),
            time: .init(label: "Piano Roll zoom", toggleLabel: "Toggle Piano Roll zoom", id: "piano-time-zoom",
                        value: Binding(get: { log(scale) }, set: { changeScale(exp($0)) }),
                        range: log(zoom.lowerBound)...log(zoom.upperBound), active: zoomMemory != nil, toggle: {
                            if let saved = zoomMemory { changeScale(saved) }
                            else if scale > zoom.lowerBound { zoomMemory = scale; scale = zoom.lowerBound }
                        }))
    }
    private var creationVelocityControl: some View {
        HStack(spacing: 10) {
            #if os(iOS)
            HStack(spacing: 7) {
                Text(verbatim: "Create Velocity").fixedSize()
                Button { creationVelocity -= 1 } label: {
                    Image(systemName: "minus").frame(width: 29, height: 28).contentShape(Rectangle())
                }.disabled(creationVelocity == 1).accessibilityLabel("Decrease Create Velocity")
                Text("\(creationVelocity)").monospacedDigit().frame(width: 28)
                    .accessibilityLabel(Text(verbatim: "Create Velocity"))
                Button { creationVelocity += 1 } label: {
                    Image(systemName: "plus").frame(width: 29, height: 28).contentShape(Rectangle())
                }.disabled(creationVelocity == 127).accessibilityLabel("Increase Create Velocity")
            }.disabled(!editable)
            #else
            Text(verbatim: "Create Velocity")
            Stepper(value: $creationVelocity, in: 1...127) {
                Text("\(creationVelocity)").monospacedDigit().frame(width: 30)
            }.frame(width: 75).accessibilityLabel(Text(verbatim: "Create Velocity")).disabled(!editable)
            #endif
        }.fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let clip = self.clip ?? (followsGrid ? Self.emptyPreview : nil), let midi = clip.midi {
                let visibleNotes = midi.notes.filter { channel == 0 || $0.channel == channel }
                let visibleSelection = selected.intersection(visibleNotes.map(\.id))
                let quantizeTargets = visibleSelection.isEmpty ? Set(visibleNotes.map(\.id)) : visibleSelection
                let gridControls = HStack(spacing: 12) {
                    Picker("Grade",selection:gridBinding(\.division,16)) { ForEach(MIDIGrid.divisions,id:\.self) { Text($0 == 1 ? "1" : "1/\($0)").tag($0) } }.frame(width:120)
                    Picker("",selection:gridBinding(\.mode,.straight)) { ForEach(MIDIGridMode.allCases,id:\.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width:108)
                    if midi.grid.mode == .swing {
                        Slider(value:gridBinding(\.swing,0.5),in:0...0.95).frame(width:85)
                        Text("\(Int(midi.grid.swing*100))%").monospacedDigit().frame(width:36)
                    }
                    Button("Quantizar…") { quantizeOpen = true }.disabled(visibleNotes.isEmpty).popover(isPresented:$quantizeOpen) {
                        VStack(alignment:.leading,spacing:12) {
                            Text(channel == 0 && visibleSelection.isEmpty ? "Quantizar todas as notas" : "Quantizar \(quantizeTargets.count) notas").font(.jarasHeadline)
                            HStack { Text("Força"); Slider(value:$strength,in:0...1); Text("\(Int(strength*100))%").monospacedDigit().frame(width:38) }
                            Toggle("Quantizar também o final das notas",isOn:$quantizeLengths)
                            HStack { Button("Cancelar") { quantizeOpen = false }; Spacer(); Button("Quantizar") {
                                var next=midi; next.notes=midi.grid.quantize(midi.notes,selected:quantizeTargets,strength:strength,lengths:quantizeLengths)
                                show.setMIDIItem(clip.id,midi:next); quantizeOpen=false
                            }.keyboardShortcut(.defaultAction) }
                        }.padding(16).frame(width:320)
                    }
                }.fixedSize(horizontal: true, vertical: false).disabled(!editable)
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            gridControls
                            creationVelocityControl
                        }.fixedSize(horizontal: true, vertical: false)
                    }.fixedSize(horizontal: false, vertical: true)
                    zoomControls.fixedSize(horizontal: true, vertical: false)
                }.padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                if let preview {
                    preview(.init(zoom: scale, height: keyHeight, changeZoom: changeScale, changeHeight: changeHeight, velocity: creationVelocity, filter: channel,
                                  selected: selected, select: { selected = $0 }, commit: { notes in
                        guard editable, let current = self.clip, current.id == clip.id, var value = current.midi else { return }
                        value.notes = notes; show.setMIDIItem(current.id, midi: value)
                    }, insertChord: insertChord, undo: { show.undo() }, redo: { show.redo() }))
                } else {
                #if os(macOS)
                MIDIPianoRoll(clip: clip, selected: $selected, scale: scale, keyHeight: keyHeight, creationVelocity: creationVelocity,
                    channel: max(1, channel), channelFilter: channel, zoomChanged: changeScale, heightChanged: changeHeight,
                    cursor: cursor,
                    followsGrid: followsGrid, enabled: show.canControl() && !TrackRecording.shared.recording,
                    segments:show.current?.tempoAudioSegments(clip) ?? [clip],
                    commit:{ notes in var next=midi; next.notes=notes; show.setMIDIItem(clip.id,midi:next) },
                    insertChord: insertChord, seek:{ show.send(show.snapshot.transport.playing ? .seek : .editSeek,value:$0) },
                    undo:{ show.undo() },redo:{ show.redo() })
                    .jarasHelp("Click the ruler to set the playback position")
                #endif
                }
                HStack(spacing:10) {
                    #if os(macOS)
                    Text("Shift: mover e redimensionar sem encaixe").foregroundStyle(JarasTheme.secondary)
                    #endif
                    Spacer()
                    Text("Velocity")
                    SelectedVelocityControl(notes: visibleNotes, selection: visibleSelection) { value in
                        guard editable, var next = self.clip?.midi, !visibleSelection.isEmpty else { return }
                        for i in next.notes.indices where visibleSelection.contains(next.notes[i].id) {
                            next.notes[i].velocity = value
                        }
                        show.setMIDIItem(clip.id, midi: next)
                    }.disabled(visibleSelection.isEmpty)
                    Picker(selection:$channel) {
                        Text(verbatim:JarasLocalization.string("All channels")).tag(0)
                        ForEach(1...16,id:\.self) { Text("\($0)").tag($0) }
                    } label: { Text(verbatim:JarasLocalization.string("Channel")) }
                        .frame(width:132).jarasHelp("Show notes from all channels or only the selected channel")
                    Text(channel == 0 ? "\(midi.notes.count) notas" : "\(visibleNotes.count)/\(midi.notes.count) notas").foregroundStyle(JarasTheme.secondary)
                }.font(.jarasCaption).padding(10).disabled(!editable)
            } else { Text("O item MIDI foi removido.").padding(); Button("Fechar",action:close) }
        }.background(JarasTheme.background).foregroundStyle(JarasTheme.text)
            .onChange(of: updateTitle == nil ? nil : row?.name) { name in
                if let name { updateTitle?(name) }
            }
            .onChange(of:item) { _ in selected.removeAll(); quantizeOpen = false }
            .onChange(of:channel) { value in
                selected.formIntersection((clip?.midi?.notes ?? []).filter { value == 0 || $0.channel == value }.map(\.id))
            }
            .onChange(of:show.snapshot.project.id) { if $0 != project { close() } }
    }
}

private struct SelectedVelocityControl: View {
    let notes: [MIDINote]
    let selection: Set<UUID>
    let set: (Int) -> Void
    @FocusState private var typing: Bool
    @State private var draft = ""
    @State private var editingSelection = Set<UUID>()

    var body: some View {
        let selected = notes.lazy.filter { selection.contains($0.id) }
        let first = selected.first?.velocity ?? 100
        let mixed = selected.contains { $0.velocity != first }
        let reference = mixed ? min(126, max(2, first)) : first
        let display = selection.isEmpty || mixed ? "-" : String(reference)
        HStack(spacing: 3) {
            TextField("", text: Binding(get: { typing ? draft : display }, set: { draft = $0 }))
                .accessibilityLabel(Text(verbatim: "Velocity"))
                .focused($typing).monospacedDigit().multilineTextAlignment(.center).frame(width: 38)
                .onChange(of: typing) { focused in
                    if focused { draft = display; editingSelection = selection }
                    else if editingSelection == selection, let value = Int(draft), (1...127).contains(value), mixed || value != reference { set(value) }
                }
                .onSubmit { typing = false }
            Stepper("", value: Binding(get: { reference }, set: { value in
                draft = String(value)
                set(value)
            }), in: 1...127).labelsHidden().accessibilityLabel(Text(verbatim: "Velocity"))
        }
        .onChange(of: selection) { _ in draft = display; typing = false }
    }
}

#if os(macOS)
private struct MIDIPianoRoll: NSViewRepresentable {
    let clip: AudioClip
    @Binding var selected: Set<UUID>
    let scale: Double
    let keyHeight: Double
    let creationVelocity: Int
    let channel: Int
    let channelFilter: Int
    let zoomChanged, heightChanged: (Double) -> Void
    let cursor: Double
    let followsGrid: Bool
    let enabled: Bool
    let segments: [AudioClip]
    let commit: ([MIDINote]) -> Void
    let insertChord: (LibraryMIDIChord) -> Bool
    let seek: (Double) -> Void
    let undo: () -> Void
    let redo: () -> Void
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=MIDIPianoScrollView(); scroll.hasHorizontalScroller=true; scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true
        scroll.backgroundColor=NSColor(JarasTheme.background); scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        let canvas=MIDIPianoCanvas(); scroll.documentView=canvas
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let canvas=scroll.documentView as? MIDIPianoCanvas else{return}
        (scroll as? MIDIPianoScrollView)?.zoomChanged = zoomChanged
        (scroll as? MIDIPianoScrollView)?.heightChanged = heightChanged
        let previousScale = canvas.scale, previousHeight = canvas.keyHeight, previousCursor = canvas.cursorBeat
        let origin = scroll.contentView.bounds.origin
        canvas.followsGrid = followsGrid
        canvas.insertChord = insertChord
        canvas.commit=commit; canvas.selectionChanged={ selected=$0 };canvas.undoEdit=undo;canvas.redoEdit=redo;canvas.seek=seek
        canvas.creationVelocity = creationVelocity
        canvas.channel=channel;canvas.channelFilter=channelFilter;canvas.isEditable=enabled
        canvas.update(clip:clip,selected:selected,scale:scale,keyHeight:keyHeight,cursor:cursor,width:scroll.contentSize.width,segments:segments)
        if canvas.initialScroll, (previousScale != canvas.scale || previousHeight != canvas.keyHeight) {
            let target = canvas.rescaledOrigin(origin, viewportHeight: scroll.contentSize.height,
                                               previousScale: previousScale, previousHeight: previousHeight)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(
                CGRect(origin: target, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if followsGrid && (previousCursor != canvas.cursorBeat || !canvas.initialScroll) {
            (scroll as? MIDIPianoScrollView)?.centerGridCursor()
        }
        if !canvas.initialScroll, let scroll=scroll as? MIDIPianoScrollView {
            let pitches=canvas.visibleNotes.map(\.pitch)
            scroll.initialPitch=CGFloat((pitches.min() ?? 60)+(pitches.max() ?? 60))/2
            scroll.needsLayout=true
        }
    }
}

/// Wait for the actual viewport before centering; SwiftUI's first update can be zero-sized.
private final class MIDIPianoScrollView: NSScrollView {
    var initialPitch: CGFloat?
    var zoomChanged, heightChanged: ((Double) -> Void)?
    private var wheelGesture = MIDIPianoWheelGesture()
    override func scrollWheel(with event: NSEvent) {
        guard let canvas = documentView as? MIDIPianoCanvas, let motion = wheelGesture.motion(for: event) else { return }
        var origin = contentView.bounds.origin
        switch motion {
        case .height(let factor):
            let old = canvas.keyHeight, range = MIDIPianoLimits.height
            let next = min(range.upperBound,max(range.lowerBound,old * factor))
            guard next != old else { return }
            canvas.keyHeight = next
            origin = canvas.rescaledOrigin(origin, viewportHeight: contentSize.height, previousScale: canvas.scale, previousHeight: old)
            canvas.setZoom(canvas.scale, viewportWidth: contentSize.width)
            heightChanged?(next)
        case .vertical(let delta): origin.y -= delta
        case .horizontal(let delta): origin.x -= delta
        case .zoom(let factor):
            let point = canvas.convert(event.locationInWindow, from: nil)
            let anchor = max(point.x, origin.x + canvas.keyboardWidth) - canvas.keyboardWidth - canvas.horizontalPadding
            let old = canvas.scale
            let next = min(MIDIPianoLimits.zoom.upperBound, max(MIDIPianoLimits.zoom.lowerBound, old * factor))
            guard next != old else { return }
            origin.x += anchor * (next / old - 1)
            canvas.setZoom(next, viewportWidth: contentSize.width)
            zoomChanged?(next)
        }
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }
    private var followsGridCursor: Bool { (documentView as? MIDIPianoCanvas)?.followsGrid == true }
    func centerGridCursor() {
        guard let canvas = documentView as? MIDIPianoCanvas, contentSize.width > canvas.keyboardWidth else { return }
        let target = CGPoint(x: canvas.cursorBeat * canvas.scale, y: contentView.bounds.minY)
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: target, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
    }
    private var drawnBounds=CGRect.null
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if drawnBounds != clipView.bounds {
            drawnBounds=clipView.bounds
            documentView?.needsDisplay=true // Keyboard/ruler stay pinned while content scrolls.
        }
    }
    override func layout() {
        super.layout()
        guard let pitch=initialPitch, contentSize.height>40,
              let canvas=documentView as? MIDIPianoCanvas, !canvas.initialScroll else { return }
        initialPitch=nil; canvas.initialScroll=true
        let center=canvas.rulerHeight+(127-pitch)*canvas.keyHeight+canvas.keyHeight/2
        contentView.scroll(to: CGPoint(x: followsGridCursor ? contentView.bounds.origin.x : 0, y: max(0,center-contentSize.height/2)))
        if followsGridCursor { centerGridCursor() }
        reflectScrolledClipView(contentView)
        canvas.needsDisplay=true
    }
}

private struct MIDIPianoWheelGesture {
    enum Motion { case vertical(CGFloat), horizontal(CGFloat), zoom(Double), height(Double) }
    private enum Axis { case horizontal, vertical, zoom, height }
    private var axis: Axis?

    mutating func motion(for event: NSEvent) -> Motion? {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || !gesture { axis = nil }
        guard dx != 0 || dy != 0 else { return nil }
        let horizontal = abs(dx) > abs(dy)
        let direction = axis ?? (event.modifierFlags.contains(.option) ? .vertical :
            event.modifierFlags.contains(.command) ? .height :
            event.modifierFlags.contains(.shift) || NSEvent.pressedMouseButtons & 1 != 0 || horizontal ? .horizontal : .zoom)
        if gesture { axis = direction }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
        switch direction {
        case .vertical: return .vertical(dy * step)
        case .horizontal: return .horizontal((horizontal ? dx : dy) * step)
        case .height, .zoom:
            guard event.momentumPhase.isEmpty else { return nil }
            let sensitivity = event.hasPreciseScrollingDeltas ? TimelineZoomLimits.preciseSensitivity : TimelineZoomLimits.wheelSensitivity
            let factor = exp(dy * sensitivity)
            return direction == .height ? .height(factor) : .zoom(factor)
        }
    }
}

/// A single native canvas: dragging notes never rebuilds a SwiftUI view tree.
class MIDIPianoCanvas: NSView {
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
    static let zoomRange = MIDIPianoLimits.zoom
    static let heightRange = MIDIPianoLimits.height
    let keyboardWidth: CGFloat = 64, rulerHeight: CGFloat = 24
    fileprivate(set) var keyHeight: CGFloat = 18
    var initialScroll=false
    var isEditable=true
    var creationVelocity = 100, channel=1
    var channelFilter=0 {
        didSet {
            guard channelFilter != oldValue else { return }
            if edit != nil { notes=originals;edit=nil;box=nil }
            selected.formIntersection(visibleNotes.map(\.id));needsDisplay=true
        }
    }
    var insertChord: (LibraryMIDIChord) -> Bool = { _ in false }
    private static let chordType = NSPasteboard.PasteboardType(LibraryMIDIChord.transferType)
    private var hoverCursor: NSCursor?
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        releaseHoverCursor()
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([Self.chordType])
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(releaseHoverCursor),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable, sender.draggingPasteboard.availableType(from: [Self.chordType]) != nil else { return [] }
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, let data = sender.draggingPasteboard.data(forType: Self.chordType),
              let name = String(data: data, encoding: .utf8),
              let chord = LibraryMIDIChord.catalog.first(where: { $0.name == name }) else { return false }
        return insertChord(chord)
    }
    var commit:([MIDINote])->Void={_ in}
    var seek:(Double)->Void={_ in}
    var selectionChanged:(Set<UUID>)->Void={_ in}
    var undoEdit:()->Void={}, redoEdit:()->Void={}
    private(set) var notes:[MIDINote]=[]
    var visibleNotes:[MIDINote] { channelFilter == 0 ? notes : notes.filter { $0.channel == channelFilter } }
    private(set) var scale: CGFloat = 100
    private var endBeat = 0.0
    private var selected=Set<UUID>(), grid=MIDIGrid(), sourceStart=0.0, sourceEnd=16.0
    private(set) var cursorBeat = 0.0
    var followsGrid = false
    private(set) var horizontalPadding: CGFloat = 0
    private var beatOrigin: CGFloat { keyboardWidth + horizontalPadding }
    private var dragOrigin=CGPoint.zero, originals:[MIDINote]=[], edit:Edit?, box:CGRect?
    private var sourceBPM=120.0, playbackSegments:[AudioClip]=[]
    private var rulerPress:CGPoint?, rulerDragged=false
    private enum Edit { case create(UUID),move(UUID),left(UUID),right(UUID),select }
    func update(clip:AudioClip,selected:Set<UUID>,scale:Double,keyHeight:Double = 18,cursor:Double,width:CGFloat,segments:[AudioClip] = []) {
        guard let midi=clip.midi else{return}
        if edit == nil { notes=midi.notes; self.selected=selected.intersection(visibleNotes.map(\.id)) }
        self.keyHeight = keyHeight
        grid=midi.grid
        sourceBPM=midi.sourceBPM;playbackSegments=segments.isEmpty ? [clip] : segments
        sourceStart=clip.sourceOffset*midi.sourceBPM/60
        sourceEnd=sourceStart+clip.duration*clip.audioRate*midi.sourceBPM/60
        cursorBeat=sourceStart+(cursor-clip.startTime)*clip.audioRate*midi.sourceBPM/60
        if let last=segments.last { sourceEnd=(last.sourceOffset+last.duration*last.audioRate)*midi.sourceBPM/60 }
        if let active=segments.last(where:{$0.startTime<=cursor}) ?? segments.first {
            cursorBeat=(active.sourceOffset+(cursor-active.startTime)*active.audioRate)*midi.sourceBPM/60
        }
        endBeat=max(sourceEnd,midi.notes.map(\.end).max() ?? 0)
        if previewLayout != nil { self.scale = scale; needsDisplay = true }
        else { setZoom(scale, viewportWidth: width) }
    }
    func setZoom(_ value: CGFloat, viewportWidth: CGFloat) {
        scale = value
        horizontalPadding = followsGrid ? max(0, viewportWidth - keyboardWidth) / 2 : 0
        setFrameSize(CGSize(width: max(viewportWidth, beatOrigin + CGFloat(endBeat + 4) * scale + horizontalPadding),
                            height: 128 * keyHeight + rulerHeight))
        needsDisplay=true
    }
    func rescaledOrigin(_ origin: CGPoint, viewportHeight: CGFloat, previousScale: CGFloat, previousHeight: CGFloat) -> CGPoint {
        let center = max(0, viewportHeight - rulerHeight) / 2
        return CGPoint(x: origin.x * scale / previousScale, y: (origin.y + center) * keyHeight / previousHeight - center)
    }
    private func point(_ event:NSEvent)->CGPoint { convert(event.locationInWindow,from:nil) }
    struct PreviewLayout {
        let left, pixelsPerSecond, topPitch, keys, ruler: CGFloat
    }
    var previewLayout: PreviewLayout?
    func cancelPreviewGesture() { edit = nil; box = nil; selected.removeAll(); originals = []; notes = [] }
    private func beat(_ p:CGPoint)->Double {
        guard let v = previewLayout else { return max(0,Double((p.x-beatOrigin)/scale)) }
        let time = v.left + (p.x-v.keys)/v.pixelsPerSecond
        guard let segment = playbackSegments.last(where: { $0.startTime <= time }) ?? playbackSegments.first else { return 0 }
        return max(0,(segment.sourceOffset + (time-segment.startTime)*segment.audioRate)*sourceBPM/60)
    }
    private func pitch(_ p:CGPoint)->Int {
        let row = (p.y - (previewLayout?.ruler ?? rulerHeight))/keyHeight + (previewLayout?.topPitch ?? 0)
        return min(127,max(0,127-Int(floor(row))))
    }
    func hasNote(at point: CGPoint) -> Bool { visibleNotes.contains { rect($0).contains(point) } }
    private func rect(_ n:MIDINote)->CGRect {
        guard let v = previewLayout else { return CGRect(x:beatOrigin+CGFloat(n.start)*scale,y:rulerHeight+CGFloat(127-n.pitch)*keyHeight+1,width:max(2,CGFloat(n.length)*scale),height:keyHeight-2) }
        func x(_ beat: Double) -> Double {
            let source = beat*60/sourceBPM
            guard let seg = playbackSegments.last(where: { $0.sourceOffset <= source }) ?? playbackSegments.first else { return v.keys }
            return v.keys + (seg.startTime+(source-seg.sourceOffset)/seg.audioRate-v.left)*v.pixelsPerSecond
        }
        let start = x(n.start)
        return CGRect(x: start, y: v.ruler+(Double(127-n.pitch)-v.topPitch)*keyHeight+1,
                      width: max(2,x(n.end)-start), height: keyHeight-2)
    }
    private var rulerRect:CGRect { CGRect(x:visibleRect.minX+keyboardWidth,y:visibleRect.minY,width:max(0,visibleRect.width-keyboardWidth),height:rulerHeight) }
    private func seekFromRuler(_ point:CGPoint,free:Bool) {
        guard let first=playbackSegments.first,let last=playbackSegments.last,sourceBPM>0 else{return}
        let source=grid.snap(beat(point),bypass:free)*60/sourceBPM
        let bounded=min(last.sourceOffset+last.duration*last.audioRate,max(first.sourceOffset,source))
        guard let segment=playbackSegments.last(where:{$0.sourceOffset<=bounded}) ?? playbackSegments.first,
              segment.audioRate>0 else{return}
        let position=min(segment.startTime+segment.duration,max(segment.startTime,segment.startTime+(bounded-segment.sourceOffset)/segment.audioRate))
        guard position.isFinite else{return}
        cursorBeat=bounded*sourceBPM/60;seek(position);needsDisplay=true
    }
    private static var noteLabels = [Int: (NSAttributedString, CGFloat)]()
    private static func label(for note: MIDINote) -> (NSAttributedString, CGFloat) {
        let key = note.pitch * 128 + note.velocity
        if let cached = noteLabels[key] { return cached }
        let text = NSAttributedString(string: MIDINote.label(pitch: note.pitch, velocity: note.velocity),
            attributes: [.font: NSFont.jarasSystemFont(ofSize: 10), .foregroundColor: NSColor.black])
        let result = (text, ceil(text.size().width))
        noteLabels[key] = result
        return result
    }
    func drawNotes(in visible: CGRect) {
        for note in visibleNotes {let r=rect(note);guard r.intersects(visible) else{continue}
            NSColor(JarasTheme.green).withAlphaComponent(selected.contains(note.id) ? 1:0.55+Double(note.velocity)/127*0.25).setFill()
            NSBezierPath(roundedRect:r,xRadius:2,yRadius:2).fill()
            if selected.contains(note.id) {NSColor.white.setStroke();let border=NSBezierPath(rect:r.insetBy(dx:0.5,dy:0.5));border.lineWidth=1;border.stroke()}
            let (label, width) = Self.label(for: note)
            if r.width >= width + 6, r.height >= 11 { label.draw(at: CGPoint(x: r.minX + 3, y: r.midY - label.size().height / 2)) }
        }
        if previewLayout != nil, let box { NSColor(JarasTheme.green).withAlphaComponent(0.18).setFill(); box.fill() }
    }
    override func draw(_ dirtyRect:NSRect) {
        let visible=visibleRect
        NSColor(JarasTheme.background).setFill();dirtyRect.fill()
        let first=max(0,Int((visible.minY-rulerHeight)/keyHeight)),last=min(127,Int((visible.maxY-rulerHeight)/keyHeight))
        if first<=last {for row in first...last {
            let note=127-row,black=[1,3,6,8,10].contains(note%12), y=rulerHeight+CGFloat(row)*keyHeight
            NSColor(white:black ? 0.105:0.145,alpha:1).setFill();CGRect(x:keyboardWidth,y:y,width:bounds.width-keyboardWidth,height:keyHeight).fill()
            NSColor(white:note%12==0 ? 0.32:0.20,alpha:1).setFill();CGRect(x:keyboardWidth,y:y+keyHeight-0.5,width:bounds.width-keyboardWidth,height:0.5).fill()
        }}
        let a=max(0,Int(beat(CGPoint(x:visible.minX,y:0))/grid.step)-2),b=max(a,Int(beat(CGPoint(x:visible.maxX,y:0))/grid.step)+2)
        let strideValue=max(1,Int(ceil(4/(grid.step*Double(scale)))))
        for i in stride(from:a,through:b,by:strideValue) {
            let beat=grid.line(i),x=beatOrigin+CGFloat(beat)*scale
            let bar=abs(beat/4-(beat/4).rounded())<0.000001
            NSColor(JarasTheme.green).withAlphaComponent(bar ? 0.48:0.18).setFill()
            CGRect(x:x,y:visible.minY,width:bar ? 1:0.5,height:visible.height).fill()
        }
        drawNotes(in: visible)
        // Trim boundaries and transport cursor share the same source transform.
        for (value,color) in [(sourceStart,NSColor.yellow),(sourceEnd,NSColor.yellow),(cursorBeat,NSColor(JarasTheme.green))] {
            let x=beatOrigin+CGFloat(value)*scale;color.setFill();CGRect(x:x,y:visible.minY,width:1,height:visible.height).fill()
        }
        if let box {NSColor(JarasTheme.green).withAlphaComponent(0.15).setFill();box.fill();NSColor(JarasTheme.green).setStroke();NSBezierPath(rect:box).stroke()}
        // Pin keyboard and ruler inside the native scroll viewport.
        NSColor(white:0.12,alpha:1).setFill();CGRect(x:visible.minX,y:visible.minY,width:keyboardWidth,height:visible.height).fill()
        if first<=last {for row in first...last {
            let note=127-row,black=[1,3,6,8,10].contains(note%12),y=rulerHeight+CGFloat(row)*keyHeight
            NSColor(white:black ? 0.10:0.78,alpha:1).setFill();CGRect(x:visible.minX,y:y,width:keyboardWidth-1,height:keyHeight-1).fill()
            if note%12==0 && keyHeight >= 13 {("C\(note/12-1)" as NSString).draw(at:CGPoint(x:visible.minX+32,y:y+(keyHeight-13)/2),withAttributes:[.font:NSFont.jarasSystemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.black])}
        }}
        NSColor(white:0.09,alpha:1).setFill();CGRect(x:visible.minX,y:visible.minY,width:visible.width,height:rulerHeight).fill()
        let firstBeat=max(0,Int(beat(CGPoint(x:visible.minX+keyboardWidth,y:0))/4)*4)
        for value in stride(from:firstBeat,through:Int(beat(CGPoint(x:visible.maxX,y:0)))+4,by:4) {
            let x=beatOrigin+CGFloat(value)*scale
            if x>=visible.minX+keyboardWidth {("\(value/4+1)" as NSString).draw(at:CGPoint(x:x+3,y:visible.minY+5),withAttributes:[.font:NSFont.jarasMonospacedSystemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor(JarasTheme.green)])}
        }
        let cursorX=beatOrigin+CGFloat(cursorBeat)*scale
        if cursorX>=rulerRect.minX,cursorX<=rulerRect.maxX {
            NSColor(JarasTheme.green).setFill()
            let head=NSBezierPath();head.move(to:CGPoint(x:cursorX-5,y:visible.minY));head.line(to:CGPoint(x:cursorX+5,y:visible.minY));head.line(to:CGPoint(x:cursorX,y:visible.minY+7));head.close();head.fill()
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard isEditable else { return }
        window?.makeFirstResponder(self)
        let p=point(event)
        if previewLayout == nil && rulerRect.contains(p) { rulerPress=p;rulerDragged=false;return }
        guard p.x>=visibleRect.minX+(previewLayout?.keys ?? keyboardWidth),p.y>=visibleRect.minY+(previewLayout?.ruler ?? rulerHeight) else{return}
        dragOrigin=p; originals=notes
        if let n=visibleNotes.reversed().first(where:{rect($0).contains(p)}) {
            if event.modifierFlags.contains(.command) {if selected.contains(n.id){selected.remove(n.id)}else{selected.insert(n.id)}}
            else if !selected.contains(n.id) {selected=[n.id]}
            let r=rect(n),edge=min(6,r.width/3)
            edit=p.x<=r.minX+edge ? .left(n.id):p.x>=r.maxX-edge ? .right(n.id):.move(n.id)
        } else if event.clickCount == 2 {
            if previewLayout != nil && !(sourceStart..<max(sourceStart,sourceEnd)).contains(beat(p)) { return }
            let n=MIDINote(start:grid.snap(beat(p),bypass:event.modifierFlags.contains(.shift)),length:grid.step,pitch:pitch(p),velocity:creationVelocity,channel:channelFilter == 0 ? channel : channelFilter)
            notes.append(n);selected=[n.id];edit = .create(n.id)
        } else {
            selected.removeAll(); edit = .select
        }
        selectionChanged(selected);needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent) {
        if let press=rulerPress {
            let p=point(event)
            if abs(p.x-press.x)>3 || abs(p.y-press.y)>3 { rulerDragged=true }
            return
        }
        guard let edit else{return};autoscroll(with:event)
        let p=point(event),free=event.modifierFlags.contains(.shift),minimum=1.0/960
        switch edit {
        case .create(let id):
            if let i=notes.firstIndex(where:{$0.id==id}) {notes[i].length=max(minimum,grid.snap(beat(p),bypass:free)-notes[i].start);notes[i].pitch=pitch(p)}
        case .move(let id),.left(let id),.right(let id):
            guard let anchor=originals.first(where:{$0.id==id}) else{return}
            let raw = previewLayout == nil ? Double((p.x-dragOrigin.x)/scale) : beat(p)-beat(dragOrigin)
            let isRight:Bool;if case .right=edit {isRight=true}else{isRight=false}
            let base=isRight ? anchor.end:anchor.start
            var delta=grid.snap(base+raw,bypass:free)-base
            let chosen=originals.filter{selected.contains($0.id)}
            if case .move=edit {
                delta=max(delta,-(chosen.map(\.start).min() ?? 0))
                let pitchDelta=min(127-(chosen.map(\.pitch).max() ?? 127),max(-(chosen.map(\.pitch).min() ?? 0),pitch(p)-pitch(dragOrigin)))
                notes=originals.map { n in var v=n;if selected.contains(n.id){v.start+=delta;v.pitch+=pitchDelta};return v }
            } else if case .left=edit {
                delta=max(-(chosen.map(\.start).min() ?? 0),min(delta,(chosen.map(\.length).min() ?? 0)-minimum))
                notes=originals.map { n in var v=n;if selected.contains(n.id){v.start+=delta;v.length-=delta};return v }
            } else {
                delta=max(delta,minimum-(chosen.map(\.length).min() ?? minimum))
                notes=originals.map { n in var v=n;if selected.contains(n.id){v.length+=delta};return v }
            }
        case .select:
            box=CGRect(x:min(p.x,dragOrigin.x),y:min(p.y,dragOrigin.y),width:abs(p.x-dragOrigin.x),height:abs(p.y-dragOrigin.y))
            selected=Set(visibleNotes.filter{rect($0).intersects(box!)}.map(\.id));selectionChanged(selected)
        }
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        if let press=rulerPress {
            defer { rulerPress=nil;rulerDragged=false }
            let p=point(event)
            if isEditable,!rulerDragged,abs(p.x-press.x)<=3,abs(p.y-press.y)<=3,rulerRect.contains(p) {
                seekFromRuler(p,free:event.modifierFlags.contains(.shift))
            }
            return
        }
        if edit != nil,notes != originals {commit(notes)};edit=nil;box=nil;needsDisplay=true
    }
    override func rightMouseDown(with event:NSEvent) {
        let p=point(event)
        guard isEditable,p.x>=visibleRect.minX+keyboardWidth,p.y>=visibleRect.minY+rulerHeight else{return}
        window?.makeFirstResponder(self);dragOrigin=p;originals=notes;edit = .select;selected=[];selectionChanged(selected)
    }
    override func rightMouseDragged(with event:NSEvent) {mouseDragged(with:event)}
    override func rightMouseUp(with event:NSEvent) {edit=nil;box=nil;needsDisplay=true}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }
    func pointerCursor(at point: CGPoint) -> NSCursor {
        let area = visibleRect
        let keys = previewLayout?.keys ?? keyboardWidth
        guard area.contains(point), point.x >= area.minX + keys else { return .arrow }
        let ruler = previewLayout?.ruler ?? rulerHeight
        if point.y < area.minY + ruler { return .pointingHand }
        guard isEditable else { return .arrow }
        guard let note = visibleNotes.reversed().first(where: { rect($0).contains(point) }) else { return .crosshair }
        let noteRect = rect(note)
        let edge = min(6, noteRect.width / 3)
        return point.x <= noteRect.minX + edge || point.x >= noteRect.maxX - edge ? .resizeLeftRight : .openHand
    }
    private func updateHoverCursor(_ event: NSEvent) {
        guard window?.isKeyWindow == true, window?.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor, !NativeTimelineInputGate.shared.isBlocked(window) else {
            releaseHoverCursor()
            return
        }
        let location = point(event)
        guard visibleRect.contains(location) else {
            releaseHoverCursor()
            return
        }
        let cursor = pointerCursor(at: location)
        hoverCursor = cursor
        if NSCursor.current !== cursor { cursor.set() }
    }
    @objc private func releaseHoverCursor() {
        if let hoverCursor, hoverCursor !== NSCursor.arrow, NSCursor.current === hoverCursor {
            NSCursor.arrow.set()
        }
        hoverCursor = nil
    }
    override func cursorUpdate(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateHoverCursor(event) }
    override func mouseExited(with event: NSEvent) { releaseHoverCursor() }
    override func keyDown(with event:NSEvent) {
        guard isEditable else { return }
        if event.keyCode==51 || event.keyCode==117 {
            let before=notes
            notes.removeAll{selected.contains($0.id) && (channelFilter == 0 || $0.channel == channelFilter)}
            selected=[];selectionChanged(selected);if notes != before {commit(notes)};needsDisplay=true;return
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":selected=Set(visibleNotes.map(\.id));selectionChanged(selected);needsDisplay=true;return
            case "z":if event.modifierFlags.contains(.shift){redoEdit()}else{undoEdit()};return
            default:break
            }
        }
        if event.keyCode==53,rulerPress != nil {rulerPress=nil;rulerDragged=false;return}
        if event.keyCode==53, edit != nil {notes=originals;edit=nil;box=nil;needsDisplay=true;return}
        super.keyDown(with:event)
    }
}
#endif

#if os(iOS)
private struct MIDIPreviewInput: View {
    let controls: MIDIPreviewEditorControls
    let clip: AudioClip?
    let segments: [AudioClip]
    let cursor, left, pixelsPerSecond, topPitch: Double
    let keys, ruler: CGFloat
    let zoomAt: (Double, CGFloat) -> Void
    let scroll: (CGPoint) -> Void
    let click: (CGPoint, UIKeyModifierFlags) -> Void

    @State private var gesture: NoteDrag?
    @State private var panOffset = CGSize.zero
    @GestureState private var pinchScale: CGFloat = 1

    private struct NoteDrag {
        enum Edge { case move, start, end }
        let original: [MIDINote]
        var draft: [MIDINote]
        let selection: Set<UUID>
        let anchor: MIDINote
        let edge: Edge
    }

    private var notes: [MIDINote] {
        (gesture?.draft ?? clip?.midi?.notes ?? []).filter { controls.filter == 0 || $0.channel == controls.filter }
    }
    private func time(at x: CGFloat) -> Double { left + (x - keys) / pixelsPerSecond }
    private func sourceBeat(at time: Double) -> Double {
        guard let segment = segments.last(where: { $0.startTime <= time }) ?? clip,
              let midi = clip?.midi else { return 0 }
        return (segment.sourceOffset + (time - segment.startTime) * segment.audioRate) * midi.sourceBPM / 60
    }
    private func x(for beat: Double) -> CGFloat {
        guard let midi = clip?.midi else { return keys }
        let source = beat * 60 / midi.sourceBPM
        guard let segment = segments.last(where: { $0.sourceOffset <= source }) ?? clip else { return keys }
        return keys + (segment.startTime + (source - segment.sourceOffset) / segment.audioRate - left) * pixelsPerSecond
    }
    private func pitch(at y: CGFloat) -> Int {
        min(127, max(0, 127 - Int(floor((y - ruler) / controls.height + topPitch))))
    }
    private func noteRect(_ note: MIDINote) -> CGRect {
        let xStart = x(for: note.start)
        return CGRect(x: xStart, y: ruler + (Double(127 - note.pitch) - topPitch) * controls.height + 1,
                      width: max(2, x(for: note.end) - xStart), height: controls.height - 2)
    }
    private func hit(_ location: CGPoint) -> MIDINote? {
        guard location.x >= keys, location.y >= ruler else { return nil }
        return notes.last { noteRect($0).contains(location) }
    }
    private func tap(_ location: CGPoint, count: Int) {
        guard location.x >= keys else { return }
        guard count == 2 else {
            if let note = hit(location) {
                controls.select(controls.selected.contains(note.id) ? controls.selected.subtracting([note.id]) : controls.selected.union([note.id]))
            } else {
                controls.select([])
                click(location, [])
            }
            return
        }
        guard location.y >= ruler, hit(location) == nil, let clip, let midi = clip.midi else { return }
        let position = time(at: location.x)
        guard clip.startTime <= position, position < clip.startTime + clip.duration else { return }
        let note = MIDINote(start: max(0, midi.grid.snap(sourceBeat(at: position))), length: midi.grid.step,
                            pitch: pitch(at: location.y), velocity: controls.velocity, channel: max(1, controls.filter))
        controls.commit(midi.notes + [note])
        controls.select([note.id])
    }
    private func drag(_ value: DragGesture.Value) {
        guard pinchScale == 1 else { return }
        if gesture == nil, let note = hit(value.startLocation), let midi = clip?.midi {
            let rect = noteRect(note)
            let edge = min(10, rect.width / 3)
            let selection = controls.selected.contains(note.id) ? controls.selected : [note.id]
            gesture = NoteDrag(original: midi.notes, draft: midi.notes, selection: selection, anchor: note,
                               edge: value.startLocation.x <= rect.minX + edge ? .start :
                                    value.startLocation.x >= rect.maxX - edge ? .end : .move)
            controls.select(selection)
        }
        guard var editing = gesture, let grid = clip?.midi?.grid else {
            scroll(CGPoint(x: value.translation.width - panOffset.width, y: value.translation.height - panOffset.height))
            panOffset = value.translation
            return
        }
        let offset = sourceBeat(at: time(at: value.location.x)) - sourceBeat(at: time(at: value.startLocation.x))
        let anchor = editing.edge == .end ? editing.anchor.end : editing.anchor.start
        let amount = grid.snap(anchor + offset) - anchor
        let chosen = editing.original.filter { editing.selection.contains($0.id) }
        let earliest = chosen.map(\.start).min() ?? 0
        let shortest = chosen.map(\.length).min() ?? 0
        let pitchOffset = pitch(at: value.location.y) - pitch(at: value.startLocation.y)
        let pitchDelta = min(127 - (chosen.map(\.pitch).max() ?? 127), max(-(chosen.map(\.pitch).min() ?? 0), pitchOffset))
        editing.draft = editing.original.map { original in
            guard editing.selection.contains(original.id) else { return original }
            var note = original
            switch editing.edge {
            case .move: note.start += max(-earliest, amount); note.pitch += pitchDelta
            case .start:
                let delta = max(-earliest, min(amount, shortest - 1.0 / 960))
                note.start += delta
                note.length -= delta
            case .end: note.length += max(1.0 / 960 - shortest, amount)
            }
            return note
        }
        gesture = editing
    }

    var body: some View {
        Canvas { graphics, size in
            var context = graphics
            context.clip(to: Path(CGRect(x: keys, y: ruler, width: max(0, size.width - keys), height: max(0, size.height - ruler))))
            for note in notes {
                let bounds = noteRect(note)
                guard bounds.intersects(CGRect(origin: .zero, size: size)) else { continue }
                let path = Path(roundedRect: bounds, cornerRadius: 2)
                context.fill(path, with: .color(JarasTheme.green.opacity(controls.selected.contains(note.id) ? 1 : 0.7)))
                if controls.selected.contains(note.id) { context.stroke(path, with: .color(.white), lineWidth: 1) }
                RecordingPreviewTake.drawNoteLabel(in: &context, rect: bounds, pitch: note.pitch, velocity: note.velocity)
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { tap($0.location, count: 2) }
            .exclusively(before: SpatialTapGesture().onEnded { tap($0.location, count: 1) }))
        .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged(drag).onEnded { _ in
            if let gesture, gesture.draft != gesture.original { controls.commit(gesture.draft) }
            gesture = nil
            panOffset = .zero
        })
        .simultaneousGesture(MagnificationGesture().updating($pinchScale) { value, state, _ in state = value }
            .onEnded { value in zoomAt(min(MIDIPianoLimits.zoom.upperBound, max(MIDIPianoLimits.zoom.lowerBound, controls.zoom * value)), x(for: sourceBeat(at: cursor))) })
        .onChange(of: clip?.id) { _ in gesture = nil; panOffset = .zero }
        .onDrop(of: [UTType(exportedAs: LibraryMIDIChord.transferType)], isTargeted: nil) { providers in
            guard clip != nil, let provider = providers.first else { return false }
            let insert = controls.insertChord
            provider.loadDataRepresentation(forTypeIdentifier: LibraryMIDIChord.transferType) { data, _ in
                guard let data, let name = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    if let chord = LibraryMIDIChord.catalog.first(where: { $0.name == name }) { _ = insert(chord) }
                }
            }
            return true
        }
    }
}

private struct MIDIPreviewScrollBar: View {
    let vertical: Bool
    let position, first, last, visible, step: Double
    let changed: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let length = vertical ? geometry.size.height : geometry.size.width
            let thumb = max(16, length * min(1, visible / max(visible, last - first)))
            let travel = max(1, length - thumb)
            let span = max(0, last - first - visible)
            let offset = travel * (span > 0 ? min(1, max(0, (position - first) / span)) : 0)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.16))
                Capsule().fill(Color(white: 0.40))
                    .frame(width: vertical ? 6 : thumb, height: vertical ? thumb : 6)
                    .offset(x: vertical ? 3 : offset, y: vertical ? offset : 3)
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let pointer = vertical ? drag.location.y : drag.location.x
                    changed(first + span * min(1, max(0, (pointer - thumb / 2) / travel)))
                })
                .accessibilityLabel(vertical ? "MIDI Preview pitch" : "MIDI Preview time")
                .accessibilityAdjustableAction { direction in
                    changed(min(first + span, max(first, position + (direction == .increment ? step : -step))))
                }
        }
    }
}
#endif

#if os(iOS)
struct IpadWorkspaceFloatingPanel<Content: View>: View {
    let title: String
    var minimumHeight: CGFloat = 200
    let dock: () -> Void
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var position = CGPoint(x: 24, y: 82)
    @State private var height = 340.0
    @GestureState private var movement = CGSize.zero
    @GestureState private var resize: CGFloat = 0

    var body: some View {
        GeometryReader { viewport in
            let width = min(920, viewport.size.width)
            let currentHeight = min(viewport.size.height, max(minimumHeight, height + resize))
            let xLimit = max(0, viewport.size.width - width)
            let yLimit = max(0, viewport.size.height - currentHeight)
            VStack(spacing: 0) {
                HStack {
                    Text(verbatim: title).font(.jarasHeadline)
                    Spacer()
                    Button(action: dock) { Image(systemName: "pin.fill").frame(width: 36, height: 36) }.accessibilityLabel("Indexar")
                    Button(action: close) { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("Close")
                }.padding(.horizontal, 10).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
                        .updating($movement) { drag, value, _ in value = drag.translation }
                        .onEnded { drag in
                            position.x = min(xLimit, max(0, position.x + drag.translation.width))
                            position.y = min(yLimit, max(0, position.y + drag.translation.height))
                        })
                Divider()
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                Capsule().fill(JarasTheme.secondary).frame(width: 48, height: 3)
                    .frame(maxWidth: .infinity).frame(height: 16).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($resize) { drag, value, _ in value = drag.translation.height }
                        .onEnded { drag in height = min(viewport.size.height, max(minimumHeight, height + drag.translation.height)) })
                    .accessibilityLabel(Text("Resize \(title)"))
            }.frame(width: width, height: currentHeight)
                .background(JarasTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.4), radius: 10)
                .buttonStyle(.plain)
                .offset(x: min(xLimit, max(0, position.x + movement.width)),
                        y: min(yLimit, max(0, position.y + movement.height)))
        }
    }
}
#endif
