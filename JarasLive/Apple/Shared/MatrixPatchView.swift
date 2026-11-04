#if os(macOS)
import SwiftUI
import AppKit
import CoreAudio

private struct MatrixPatchRow: Equatable {
    let id: UUID?
    let number: String
    let name: String
    let color: UInt32
    let sends: Bool
    let master: Bool
    let outputs: [OutputPatch]
    let destinations: Set<UUID>
}
private struct MatrixPatchColumn: Equatable {
    let destination: MatrixPatchDestination
    let name: String
    let badge: String
    let color: UInt32
    let available: Bool
}
private struct MatrixPatchPresentation: Equatable {
    var rows: [MatrixPatchRow] = []
    var columns: [MatrixPatchColumn] = []
    func enabled(_ row: Int, _ column: Int) -> Bool {
        let r = rows[row], c = columns[column]
        switch c.destination {
        case .output(let patch): return c.available && (patch.firstChannel > 0 || r.master)
        case .track(let id): return r.sends && r.id != id
        }
    }
    func active(_ row: Int, _ column: Int) -> Bool {
        switch columns[column].destination {
        case .output(let patch): return rows[row].outputs.contains(patch)
        case .track(let id): return rows[row].destinations.contains(id)
        }
    }
}

struct MatrixPatchView: View {
    @ObservedObject var show: ShowController
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @AppStorage("jaras.language") private var language = "en"
    @State private var search = ""
    @State private var hint = ""
    @State private var failure = ""
    @State private var cached = MatrixPatchPresentation()
    private var presentation: MatrixPatchPresentation {
        var result = cached
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { result.rows.removeAll { !$0.name.localizedCaseInsensitiveContains(query) && $0.number != query } }
        return result
    }
    private func refresh() {
        let tracks = show.current?.tracks ?? []
        var result = MatrixPatchPresentation()
        var destinations: [UUID: Set<UUID>] = [:]
        for track in tracks {
            for id in track.routing?.transmitters.compactMap({ $0 }) ?? [] { destinations[track.id, default: []].insert(id) }
            for id in track.routing?.receives.compactMap({ $0 }) ?? [] { destinations[id, default: []].insert(track.id) }
            if let parent = track.parentTrackID, track.outputPatches.contains(.masterGroup) { destinations[track.id, default: []].insert(parent) }
        }
        result.rows.append(MatrixPatchRow(id: nil, number: "M", name: "Master", color: 0x68df97,
            sends: false, master: false, outputs: show.snapshot.project.masterOutputPatches, destinations: []))
        for (index, track) in tracks.enumerated() where track.kind == .standard || track.kind == .click {
            result.rows.append(MatrixPatchRow(id: track.id, number: String(index + 1), name: track.name,
                color: track.color ?? 0x888888, sends: track.kind == .standard && track.role.rawValue != "vinhetas",
                master: track.role.rawValue != "vinhetas", outputs: track.outputPatches, destinations: destinations[track.id] ?? []))
        }
        result.columns.append(MatrixPatchColumn(destination: .output(.master), name: "Master", badge: "M", color: 0x68df97, available: true))
        var patches = OutputPatch.choices(channels: audio.channels, includeMaster: false)
        // Keep offline routes visible and removable after an interface disconnect.
        for row in result.rows { for patch in row.outputs where patch.firstChannel > 0 && !patches.contains(patch) { patches.append(patch) } }
        for patch in patches {
            let available = patch.firstChannel + patch.channelCount - 1 <= audio.channels
            let title = patch.channelCount == 2 ? "\(channelName(patch.firstChannel)) / \(channelName(patch.firstChannel + 1))" : channelName(patch.firstChannel)
            result.columns.append(MatrixPatchColumn(destination: .output(patch), name: available ? title : title + " · " + JarasLocalization.string("Unavailable"), badge: patch.title, color: 0x67b9ee, available: available))
        }
        for (index, track) in tracks.enumerated() where track.kind == .standard && track.role.rawValue != "vinhetas" {
            result.columns.append(MatrixPatchColumn(destination: .track(track.id), name: track.name, badge: String(index + 1), color: track.color ?? 0x888888, available: true))
        }
        cached = result
    }
    private func channelName(_ channel: Int) -> String {
        if let device = audio.devices.first(where: { $0.id == audio.selectedUID }), device.hardwareID != 0 {
            var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName, mScope: kAudioDevicePropertyScopeOutput, mElement: UInt32(channel))
            var name: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &size, &name) == noErr, !(name as String).isEmpty { return name as String }
        }
        return "Out \(channel)"
    }
    var body: some View {
        let model = presentation
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Matrix Patch").font(.system(size: 22, weight: .semibold))
                    Text(audio.deviceName).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField(JarasLocalization.string("Search tracks"), text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(9).frame(width: 210).background(Color.black.opacity(0.35)).cornerRadius(8)
            }.padding(20)
            MatrixPatchCanvas(model: model, hover: { hint = $0 }, toggle: { row, column in
                failure = ""
                let previous = show.projectRevision
                show.toggleMatrixPatch(source: row.id, destination: column.destination)
                if show.projectRevision == previous && !show.message.isEmpty { failure = JarasLocalization.string(show.message) }
            }).padding(.horizontal, 16)
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0x68df97)).frame(width: 7, height: 7)
                Text(failure.isEmpty ? (hint.isEmpty ? JarasLocalization.string("Click a cell to connect or disconnect") : hint) : failure)
                    .font(.system(size: 12)).foregroundColor(failure.isEmpty ? .secondary : .red).lineLimit(2)
                Spacer(minLength: 0)
            }.frame(height: 44).padding(.horizontal, 20)
        }.background(Color(hex: 0x1e1f21)).foregroundColor(.white).preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: language))
            .onAppear { refresh() }
            .onChange(of: show.projectRevision) { _ in refresh() }
            .onChange(of: show.current?.id) { _ in refresh() }
            .onChange(of: audio.channels) { _ in refresh() }
            .onChange(of: audio.selectedUID) { _ in refresh() }
            .onChange(of: audio.deviceName) { _ in refresh() }
            .onChange(of: language) { _ in refresh() }
    }
}

private struct MatrixPatchCanvas: NSViewRepresentable {
    let model: MatrixPatchPresentation
    let hover: (String) -> Void
    let toggle: (MatrixPatchRow, MatrixPatchColumn) -> Void
    func makeNSView(context: Context) -> MatrixPatchSurface { MatrixPatchSurface() }
    func updateNSView(_ view: MatrixPatchSurface, context: Context) {
        view.hover = hover; view.toggle = toggle
        if view.model != model { view.model = model; view.updateContent() }
    }
}

/// Only visible cells are painted. Headers stay fixed while either axis scrolls;
/// there is no SwiftUI button/view allocation for every routing intersection.
private final class MatrixPatchSurface: NSView {
    static let rowHeight: CGFloat = 32, columnWidth: CGFloat = 38, labelWidth: CGFloat = 236, headerHeight: CGFloat = 170
    var model = MatrixPatchPresentation()
    var hover: (String) -> Void = { _ in }
    var toggle: (MatrixPatchRow, MatrixPatchColumn) -> Void = { _, _ in }
    var hotRow = -1, hotColumn = -1
    let scroll = NSScrollView()
    private lazy var cells = MatrixPatchDrawing(owner: self, area: .cells)
    private lazy var rows = MatrixPatchDrawing(owner: self, area: .rows)
    private lazy var columns = MatrixPatchDrawing(owner: self, area: .columns)
    private var observation: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        // Keep a draggable scrollbar visible whenever destinations overflow,
        // including with a mouse and macOS' default auto-hidden scrollbars.
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .legacy
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = true; scroll.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1)
        scroll.documentView = cells
        addSubview(scroll); addSubview(rows); addSubview(columns)
        scroll.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.rows.needsDisplay = true; self?.columns.needsDisplay = true
            self?.setHover(row: -1, column: -1)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    override func layout() {
        super.layout()
        let left = min(Self.labelWidth, max(120, bounds.width * 0.3)), top = Self.headerHeight
        rows.frame = NSRect(x: 0, y: top, width: left, height: max(0, bounds.height - top))
        columns.frame = NSRect(x: left, y: 0, width: max(0, bounds.width - left), height: top)
        scroll.frame = NSRect(x: left, y: top, width: max(0, bounds.width - left), height: max(0, bounds.height - top))
        updateContent()
    }
    func updateContent() {
        cells.setFrameSize(NSSize(width: max(scroll.contentSize.width, CGFloat(model.columns.count) * Self.columnWidth), height: max(scroll.contentSize.height, CGFloat(model.rows.count) * Self.rowHeight)))
        for view in [cells, rows, columns, self] { view.needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill(); bounds.fill()
        MatrixPatchDrawing.text(JarasLocalization.string("Sources"), NSRect(x: 14, y: Self.headerHeight - 30, width: rows.frame.width - 28, height: 24), color: .secondaryLabelColor, bold: true)
        MatrixPatchDrawing.text(JarasLocalization.string("Destinations →"), NSRect(x: 14, y: 12, width: rows.frame.width - 28, height: 24), color: .secondaryLabelColor)
    }
    func setHover(row: Int, column: Int) {
        guard row != hotRow || column != hotColumn else { return }
        DesktopIconTooltipWindow.shared.hide(owner: cells)
        hotRow = row; hotColumn = column
        cells.needsDisplay = true; rows.needsDisplay = true; columns.needsDisplay = true
        if model.rows.indices.contains(row), model.columns.indices.contains(column) {
            hover(model.rows[row].name + " > " + model.columns[column].name)
        } else { hover("") }
    }
}
private final class MatrixPatchDrawing: NSView {
    enum Area { case cells, rows, columns }
    weak var owner: MatrixPatchSurface?
    let area: Area
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(owner: MatrixPatchSurface, area: Area) { self.owner = owner; self.area = area; super.init(frame: .zero); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseMoved(with event: NSEvent) {
        guard let owner else { return }
        let point = convert(event.locationInWindow, from: nil), offset = owner.scroll.contentView.bounds.origin
        let row = Int((point.y + (area == .rows ? offset.y : 0)) / MatrixPatchSurface.rowHeight)
        let col = Int((point.x + (area == .columns ? offset.x : 0)) / MatrixPatchSurface.columnWidth)
        owner.setHover(row: area == .columns ? -1 : row, column: area == .rows ? -1 : col)
        if area == .cells, owner.model.rows.indices.contains(row), owner.model.columns.indices.contains(col), let window {
            let label = owner.model.rows[row].name + " > " + owner.model.columns[col].name
            DesktopIconTooltipWindow.shared.present(label, owner: self, at: window.convertPoint(toScreen: event.locationInWindow))
        }
    }
    override func mouseExited(with event: NSEvent) { owner?.setHover(row: -1, column: -1); DesktopIconTooltipWindow.shared.hide(owner: self) }
    override func scrollWheel(with event: NSEvent) {
        // The frozen labels and the cells share the same scrolling surface.
        owner?.scroll.scrollWheel(with: event)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { DesktopIconTooltipWindow.shared.hide(owner: self) } }
    override func mouseDown(with event: NSEvent) {
        guard area == .cells, let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(point.y / MatrixPatchSurface.rowHeight), col = Int(point.x / MatrixPatchSurface.columnWidth)
        guard owner.model.rows.indices.contains(row), owner.model.columns.indices.contains(col),
              owner.model.enabled(row, col) || owner.model.active(row, col) else { return }
        owner.toggle(owner.model.rows[row], owner.model.columns[col])
    }
    static func text(_ value: String, _ rect: NSRect, color: NSColor = .white, bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func color(_ hex: UInt32) -> NSColor { NSColor(calibratedRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let painting = dirtyRect.intersection(visibleRect).intersection(bounds)
        guard !painting.isEmpty else { return }
        let model = owner.model, offset = owner.scroll.contentView.bounds.origin
        let w = MatrixPatchSurface.columnWidth, h = MatrixPatchSurface.rowHeight
        NSColor(calibratedWhite: area == .cells ? 0.075 : 0.12, alpha: 1).setFill(); painting.fill()
        if area == .columns {
            for (col, value) in model.columns.enumerated() {
                let x = CGFloat(col) * w - offset.x
                guard x + w >= 0, x < bounds.width else { continue }
                if col == owner.hotColumn { NSColor.white.withAlphaComponent(0.07).setFill(); NSRect(x: x, y: 0, width: w, height: bounds.height).fill() }
                color(value.color).setFill(); NSRect(x: x + 6, y: bounds.height - 5, width: w - 12, height: 2).fill()
                Self.text(value.badge, NSRect(x: x + 6, y: bounds.height - 26, width: w - 6, height: 18), color: color(value.color), bold: true)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform(); transform.translateX(by: x + 10, yBy: bounds.height - 34); transform.rotate(byDegrees: -90); transform.concat()
                Self.text(value.name, NSRect(x: 0, y: 0, width: bounds.height - 42, height: 20), color: value.available ? .white : .secondaryLabelColor)
                NSGraphicsContext.restoreGraphicsState()
            }
            return
        }
        let first = max(0, Int((area == .cells ? painting.minY : offset.y) / h))
        let last = min(model.rows.count, Int(((area == .cells ? painting.maxY : offset.y + bounds.height)) / h) + 1)
        guard first < last else { return }
        for row in first..<last {
            let y = CGFloat(row) * h - (area == .rows ? offset.y : 0), value = model.rows[row]
            NSColor.white.withAlphaComponent(row == owner.hotRow ? 0.07 : row % 2 == 0 ? 0.025 : 0).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: h).fill()
            if area == .rows {
                color(value.color).setFill(); NSRect(x: 0, y: y + 6, width: 3, height: h - 12).fill()
                Self.text(value.number, NSRect(x: 12, y: y + 8, width: 34, height: 20), color: .secondaryLabelColor)
                Self.text(value.name, NSRect(x: 48, y: y + 8, width: bounds.width - 56, height: 20), bold: value.id == nil)
                continue
            }
            let start = max(0, Int(painting.minX / w)), end = min(model.columns.count, Int(painting.maxX / w) + 1)
            guard start < end else { continue }
            for col in start..<end {
                let cell = NSRect(x: CGFloat(col) * w + 5, y: y + 5, width: w - 10, height: h - 10)
                if col == owner.hotColumn {
                    NSColor(calibratedRed: 0.35, green: 0.52, blue: 0.76, alpha: 0.12).setFill()
                    NSRect(x: CGFloat(col) * w, y: y, width: w, height: h).fill()
                }
                let active = model.active(row, col), enabled = model.enabled(row, col)
                let path = NSBezierPath(roundedRect: cell, xRadius: 5, yRadius: 5)
                if active {
                    color(0x68df97).setFill(); path.fill()
                    let tick = NSBezierPath(); tick.move(to: NSPoint(x: cell.midX - 5, y: cell.midY)); tick.line(to: NSPoint(x: cell.midX - 1, y: cell.midY + 4)); tick.line(to: NSPoint(x: cell.midX + 6, y: cell.midY - 4)); tick.lineWidth = 1.8
                    NSColor.black.setStroke(); tick.stroke()
                } else if enabled {
                    NSColor.white.withAlphaComponent(col == owner.hotColumn ? 0.11 : 0.035).setFill(); path.fill()
                    NSColor.white.withAlphaComponent(0.10).setStroke(); path.lineWidth = 0.5; path.stroke()
                } else {
                    NSColor.white.withAlphaComponent(0.12).setStroke()
                    let slash = NSBezierPath(); slash.move(to: NSPoint(x: cell.midX - 3, y: cell.midY + 3)); slash.line(to: NSPoint(x: cell.midX + 3, y: cell.midY - 3)); slash.stroke()
                }
                if row == owner.hotRow && col == owner.hotColumn {
                    color(0x68df97).setStroke(); path.lineWidth = 1.4; path.stroke()
                }
            }
        }
    }
}
#endif
