import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Transport updates stay in this small panel, independently of the grid canvas.
struct SmoothSeekPanel: View {
    @ObservedObject var show: ShowController
    var verticalList = false
    var body: some View {
        let transport = show.snapshot.transport
        let current = show.current.flatMap { song in
            transport.playing ? song.sectionRegion(at: transport.position) :
                song.parts.first(where: { $0.id == show.focusedRegion }) ?? song.sectionRegion(at: transport.editPosition ?? transport.position)
        }
        let queued = show.current.flatMap { song in
            transport.subPlay.playing ? song.sectionRegion(at: transport.subPlay.position) :
                song.parts.first(where: { $0.id == transport.queuedRegionId })
        }
        if verticalList {
            SectionListTabs(current: current?.displayName, queued: queued?.displayName, subPlaying: transport.subPlay.playing) { secondary in
                bank(region: secondary ? queued : current, secondary: secondary)
            }
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
        let trigger = show.current?.sectionRegion(at: transport.position).flatMap { part in
            show.current?.sectionMarkers(in: part).first(where: { $0.position > transport.position + 0.000001 })?.position
        }
        return SmoothSeekBankView(title: secondary ? (transport.subPlay.playing ? "Sub Play" : "Queued") : "Playing / Selected",
            name: region?.name ?? "—", markers: markers, end: region?.endTime ?? 0,
            position: secondary && transport.subPlay.playing ? transport.subPlay.position : transport.playing ? transport.position : transport.editPosition ?? transport.position,
            showsPosition: !secondary || transport.subPlay.playing, positionRunning: secondary ? transport.subPlay.playing : transport.playing, queued: transport.queuedSectionMarkerId,
            trigger: trigger, queueStartedAt: transport.sectionQueueStartedAt, playbackPosition: transport.position, playbackRunning: transport.playing,
            select: { show.send(.queueSection, target: $0) }, verticalList: verticalList,
            regionID: region?.id, regionStart: region?.startTime ?? 0)
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
                RoundedRectangle(cornerRadius: 5).fill(selected ? JarasTheme.green.opacity(0.35) : isStart ? Color.blue.opacity(0.4) : JarasTheme.display)
                if queued, let trigger {
                    SectionCountdownBar(position: playbackPosition, trigger: trigger,
                        startedAt: queueStartedAt, running: playbackRunning)
                        .id(trigger)
                        .clipShape(RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
                } else if active, positionRunning {
                    SectionPlaybackBar(position: position, start: marker.position,
                        end: displayMarkers.first(where: { $0.position > marker.position })?.position ?? end,
                        running: positionRunning)
                        .clipShape(RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
                }
                HStack(spacing: 2) {
                    if queued { Image(systemName: "arrow.turn.up.left").font(.system(size: 8, weight: .bold)) }
                    Text(verbatim: marker.name.uppercased()).font(.system(size: isStart ? 16 : 12, weight: isStart ? .heavy : .semibold)).lineLimit(nil).multilineTextAlignment(.center).minimumScaleFactor(0.35)
                }.foregroundStyle(Color.white).padding(.horizontal, 3).frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 5).stroke(selected ? JarasTheme.green : isStart ? Color.blue : JarasTheme.line, lineWidth: selected || isStart ? 1.5 : 0.5)
            }
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
    @State private var sampleTime = ProcessInfo.processInfo.systemUptime
    var body: some View {
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
    @State private var sampleTime = ProcessInfo.processInfo.systemUptime
    @State private var initialPosition: Double?
    @State private var samplePosition: Double?
    var body: some View {
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
                .background(secondary == target ? (target ? Color.orange : JarasTheme.green).opacity(0.55) : JarasTheme.display)
                .clipShape(RoundedRectangle(cornerRadius: 5))
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
