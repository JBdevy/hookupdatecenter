import SwiftUI
struct TimelineGridView: View {
    @ObservedObject var show: ShowController
    @Environment(\.locale) private var locale
    @AppStorage("jaras.timelineZoom") private var zoom = 1.0
    @State private var addingTrack = false
    @State private var trackName = ""
    @State private var newRole = "other"
    @State private var draggingMain = false
    @State private var draggingSub = false
    @AppStorage("jaras.trackColumnWidth") private var savedLabelWidth = 138.0
    @State private var resizeStart: CGFloat?
    private let rulerHeight: CGFloat = 46
    #if os(iOS)
    private let minimumRow: CGFloat = 42
    #else
    private let minimumRow: CGFloat = 32
    #endif
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(show.current?.name ?? "Nenhuma música").font(.system(size: 17, weight: .bold))
                Text("\(Int(show.current?.bpm ?? 120)) BPM").font(.system(size: 11, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                Spacer()
                Label("Principal", systemImage: "triangle.fill").foregroundStyle(JarasTheme.green)
                Label("Sub Play", systemImage: "triangle.fill").foregroundStyle(JarasTheme.yellow)
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...4).frame(width: 88).tint(JarasTheme.accent)
                Image(systemName: "plus.magnifyingglass")
            }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 12).frame(height: 42).background(JarasTheme.panel)
            GeometryReader { geometry in
                if let song = show.current {
                    let maximumLabelWidth = max(161, min(248, geometry.size.width - 260))
                    let labelWidth = min(maximumLabelWidth, max(161, CGFloat(savedLabelWidth)))
                    let row = max(minimumRow, (geometry.size.height - rulerHeight - 48) / CGFloat(max(1, song.tracks.count)))
                    let width = max(200, geometry.size.width - labelWidth - 8) * zoom
                    let height = rulerHeight + CGFloat(song.tracks.count) * row
                    ScrollViewReader { scroll in
                        ScrollView(.vertical, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    HStack { Text("Mixer"); Spacer(); Text("M") }.font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(JarasTheme.secondary).padding(.horizontal, 10).frame(height: rulerHeight)
                                    ForEach(Array(song.tracks.enumerated()), id: \.element.id) { index, track in
                                        HStack(spacing: 6) {
                                            Rectangle().fill(JarasTheme.role(track.role)).frame(width: 3)
                                            Text(String(format: "%02d", index + 1)).font(.system(size: 9, design: .monospaced)).foregroundStyle(JarasTheme.secondary)
                                            Text(track.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                            Button { show.send(.mute, target: track.id) } label: { Circle().fill(track.mute ? JarasTheme.secondary : JarasTheme.green).frame(width: 8, height: 8).frame(width: 24, height: max(28, row - 2)) }.buttonStyle(.plain).accessibilityLabel("Silenciar \(track.name)")
                                        }.frame(height: row).background(JarasTheme.role(track.role).opacity(track.mute ? 0.04 : 0.17)).overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1) }
                                    }
                                    Button { trackName = "Track \(song.tracks.count + 1)"; addingTrack = true } label: {
                                        Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(JarasTheme.accent).frame(width: 28, height: 28).background(Circle().fill(JarasTheme.panel)).overlay(Circle().stroke(JarasTheme.accent, lineWidth: 1.5)).frame(maxWidth: .infinity).frame(height: 48)
                                    }.buttonStyle(.plain).accessibilityLabel("Criar pista").id("add-track")
                                }.frame(width: labelWidth).background(Color(hex: 0x202630))
                                Color.clear.frame(width: 8)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    ZStack(alignment: .topLeading) {
                                        TimelineDrawing(song: song, rowHeight: row, rulerHeight: rulerHeight).equatable().frame(width: width, height: height)
                                        #if os(macOS)
                                        TimelineRulerInput { fraction, rightClick in
                                            show.send(rightClick || show.isPlaying ? .subSeek : .seek, value: fraction * song.duration)
                                        }.frame(width: width, height: 23)
                                        #else
                                        Color.clear.frame(width: width, height: 23).contentShape(Rectangle())
                                            .gesture(SpatialTapGesture().onEnded { value in
                                                show.send(show.isPlaying ? .subSeek : .seek, value: min(1, max(0, value.location.x / width)) * song.duration)
                                            })
                                        #endif
                                        cursor(position: show.snapshot.transport.position, duration: song.duration, width: width, height: height, color: JarasTheme.green, secondary: false)
                                        cursor(position: show.snapshot.transport.subPlay.position, duration: song.duration, width: width, height: height, color: JarasTheme.yellow, secondary: true)
                                    }
                                    #if os(macOS)
                                    .background(TimelineWheelInput(zoom: $zoom, position: show.snapshot.transport.position / max(1, song.duration)))
                                    #endif
                                    .coordinateSpace(name: "timeline").frame(width: width, height: height + 48, alignment: .topLeading)
                                }
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            mixerDivider(width: labelWidth, maximum: maximumLabelWidth)
                                .frame(width: 12, height: geometry.size.height)
                                .offset(x: labelWidth - 2)
                        }
                        .onChange(of: song.tracks.count) { _ in withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("add-track", anchor: .bottom) } }
                    }
                }
            }
        }.background(JarasTheme.background).sheet(isPresented: $addingTrack) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Criar pista").font(.title2.bold())
                TextField("Nome da pista", text: $trackName).textFieldStyle(.roundedBorder)
                Picker("Tipo", selection: $newRole) { ForEach(["click","guide","drums","bass","guitar","keys","accordion","backingVocal","fx","other"], id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }
                HStack { Button("Cancelar") { addingTrack = false }; Spacer(); Button("Criar") { show.addTrack(name: trackName, role: TrackRole(rawValue: newRole)); addingTrack = false }.disabled(trackName.trimmingCharacters(in: .whitespaces).isEmpty) }.buttonStyle(StageButtonStyle(color: JarasTheme.accent))
            }.padding(28).frame(minWidth: 330).background(JarasTheme.panel).environment(\.locale, locale).preferredColorScheme(.dark)
        }
    }
    @ViewBuilder
    private func mixerDivider(width: CGFloat, maximum: CGFloat) -> some View {
        #if os(macOS)
        MixerResizeHandle(width: width, maximum: maximum) { savedLabelWidth = Double($0) }
        #else
        Rectangle().fill(JarasTheme.line)
            .overlay { Capsule().fill(JarasTheme.secondary).frame(width: 2, height: 28) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStart == nil { resizeStart = width }
                    savedLabelWidth = Double(min(maximum, max(161, (resizeStart ?? width) + value.translation.width)))
                }.onEnded { _ in resizeStart = nil })
        #endif
    }
    private func cursor(position: Double, duration: Double, width: CGFloat, height: CGFloat, color: Color, secondary: Bool) -> some View {
        let dragging = secondary ? draggingSub : draggingMain
        let x = min(width - 1, max(0, width * position / max(1, duration)))
        return ZStack(alignment: .top) {
            if dragging { Rectangle().fill(LinearGradient(colors: [.clear, color.opacity(0.35)], startPoint: .leading, endPoint: .trailing)).frame(width: 22, height: height).offset(x: -10).allowsHitTesting(false) }
            Rectangle().fill(color).frame(width: 1.5, height: height).shadow(color: color.opacity(dragging ? 1 : 0.55), radius: dragging ? 8 : 3).allowsHitTesting(false)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 13)).foregroundStyle(color)
                .frame(width: 28, height: 22).contentShape(Rectangle()).offset(x: x < 7 ? 7 - x : x > width - 7 ? width - 7 - x : 0, y: secondary ? 23 : 0)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        if secondary { draggingSub = true } else { draggingMain = true }
                        show.send(secondary ? .subSeek : .seek, value: min(duration, max(0, Double(value.location.x / width) * duration)))
                    }.onEnded { _ in draggingSub = false; draggingMain = false })
                .accessibilityLabel(secondary ? "Agulha Sub Play" : "Agulha principal")
        }.frame(width: 28, height: height).offset(x: x - 14)

    }
}
struct TimelineDrawing: View, Equatable {
    let song: Song; let rowHeight: CGFloat; let rulerHeight: CGFloat
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x1a2029)))
            let scale = size.width / song.duration
            let barSeconds = 240 / song.bpm
            let bars = Int(ceil(song.duration / barSeconds))
            for bar in 0...bars {
                let x = CGFloat(bar) * barSeconds * scale
                if bar % 2 == 0 { context.fill(Path(CGRect(x: x, y: rulerHeight, width: barSeconds * scale, height: size.height - rulerHeight)), with: .color(.white.opacity(0.022))) }
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height)); context.stroke(line, with: .color(.black.opacity(0.55)), lineWidth: 1)
                if barSeconds * scale > 18 || bar % 4 == 0 { context.draw(Text("\(bar + 1)").font(.system(size: 8, design: .monospaced)).foregroundColor(JarasTheme.secondary), at: CGPoint(x: x + 4, y: 8), anchor: .topLeading) }
                if barSeconds * scale > 28 {
                    for beat in 1..<4 { let bx = x + CGFloat(beat) * barSeconds * scale / 4; var minor = Path(); minor.move(to: CGPoint(x: bx, y: rulerHeight)); minor.addLine(to: CGPoint(x: bx, y: size.height)); context.stroke(minor, with: .color(.black.opacity(0.22)), lineWidth: 0.5) }
                }
            }
            for (index, part) in song.parts.enumerated() {
                let rect = CGRect(x: part.startTime * scale + 1, y: 23, width: max(1, (part.endTime - part.startTime) * scale - 2), height: 22)
                context.fill(Path(rect), with: .color(Color(hex: index % 2 == 0 ? 0x705264 : 0x885965)))
                context.draw(Text(part.name).font(.system(size: 9, weight: .medium)).foregroundColor(.white), at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
            }
            for (index, track) in song.tracks.enumerated() {
                let y = rulerHeight + CGFloat(index) * rowHeight
                var rowLine = Path(); rowLine.move(to: CGPoint(x: 0, y: y)); rowLine.addLine(to: CGPoint(x: size.width, y: y)); context.stroke(rowLine, with: .color(.black.opacity(0.6)), lineWidth: 1)
                let color = JarasTheme.role(track.role)
                for clip in track.clips {
                    let rect = CGRect(x: clip.startTime * scale + 1, y: y + 3, width: max(2, clip.duration * scale - 2), height: rowHeight - 6)
                    let path = Path(roundedRect: rect, cornerRadius: 3)
                    context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(track.mute ? 0.18 : 0.83), color.opacity(track.mute ? 0.1 : 0.4)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
                    context.stroke(path, with: .color(color.opacity(0.75)), lineWidth: 0.6)
                    if rect.width > 28 { context.draw(Text(clip.name).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.95)), at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: .topLeading) }
                    var wave = Path()
                    let peaks = clip.waveform
                    let middle = rect.minY + rect.height * 0.68, amplitude = rect.height * 0.22
                    for (sample, peak) in peaks.enumerated() {
                        let x = rect.minX + CGFloat(sample) / CGFloat(max(1, peaks.count - 1)) * rect.width
                        wave.move(to: CGPoint(x: x, y: middle - peak * amplitude)); wave.addLine(to: CGPoint(x: x, y: middle + peak * amplitude))
                    }
                    context.stroke(wave, with: .color(.white.opacity(track.mute ? 0.15 : 0.63)), lineWidth: 0.7)
                }
            }
        }
    }
}

#if os(macOS)
import AppKit
private struct MixerResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let maximum: CGFloat
    let onResize: (CGFloat) -> Void
    func makeNSView(context: Context) -> MixerDividerView {
        let view = MixerDividerView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel("Resize mixer")
        return view
    }
    func updateNSView(_ view: MixerDividerView, context: Context) {
        view.columnWidth = width
        view.maximum = maximum
        view.onResize = onResize
    }
}
private final class MixerDividerView: NSView {
    var columnWidth: CGFloat = 138
    var maximum: CGFloat = 248
    var onResize: ((CGFloat) -> Void)?
    private var startingWidth: CGFloat = 0
    private var startingX: CGFloat = 0
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1, y: bounds.midY - 14, width: 2, height: 28), xRadius: 1, yRadius: 1).fill()
    }
    override func mouseDown(with event: NSEvent) {
        startingWidth = columnWidth
        startingX = event.locationInWindow.x
    }
    override func mouseDragged(with event: NSEvent) {
        onResize?(min(maximum, max(161, startingWidth + event.locationInWindow.x - startingX)))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event) }
}
#endif
