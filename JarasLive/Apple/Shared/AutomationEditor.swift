#if os(macOS)
import AppKit
import SwiftUI
import Combine

@MainActor private final class AutomationWindow: NSWindow, NSWindowDelegate {
    var observation: AnyCancellable?
    var didClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { observation = nil; didClose?() }
}
@MainActor enum AutomationWindows {
    private static var windows: [String: NSWindow] = [:]
    static func closeAll() {
        // Closing calls didClose, which mutates the registry.
        let closing = Array(windows.values)
        windows.removeAll()
        for window in closing { window.close() }
    }
    static func open(show: ShowController, track: UUID?) {
        let key = show.snapshot.project.id.uuidString + (track?.uuidString ?? "master")
        if let window = windows[key] { window.makeKeyAndOrderFront(nil); return }
        let name = track.flatMap { id in show.current?.tracks.first { $0.id == id }?.name } ?? "Master"
        let window = AutomationWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = JarasLocalization.string("Envelopes") + " · " + name
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 640, height: 400)
        let host = NSHostingView(rootView: LocalizedAutomationEditor(show: show, track: track))
        if #available(macOS 13, *) { host.sizingOptions = [] }
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        windows[key] = window; window.center(); window.makeKeyAndOrderFront(nil)
        window.delegate = window
        window.didClose = { windows[key] = nil }
        let project = show.snapshot.project.id
        window.observation = show.$snapshot.map { $0.project.id }.removeDuplicates().sink { [weak window] id in
            if id != project { window?.close() }
        }
    }
}

@MainActor private struct LocalizedAutomationEditor: View {
    let show: ShowController
    let track: UUID?
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        GeometryReader { geometry in
            AutomationEditor(show: show, track: track)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.dark)
        }
    }
}

private struct AutomationChoice: Identifiable {
    let target: AutomationTarget, name: String, value: Double
    var id: String { target.key }
}
@MainActor private struct AutomationEditor: View {
    let show: ShowController
    let track: UUID?
    @ObservedObject private var updates: ShowPresentationObserver
    @State private var choices: [AutomationChoice] = []
    @State private var search = ""
    @State private var selected: UUID?
    @State private var zoom = 1.0
    @State private var offset = 0.0
    init(show: ShowController, track: UUID?) {
        self.show = show; self.track = track; _updates = ObservedObject(wrappedValue: show.presentationObserver)
    }
    private var settings: TrackAutomation { show.automation(track) }
    private var duration: Double { max(30, show.current?.duration ?? 30) }
    private func edit(_ action: (inout TrackAutomation) -> Void) { var next = settings; action(&next); show.setAutomation(track, settings: next) }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Automation enabled", isOn: Binding(get: { settings.enabled }, set: { value in edit { $0.enabled = value; $0.lanesVisible = value } }))
                Spacer()
                Picker("Mode", selection: Binding(get: { settings.mode }, set: { value in edit { $0.mode = value } })) {
                    ForEach(AutomationMode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }.frame(width: 210)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search parameters", text: $search)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(choices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { choice in
                                HStack {
                                    Toggle(isOn: Binding(get: { settings.envelopes.contains { $0.target == choice.target && $0.enabled } }, set: { enabled in
                                        edit { next in
                                            if let index = next.envelopes.firstIndex(where: { $0.target == choice.target }) {
                                                next.envelopes[index].enabled = enabled
                                                next.envelopes[index].visible = enabled
                                                if enabled { next.lanesVisible = true; next.enabled = true; selected = next.envelopes[index].id }
                                            } else if enabled {
                                                let envelope = TrackEnvelope(target: choice.target, name: choice.name, defaultValue: choice.value)
                                                next.envelopes.append(envelope); selected = envelope.id; next.lanesVisible = true; next.enabled = true
                                            }
                                        }
                                    })) { Text(verbatim: choice.name).font(.system(size: 12)).lineLimit(2) }
                                    Spacer(minLength: 0)
                                }.padding(5)
                            }
                        }
                    }
                }.frame(width: 240)
                Divider()
                VStack(spacing: 8) {
                    List(selection: $selected) {
                        ForEach(settings.envelopes) { envelope in
                            HStack {
                                Text(verbatim: envelope.name).lineLimit(2)
                                Spacer()
                                flag(envelope, title: "Enabled", path: \.enabled)
                                flag(envelope, title: "Visible", path: \.visible)
                                flag(envelope, title: "Arm", path: \.armed)
                            }.tag(envelope.id)
                        }
                    }.frame(minHeight: 130)
                    if track == nil, let envelope = settings.envelopes.first(where: { $0.id == selected }) ?? settings.envelopes.first {
                        Text(verbatim: envelope.name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geometry in
                            AutomationCurveEditor(show: show, track: track, envelope: envelope,
                                scale: max(1, geometry.size.width) / (duration / zoom), offset: offset,
                                height: geometry.size.height)
                        }.frame(minHeight: 140)
                        HStack {
                            Text("Zoom"); Slider(value: $zoom, in: 1...64).frame(width: 140)
                            Slider(value: $offset, in: 0...max(0.001, duration - duration / zoom))
                        }
                        Text("Double-click to add a point. Drag to move. Shift disables snap. Delete removes selected points. Right-click changes the curve.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if track != nil, !settings.envelopes.isEmpty {
                        Text("Edit envelope points in the grid, below the track.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Double-click to add a point. Drag to move. Shift disables snap. Delete removes selected points. Right-click changes the curve.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Select parameters to create envelopes.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
            }
        }.padding(16).background(JarasTheme.background).onAppear(perform: loadChoices)
            .onChange(of: show.fxSettings(track)) { _ in loadChoices() }
    }
    private func flag(_ envelope: TrackEnvelope, title: String, path: WritableKeyPath<TrackEnvelope, Bool>) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(get: { envelope[keyPath: path] }, set: { value in
            edit { next in if let index = next.envelopes.firstIndex(where: { $0.id == envelope.id }) {
                next.envelopes[index][keyPath: path] = value
                if path == \.visible, value { next.lanesVisible = true; next.enabled = true }
            } }
        })).font(.caption).toggleStyle(.checkbox)
    }
    private func loadChoices() {
        let row = track.flatMap { id in show.current?.tracks.first { $0.id == id } }
        choices = [AutomationChoice(target: AutomationTarget(.volume), name: JarasLocalization.string("Volume"), value: TrackEnvelope.normalizedGain(row?.volume ?? show.snapshot.project.masterVolume ?? 1)),
                   AutomationChoice(target: AutomationTarget(.pan), name: "Pan", value: ((row?.pan ?? show.snapshot.project.masterPan ?? 0)+1)/2),
                   AutomationChoice(target: AutomationTarget(.mute), name: "Mute", value: (row?.mute ?? (show.snapshot.project.masterMute == true)) ? 1 : 0)]
        let fx = show.fxSettings(track)
        choices += NativeFXParameter.automationParameters(in: fx).map { parameter in
            AutomationChoice(target: AutomationTarget(.nativeFX, native: parameter), name: fx.kind(of: parameter.effect) + " · " + parameter.name,
                             value: parameter.normalized(parameter.currentValue(in: fx)))
        }
        for plugin in fx.externalPlugins ?? [] where fx.inserted.contains(plugin.effectKey) {
            guard let node = StemAudioPlayback.shared.effects(for: track)?.externalNode(plugin.id) else { continue }
            for parameter in JarasVST3.parameters(node, identifier: plugin.id) {
                guard let id = parameter["id"] as? UInt32, let name = parameter["name"] as? String, let value = parameter["value"] as? Double else { continue }
                choices.append(AutomationChoice(target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: id), name: plugin.name + " · " + name, value: value))
            }
        }
        // Preserve disconnected plugin envelopes so they can be edited or removed.
        for envelope in settings.envelopes where !choices.contains(where: { $0.target == envelope.target }) {
            choices.append(AutomationChoice(target: envelope.target, name: envelope.name, value: envelope.defaultValue))
        }
    }
}

private struct AutomationCurveEditor: NSViewRepresentable {
    let show: ShowController, track: UUID?, envelope: TrackEnvelope, scale: CGFloat, offset: Double, height: CGFloat
    func makeNSView(context: Context) -> AutomationLaneView { AutomationLaneView() }
    func updateNSView(_ view: AutomationLaneView, context: Context) {
        view.configure(show: show, entries: [.init(track: track, envelope: envelope, y: 0, height: height)], minimumY: 0)
        view.project(viewport: CGRect(x: offset * scale, y: 0, width: max(1, view.bounds.width), height: height), scale: scale, movesFrame: false)
    }
}

/// Only visible points are drawn. No timer, full-timeline texture or per-point view.
@MainActor final class AutomationLaneView: NSView, TimelineGridKeyboardTarget {
    struct Entry: Equatable { var track: UUID?; var envelope: TrackEnvelope; var y: CGFloat; var height: CGFloat }
    private weak var show: ShowController?
    private var entries: [Entry] = []
    private var viewport = CGRect.zero
    private var scale: CGFloat = 10
    private var minimumY: CGFloat = 0
    private var selection = Set<UUID>()
    private var dragging: (entry: Int, point: UUID, original: TrackEnvelope)?
    private var contextEntry: Int?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); viewport.size = newSize; needsDisplay = true
    }
    func configure(show: ShowController, entries: [Entry], minimumY: CGFloat) {
        self.show = show; self.minimumY = minimumY
        let sameLanes = self.entries.count == entries.count && zip(self.entries, entries).allSatisfy {
            $0.track == $1.track && $0.envelope.id == $1.envelope.id
        }
        if !sameLanes { dragging = nil; contextEntry = nil }
        selection.formIntersection(entries.flatMap { $0.envelope.points.map(\.id) })
        if dragging == nil, self.entries != entries { self.entries = entries; needsDisplay = true }
        isHidden = entries.isEmpty
    }
    func project(viewport: CGRect, scale: CGFloat, movesFrame: Bool = true) {
        if self.viewport != viewport || self.scale != scale {
            self.viewport = viewport; self.scale = max(0.000001, scale)
            if movesFrame { frame = viewport }
            needsDisplay = true
        }
    }
    func hit(atWindowPoint point: NSPoint) -> NSView? {
        let local = convert(point, from: nil)
        guard !isHidden, bounds.contains(local), local.y >= minimumY, entry(at: local) != nil else { return nil }
        return self
    }
    override func hitTest(_ point: NSPoint) -> NSView? { hit(atWindowPoint: convert(convert(point, from: superview), to: nil)) }
    private func entry(at point: NSPoint) -> Int? { entries.firstIndex { point.y + viewport.minY >= $0.y && point.y + viewport.minY < $0.y + $0.height } }
    private func rect(_ entry: Entry) -> CGRect { CGRect(x: 0, y: entry.y - viewport.minY, width: bounds.width, height: entry.height) }
    private func curveGeometry(in entry: Entry) -> (top: CGFloat, height: CGFloat) {
        if entry.height >= 48 { return (rect(entry).minY + 24, max(1, entry.height - 32)) }
        let inset = min(6, entry.height / 4)
        return (rect(entry).minY + inset, max(1, entry.height - inset * 2))
    }
    private func location(_ point: EnvelopePoint, in entry: Entry) -> NSPoint {
        let curve = curveGeometry(in: entry)
        return NSPoint(x: point.time * scale - viewport.minX, y: curve.top + (1-point.value)*curve.height)
    }
    private func nearest(_ point: NSPoint, entry: Entry) -> EnvelopePoint? {
        entry.envelope.points.first { let p = location($0, in: entry); return hypot(p.x-point.x, p.y-point.y) < 7 }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: CGRect(x: 0, y: minimumY, width: bounds.width, height: max(0, bounds.height-minimumY)))
        defer { context.restoreGState() }
        for entry in entries where rect(entry).intersects(dirtyRect) {
            let r = rect(entry)
            let curve = curveGeometry(in: entry)
            context.saveGState(); context.clip(to: r)
            context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 0.72).cgColor); context.fill(r)
            context.setStrokeColor(NSColor(calibratedWhite: 0.3, alpha: 1).cgColor); context.stroke(r.insetBy(dx: 0, dy: 0.5))
            if entry.height >= 48 {
                (entry.envelope.name as NSString).draw(at: NSPoint(x: 8, y: r.minY+3), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
            }
            let color = entry.envelope.enabled ? NSColor.systemGreen : NSColor.gray
            context.setStrokeColor(color.cgColor); context.setLineWidth(1.5)
            // Pixel sampling includes every visible point and all curve shapes.
            let path = CGMutablePath()
            for x in stride(from: 0.0, through: Double(bounds.width), by: 2) {
                let time = (viewport.minX+x)/scale
                let p = NSPoint(x: x, y: curve.top+(1-entry.envelope.value(at: time))*curve.height)
                if x == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.addPath(path); context.strokePath()
            for point in entry.envelope.points where point.time*scale >= viewport.minX-8 && point.time*scale <= viewport.maxX+8 {
                let p = location(point, in: entry)
                let radius = min(3, entry.height / 4)
                context.setFillColor((selection.contains(point.id) ? NSColor.white : color).cgColor)
                context.fillEllipse(in: CGRect(x: p.x-radius, y: p.y-radius, width: radius*2, height: radius*2))
            }
            context.restoreGState()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = entry(at: p) else { return }
        window?.makeFirstResponder(self)
        if let point = nearest(p, entry: entries[index]) {
            if event.modifierFlags.contains(.command) { if !selection.insert(point.id).inserted { selection.remove(point.id) } }
            else if !selection.contains(point.id) { selection = [point.id] }
            dragging = (index, point.id, entries[index].envelope)
        } else if event.clickCount == 2 {
            let point = editedPoint(p, entry: entries[index], event: event)
            entries[index].envelope.insert(point); selection = [point.id]; commit(index)
        } else { selection.removeAll() }
        needsDisplay = true
    }
    private func editedPoint(_ p: NSPoint, entry: Entry, event: NSEvent) -> EnvelopePoint {
        var time = max(0, (p.x+viewport.minX)/scale)
        if !event.modifierFlags.contains(.shift), let song = show?.current { time = TimelineTempo.snap(time, song: song, pixelsPerSecond: scale) }
        let curve = curveGeometry(in: entry)
        return EnvelopePoint(time: time, value: min(1, max(0, 1-(p.y-curve.top)/curve.height)))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag = dragging, let original = drag.original.points.first(where: { $0.id == drag.point }) else { return }
        let point = editedPoint(convert(event.locationInWindow, from: nil), entry: entries[drag.entry], event: event)
        var next = drag.original
        let selected = next.points.filter { selection.contains($0.id) }
        let delta = max(-(selected.map(\.time).min() ?? 0), point.time-original.time)
        next.points.removeAll { selection.contains($0.id) }
        for var p in selected { p.time += delta; p.value = min(1, max(0, p.value+point.value-original.value)); next.insert(p) }
        entries[drag.entry].envelope = next; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if let drag = dragging { dragging = nil; commit(drag.entry) } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let drag = dragging { entries[drag.entry].envelope = drag.original; dragging = nil; needsDisplay = true; return }
        if event.keyCode == 53 { selection.removeAll(); needsDisplay = true; return }
        if event.keyCode == 51 || event.keyCode == 117 {
            for index in entries.indices where entries[index].envelope.points.contains(where: { selection.contains($0.id) }) {
                entries[index].envelope.points.removeAll { selection.contains($0.id) }; commit(index)
            }
            selection.removeAll(); needsDisplay = true; return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = entry(at: p) else { return nil }
        contextEntry = index
        if let point = nearest(p, entry: entries[index]), !selection.contains(point.id) { selection = [point.id] }
        let menu = NSMenu()
        for (index, shape) in EnvelopeShape.allCases.enumerated() {
            let item = NSMenuItem(title: JarasLocalization.string(shape.title), action: #selector(changeShape(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; menu.addItem(item)
        }
        needsDisplay = true; return menu
    }
    @objc private func changeShape(_ sender: NSMenuItem) {
        guard let index = contextEntry else { return }
        for point in entries[index].envelope.points.indices where selection.contains(entries[index].envelope.points[point].id) {
            entries[index].envelope.points[point].shape = EnvelopeShape.allCases[sender.tag]
        }
        commit(index); needsDisplay = true
    }
    private func commit(_ index: Int) {
        guard let show, entries.indices.contains(index) else { return }
        let entry = entries[index]
        var next = show.automation(entry.track)
        guard let i = next.envelopes.firstIndex(where: { $0.id == entry.envelope.id }) else { return }
        next.envelopes[i] = entry.envelope; show.setAutomation(entry.track, settings: next)
    }
}
#endif
