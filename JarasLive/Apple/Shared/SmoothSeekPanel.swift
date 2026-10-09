import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

struct SectionButtonsIcon: View {
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Capsule().frame(width: 6, height: 2)
                Capsule().frame(width: 6, height: 2)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1).stroke(lineWidth: 1.4).frame(width: 6, height: 6)
                RoundedRectangle(cornerRadius: 1).stroke(lineWidth: 1.4).frame(width: 6, height: 6)
            }
        }.frame(width: 17, height: 16).accessibilityHidden(true)
    }
}

/// Button layout changes at section boundaries, never for each position sample.
/// The small native progress layers read the same authoritative clock directly.
@MainActor private final class SectionPanelObserver: ObservableObject {
    private struct State: Equatable {
        let controls: ShowPresentationState
        let section: UUID?
        let secondarySection: UUID?
        let trigger: Double?
        let idlePosition: Double?
    }
    let objectWillChange = ObservableObjectPublisher()
    private var state: State
    private var subscription: AnyCancellable?
    private var pending = false
    init(show: ShowController) {
        state = Self.read(show)
        subscription = show.objectWillChange.sink { [weak self, weak show] _ in
            guard let self, !self.pending else { return }
            self.pending = true
            DispatchQueue.main.async { [weak self, weak show] in
                guard let self, let show else { return }
                self.pending = false
                let next = Self.read(show)
                guard next != self.state else { return }
                self.state = next; self.objectWillChange.send()
            }
        }
    }
    private static func read(_ show: ShowController) -> State {
        let transport = show.snapshot.transport
        let song = show.current
        func sections(at position: Double) -> [TimelineMarker] {
            guard let song, let region = song.sectionRegion(at: position) else { return [] }
            return song.sectionMarkers(in: region)
        }
        let main = song.flatMap { song in song.sectionPlaybackRegion(for: transport).map { song.sectionMarkers(in: $0) } } ?? []
        let sub = transport.subPlay.playing ? sections(at: transport.subPlay.position) : []
        return State(controls: show.presentationState,
            section: main.last(where: { $0.position <= transport.position })?.id,
            secondarySection: sub.last(where: { $0.position <= transport.subPlay.position })?.id,
            trigger: transport.queuedSectionMarkerId == nil ? nil : song?.nextSectionTrigger(for: transport),
            idlePosition: show.isPlaying ? nil : transport.editPosition ?? transport.position)
    }
}

#if os(macOS)
private struct NativeSectionProgressBar: NSViewRepresentable {
    let running: Bool
    let countdown: Bool
    let start: Double
    let end: Double
    let sample: () -> (position: Double, time: Double)
    func makeNSView(context: Context) -> NativeSectionProgressView { NativeSectionProgressView() }
    func updateNSView(_ view: NativeSectionProgressView, context: Context) {
        view.configure(running: running, countdown: countdown, start: start, end: end, sample: sample)
    }
    static func dismantleNSView(_ view: NativeSectionProgressView, coordinator: ()) { view.stop() }
}
private final class NativeSectionProgressView: NSView {
    private let bar = CALayer()
    private var timer: Timer?
    private var running = false, countdown = false
    private var start = 0.0, end = 0.0
    private var sample: (() -> (position: Double, time: Double))?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(bar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(running: Bool, countdown: Bool, start: Double, end: Double,
                   sample: @escaping () -> (position: Double, time: Double)) {
        self.running = running; self.countdown = countdown
        self.start = start; self.end = end; self.sample = sample
        updateTimer(); paint()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer(); paint() }
    override func layout() { super.layout(); paint() }
    func stop() { timer?.invalidate(); timer = nil }
    private func updateTimer() {
        guard running, window != nil else { stop(); return }
        guard timer == nil else { return }
        let clock = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.paint() }
        timer = clock; RunLoop.main.add(clock, forMode: .common)
    }
    private func paint() {
        guard !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty, let sample else { return }
        let value = sample()
        let elapsed = running ? min(0.25, max(0, ProcessInfo.processInfo.systemUptime - value.time)) : 0
        let fraction = min(1, max(0, (value.position + elapsed - start) / max(0.001, end - start)))
        let width = bounds.width * (countdown ? 1 - fraction : fraction)
        let scale = window?.backingScaleFactor ?? 2
        let rect = CGRect(x: 0, y: max(0, bounds.height - 5), width: (width * scale).rounded() / scale, height: min(5, bounds.height))
        let color = countdown ? Self.countdownColor : Self.playbackColor
        guard bar.frame != rect || bar.backgroundColor != color else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.frame = rect; bar.backgroundColor = color
        CATransaction.commit()
    }
    private static let countdownColor = NSColor(JarasTheme.yellow).cgColor
    private static let playbackColor = NSColor(JarasTheme.green).cgColor
}
#endif

/// Transport updates stay in this small panel, independently of the grid canvas.
struct SmoothSeekPanel: View {
    #if os(macOS)
    let show: ShowController
    @StateObject private var updates: SectionPanelObserver
    #else
    @ObservedObject var show: ShowController
    #endif
    var verticalList = false
    init(show: ShowController, verticalList: Bool = false) {
        self.verticalList = verticalList
        #if os(macOS)
        self.show = show
        _updates = StateObject(wrappedValue: SectionPanelObserver(show: show))
        #else
        _show = ObservedObject(wrappedValue: show)
        #endif
    }
    var body: some View {
        let transport = show.snapshot.transport
        let current = show.current.flatMap { song in
            transport.playing ? song.sectionPlaybackRegion(for: transport) :
                song.parts.first(where: { $0.id == show.focusedRegion }) ?? song.sectionRegion(at: transport.editPosition ?? transport.position)
        }
        let queued = show.current.flatMap { song in
            transport.subPlay.playing ? song.sectionRegion(at: transport.subPlay.position) :
                song.parts.first(where: { $0.id == transport.queuedRegionId })
        }
        if verticalList {
            VStack(spacing: 0) {
                #if os(macOS)
                Button { show.send(.cancelSection) } label: {
                    Text("Cancel").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(Color(hex: 0xffd600))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(transport.queuedSectionMarkerId == nil)
                    .accessibilityLabel("Cancel queued section")
                    .padding(4)
                #endif
                SectionListTabs(current: current?.displayName, queued: queued?.displayName, subPlaying: transport.subPlay.playing) { secondary in
                    bank(region: secondary ? queued : current, secondary: secondary)
                }
            }.background(JarasTheme.panel)
        } else {
            HStack(spacing: 1) {
                bank(region: current, secondary: false)
                Rectangle().fill(JarasTheme.secondary.opacity(0.35)).frame(width: 1)
                bank(region: queued, secondary: true)
            }.padding(5).background(JarasTheme.panel)
        }
    }
    private func bank(region: Part?, secondary: Bool) -> some View {
        let markers = region.flatMap { part in show.current?.sectionMarkers(in: part) } ?? []
        let transport = show.snapshot.transport
        let trigger = transport.queuedSectionMarkerId == nil ? nil : show.current?.nextSectionTrigger(for: transport)
        let end = !secondary && transport.playing ? transport.ignoreNextEnd ?? region?.endTime ?? 0 : region?.endTime ?? 0
        return SmoothSeekBankView(title: secondary ? (transport.subPlay.playing ? "Sub Play" : "Queued") : "Playing / Selected",
            name: region?.name ?? "—", markers: markers, end: end,
            position: secondary && transport.subPlay.playing ? transport.subPlay.position : transport.playing ? transport.position : transport.editPosition ?? transport.position,
            showsPosition: !secondary || transport.subPlay.playing, positionRunning: secondary ? transport.subPlay.playing : transport.playing, queued: transport.queuedSectionMarkerId,
            trigger: trigger, queueStartedAt: transport.sectionQueueStartedAt, playbackPosition: transport.position, playbackRunning: transport.playing,
            select: { show.send(.queueSection, target: $0) }, verticalList: verticalList,
            regionID: region?.id, regionStart: region?.startTime ?? 0,
            livePosition: { [weak show] in
                guard let show else { return (0, ProcessInfo.processInfo.systemUptime) }
                return (secondary && show.snapshot.transport.subPlay.playing ? show.snapshot.transport.subPlay.position : show.snapshot.transport.position, show.timelinePlaybackSampleTime)
            }, livePlayback: { [weak show] in
                guard let show else { return (0, ProcessInfo.processInfo.systemUptime) }
                return (show.snapshot.transport.position, show.timelinePlaybackSampleTime)
            })
    }
}

/// Shared native buttons for the Mac and iPad; transport remains authoritative on the Mac.
struct SmoothSeekBankView: View {
    let title: String
    let name: String
    let markers: [TimelineMarker]
    let end: Double
    let position: Double
    let showsPosition: Bool
    let positionRunning: Bool
    let queued: UUID?
    let trigger: Double?
    let queueStartedAt: Double?
    let playbackPosition: Double
    let playbackRunning: Bool
    let select: (UUID) -> Void
    var verticalList = false
    var regionID: UUID? = nil
    var regionStart: Double = 0
    var livePosition: (() -> (position: Double, time: Double))? = nil
    var livePlayback: (() -> (position: Double, time: Double))? = nil
    private var displayMarkers: [TimelineMarker] {
        guard let regionID else { return markers }
        return [TimelineMarker(id: regionID, name: "INÍCIO", position: regionStart, color: 0x409cff, section: true)] + markers
    }
    private var buttonHeight: CGFloat {
        #if os(macOS)
        return 34
        #else
        return 38
        #endif
    }

    var body: some View {
        if verticalList {
            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                    ForEach(displayMarkers) { marker in sectionButton(marker).frame(height: buttonHeight) }
                }.padding(5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(LocalizedStringKey(title)).foregroundStyle(JarasTheme.secondary)
                    Text(verbatim: name).foregroundStyle(JarasTheme.text).lineLimit(1)
                    Spacer(minLength: 0)
                }.font(.system(size: 11, weight: .semibold)).frame(height: 17)
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 4), count: SmoothSeekPanelLayout.columns), spacing: 4) {
                        ForEach(displayMarkers) { marker in sectionButton(marker).frame(height: buttonHeight) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity)
        }
    }
    private func sectionButton(_ marker: TimelineMarker) -> some View {
        let queued = queued == marker.id
        let isStart = marker.id == regionID
        let active = showsPosition && position < end && displayMarkers.last(where: { $0.position <= position })?.id == marker.id
        let selected = queued || (self.queued == nil && active)
        return Button { select(marker.id) } label: {
            ZStack(alignment: .bottomLeading) {
                #if os(iOS)
                RemoteSurface.fill(selected ? JarasTheme.green.opacity(0.35) : isStart ? Color.blue.opacity(0.4) : JarasTheme.display)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(RemoteSurface.edge, lineWidth: 0.5).allowsHitTesting(false))
                #else
                RoundedRectangle(cornerRadius: 5).fill(selected ? JarasTheme.green.opacity(0.35) : isStart ? Color.blue.opacity(0.4) : JarasTheme.display)
                #endif
                if queued, let trigger {
                    SectionCountdownBar(position: playbackPosition, trigger: trigger,
                        startedAt: queueStartedAt, running: playbackRunning, liveSample: livePlayback)
                        .id(trigger)
                        .clipShape(RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
                } else if active, positionRunning {
                    SectionPlaybackBar(position: position, start: marker.position,
                        end: min(end, displayMarkers.first(where: { $0.position > marker.position })?.position ?? end),
                        running: positionRunning, liveSample: livePosition)
                        .clipShape(RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
                }
                HStack(spacing: 2) {
                    if queued { Image(systemName: "arrow.turn.up.left").font(.system(size: 8, weight: .bold)) }
                    Text(verbatim: marker.name.uppercased()).font(.system(size: isStart ? 16 : 12, weight: isStart ? .heavy : .semibold)).lineLimit(nil).multilineTextAlignment(.center).minimumScaleFactor(0.35)
                }.foregroundStyle(Color.white).padding(.horizontal, 3).frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 5).stroke(selected ? JarasTheme.green : isStart ? Color.blue : JarasTheme.line, lineWidth: selected || isStart ? 1.5 : 0.5)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(marker.name.uppercased()).accessibilityValue(queued ? "Queued" : active ? "Playing" : "")
    }
}

/// Only the playing and armed buttons advance between transport packets.
/// Extrapolation is bounded, so a disconnected remote cannot run ahead forever.
private struct SectionPlaybackBar: View {
    let position: Double
    let start: Double
    let end: Double
    let running: Bool
    var liveSample: (() -> (position: Double, time: Double))? = nil
    @State private var sampleTime = ProcessInfo.processInfo.systemUptime
    var body: some View {
        #if os(macOS)
        if let liveSample {
            NativeSectionProgressBar(running: running, countdown: false, start: start, end: end, sample: liveSample)
        } else { fallback }
        #else
        fallback
        #endif
    }
    private var fallback: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { _ in
            let elapsed = running ? min(0.25, max(0, ProcessInfo.processInfo.systemUptime - sampleTime)) : 0
            let fraction = SectionPlaybackProgress.fraction(position: position + elapsed, start: start, end: end)
            GeometryReader { geometry in
                Rectangle().fill(JarasTheme.green)
                    .frame(width: geometry.size.width * fraction, height: 5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear { sampleTime = ProcessInfo.processInfo.systemUptime }
        .onChange(of: position) { _ in sampleTime = ProcessInfo.processInfo.systemUptime }
        .onChange(of: running) { _ in sampleTime = ProcessInfo.processInfo.systemUptime }
    }
}

/// Only the armed button advances at display cadence, between transport packets.
/// A stale connection freezes after 250 ms; it never invents a transport jump.
private struct SectionCountdownBar: View {
    let position: Double
    let trigger: Double
    let startedAt: Double?
    let running: Bool
    var liveSample: (() -> (position: Double, time: Double))? = nil
    @State private var sampleTime = ProcessInfo.processInfo.systemUptime
    @State private var initialPosition: Double?
    @State private var samplePosition: Double?
    var body: some View {
        #if os(macOS)
        if let liveSample {
            NativeSectionProgressBar(running: running, countdown: true, start: startedAt ?? position, end: trigger, sample: liveSample)
        } else { fallback }
        #else
        fallback
        #endif
    }
    private var fallback: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !running)) { _ in
            let elapsed = running && samplePosition != nil ? min(0.25, max(0, ProcessInfo.processInfo.systemUptime - sampleTime)) : 0
            let duration = max(0.001, trigger - (startedAt ?? initialPosition ?? position))
            let remaining = min(1, max(0, (trigger - (samplePosition ?? position) - elapsed) / duration))
            GeometryReader { geometry in
                Rectangle().fill(JarasTheme.yellow)
                    .frame(width: geometry.size.width * remaining, height: 5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear { initialPosition = position; samplePosition = position; sampleTime = ProcessInfo.processInfo.systemUptime }
        .onChange(of: position) { _ in samplePosition = position; sampleTime = ProcessInfo.processInfo.systemUptime }
        .onChange(of: running) { _ in sampleTime = ProcessInfo.processInfo.systemUptime }
    }
}

/// Song tabs stay fixed while the single list of sections scrolls below them.
struct SectionListTabs<Content: View>: View {
    let current: String?
    let queued: String?
    var subPlaying = false
    @ViewBuilder let content: (Bool) -> Content
    @State private var secondary = false
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                tab(current, secondary: false)
                tab(queued, secondary: true)
            }.padding(4)
            content(secondary).id(secondary)
        }.background(JarasTheme.panel)
    }
    private func tab(_ name: String?, secondary target: Bool) -> some View {
        Button { secondary = target } label: {
            VStack(spacing: 3) {
                Text(LocalizedStringKey(target ? (subPlaying ? "Sub Play" : "Queued") : "Playing / Selected"))
                    .font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.5)
                Text(verbatim: name ?? "—").font(.system(size: 12, weight: .semibold))
                    .lineLimit(3).minimumScaleFactor(0.45).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(4).frame(maxWidth: .infinity).frame(height: 42)
                .foregroundStyle(secondary == target ? Color.white : JarasTheme.secondary)
                #if os(iOS)
                .background {
                    RemoteSurface.fill(secondary == target ? (target ? Color.orange : JarasTheme.green).opacity(0.55) : JarasTheme.display)
                }
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(RemoteSurface.edge, lineWidth: 0.5).allowsHitTesting(false))
                #else
                .background(secondary == target ? (target ? Color.orange : JarasTheme.green).opacity(0.55) : JarasTheme.display)
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(name ?? "—").accessibilityValue(secondary == target ? "Selected" : "")
    }
}

/// Resizes only this layout scope. Global gesture coordinates remain stable as
/// the handle moves, so a drag never feeds its own layout changes back as input.
struct SectionListDock<Primary: View, Sections: View>: View {
    let visible: Bool
    let minimumPrimaryWidth: CGFloat
    @AppStorage private var savedFraction: Double
    @State private var liveWidth: CGFloat?
    @State private var dragStart: CGFloat?
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let sections: () -> Sections
    init(visible: Bool, storageKey: String, minimumPrimaryWidth: CGFloat = 140, defaultFraction: Double = 0.45,
         @ViewBuilder primary: @escaping () -> Primary, @ViewBuilder sections: @escaping () -> Sections) {
        self.visible = visible; self.minimumPrimaryWidth = minimumPrimaryWidth
        _savedFraction = AppStorage(wrappedValue: defaultFraction, storageKey)
        self.primary = primary; self.sections = sections
    }
    var body: some View {
        GeometryReader { geometry in
            let total = max(0, geometry.size.width)
            let handle: CGFloat = 12
            let available = max(0, total - handle)
            let width = SmoothSeekPanelLayout.sidebarWidth(available: available,
                requested: liveWidth ?? available * (savedFraction.isFinite ? savedFraction : 0.45), minimumPrimary: minimumPrimaryWidth)
            HStack(spacing: 0) {
                primary().frame(width: visible ? max(0, available - width) : total).clipped()
                if visible {
                    Rectangle().fill(JarasTheme.line)
                        .overlay(Capsule().fill(JarasTheme.secondary).frame(width: 2, height: 32))
                        .frame(width: handle).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStart == nil { dragStart = width }
                                liveWidth = SmoothSeekPanelLayout.sidebarWidth(available: available,
                                    requested: (dragStart ?? width) - value.translation.width, minimumPrimary: minimumPrimaryWidth)
                            }.onEnded { _ in
                                savedFraction = (liveWidth ?? width) / max(1, available)
                                liveWidth = nil; dragStart = nil
                            })
                        .accessibilityLabel("Resize sections")
                        .accessibilityAdjustableAction { direction in
                            savedFraction = SmoothSeekPanelLayout.sidebarWidth(available: available,
                                requested: width + (direction == .increment ? 24 : -24), minimumPrimary: minimumPrimaryWidth) / max(1, available)
                        }
                        #if os(macOS)
                        .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                        .onDisappear { NSCursor.arrow.set() }
                        #endif
                    sections().frame(width: width).clipped()
                }
            }
        }.onChange(of: visible) { _ in liveWidth = nil; dragStart = nil }
    }
}
