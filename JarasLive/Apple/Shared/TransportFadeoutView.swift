import SwiftUI
import Combine

struct TransportFadeoutSettings: View {
    let show: ShowController
    @ObservedObject private var fadeout: TransportFadeout
    @ObservedObject private var mappings = ControlMappings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mappingKind = "keyboard"
    init(show: ShowController) { self.show = show; _fadeout = ObservedObject(wrappedValue: show.transportFadeout) }
    private func update(enabled: Bool? = nil, duration: Double? = nil, tracks: Set<UUID>? = nil) {
        show.configureTransportFadeout(enabled: enabled ?? fadeout.enabled, duration: duration ?? fadeout.duration, tracks: tracks ?? fadeout.trackIDs)
    }
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Fadeout", isOn: Binding(get: { fadeout.enabled }, set: { update(enabled: $0) }))
                    .font(.jarasHeadline)
                HStack {
                    Text("Duration")
                    Spacer()
                    Picker("Duration", selection: Binding(get: { Int(fadeout.duration) }, set: { update(duration: Double($0)) })) {
                        ForEach(1...5, id: \.self) { Text(verbatim: "\($0) s").tag($0) }
                    }.labelsHidden().frame(width: 90)
                }
                HStack {
                    Text("Tracks").font(.jarasHeadline)
                    Spacer()
                    Button("All") { update(tracks: Set(show.fadeoutTracks.map(\.id))) }
                    Button("None") { update(tracks: []) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(show.fadeoutTracks) { track in
                            Toggle(isOn: Binding(get: { fadeout.trackIDs.contains(track.id) }, set: { checked in
                                var ids = fadeout.trackIDs
                                if checked { ids.insert(track.id) } else { ids.remove(track.id) }
                                update(tracks: ids)
                            })) { Text(verbatim: track.name).lineLimit(1) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 200).background(JarasTheme.display).cornerRadius(6)
                Picker("Input", selection: $mappingKind) {
                    Text("Keyboard").tag("keyboard")
                    Text("MIDI").tag("midi")
                }.pickerStyle(.segmented)
                HStack {
                    Text(mappingKind == "midi" ? "MIDI" : "Keyboard")
                    Spacer()
                    let binding = mappings.actions.binding(.transportFadeout)
                    let input = mappingKind == "midi" ? binding.midi : binding.keyboard
                    Button(input?.label ?? "—") {
                        mappings.beginAction(.transportFadeout, kind: mappingKind)
                    }.frame(minWidth: 100)
                    Button("Clear") { mappings.removeActionInput(.transportFadeout, kind: mappingKind) }
                        .disabled(input == nil)
                }
                Text(mappingKind == "midi" ? "Press a MIDI note or controller button." : "Choose an unused shortcut. Space and standard shortcuts cannot control Fadeout.")
                    .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                Text("Use the same key or MIDI control again to cancel Fadeout and restore the volumes.")
                    .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }.padding(22).frame(width: 400).background(JarasTheme.panel)
                .disabled(mappings.editing != nil || fadeout.run != nil)
            if mappings.editing?.action == .transportFadeout { ControlMappingEditor() }
        }.onDisappear { if mappings.editing?.action == .transportFadeout { mappings.editing = nil } }
    }
}

#if os(macOS)
import AppKit

/// Nonactivating child panels leave keyboard shortcuts with the main window.
/// Countdown and warning occupy different edges, so a Sub Play warning never
/// conceals the time remaining or intercepts the repeat-to-cancel action.
struct TransportFadeoutPresenter: NSViewRepresentable {
    let show: ShowController
    func makeNSView(context: Context) -> FadeoutPresentationAnchor {
        let view = FadeoutPresentationAnchor(); view.bind(show); return view
    }
    func updateNSView(_ view: FadeoutPresentationAnchor, context: Context) { view.bind(show) }
    static func dismantleNSView(_ view: FadeoutPresentationAnchor, coordinator: ()) { view.close() }
}
final class FadeoutPresentationAnchor: NSView {
    private weak var show: ShowController?
    private var subscriptions = Set<AnyCancellable>()
    private var windowObservers: [NSObjectProtocol] = []
    private var progress: NSPanel?
    private var countdownHost: NSHostingView<FadeoutCountdown>?
    private var warning: NSPanel?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func bind(_ show: ShowController) {
        guard self.show !== show else { return }
        self.show = show; subscriptions.removeAll()
        show.transportFadeout.$run.sink { [weak self] run in self?.updateProgress(run) }.store(in: &subscriptions)
        show.transportFadeout.$notice.sink { [weak self] message in self?.updateWarning(message) }.store(in: &subscriptions)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers = []
        guard let window else { closePanels(); return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.positionPanels() }
            })
        }
        updateProgress(show?.transportFadeout.run); updateWarning(show?.transportFadeout.notice)
    }
    private func panel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = true; panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        return panel
    }
    private func updateProgress(_ run: TransportFadeout.Run?) {
        guard let window, let run else { if let progress { progress.parent?.removeChildWindow(progress); progress.orderOut(nil) }; return }
        if progress == nil { progress = panel(size: NSSize(width: 230, height: 104)) }
        guard let progress else { return }
        if let countdownHost { countdownHost.rootView = FadeoutCountdown(run: run) }
        else {
            let host = NSHostingView(rootView: FadeoutCountdown(run: run))
            countdownHost = host; progress.contentView = host
        }
        if progress.parent !== window { progress.parent?.removeChildWindow(progress); window.addChildWindow(progress, ordered: .above) }
        positionPanels(); if !progress.isVisible, NSApp.isActive { progress.orderFront(nil) }
    }
    private func updateWarning(_ message: String?) {
        guard let window, let message else { if let warning { warning.parent?.removeChildWindow(warning); warning.orderOut(nil) }; return }
        if warning == nil { warning = panel(size: NSSize(width: 400, height: 58)) }
        guard let warning else { return }
        warning.contentView = NSHostingView(rootView:
            Text(LocalizedStringKey(message)).font(.jarasSystem(size: 13, weight: .semibold))
                .foregroundStyle(JarasTheme.yellow).multilineTextAlignment(.center)
                .padding(12).frame(width: 400, height: 58).background(.ultraThinMaterial).cornerRadius(12))
        if warning.parent !== window { warning.parent?.removeChildWindow(warning); window.addChildWindow(warning, ordered: .above) }
        positionPanels(); if !warning.isVisible, NSApp.isActive { warning.orderFront(nil) }
    }
    private func positionPanels() {
        guard let window else { return }
        let frame = window.contentLayoutRect.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        progress?.setFrameOrigin(NSPoint(x: max(frame.minX + 12, frame.maxX - 246), y: frame.minY + 18))
        warning?.setFrameOrigin(NSPoint(x: frame.midX - 200, y: frame.maxY - 78))
    }
    private func closePanels() {
        for panel in [progress, warning].compactMap({ $0 }) { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    }
    func close() {
        subscriptions.removeAll(); closePanels()
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }; windowObservers = []
    }
}
private struct FadeoutCountdown: View {
    let run: TransportFadeout.Run
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(verbatim: "Fadeout").font(.jarasSystem(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: String(format: "%.1f s", ceil(max(0, run.remaining - 0.000001) * 10) / 10))
                    .font(.jarasSystem(size: 23, weight: .semibold, design: .monospaced))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(JarasTheme.yellow).frame(width: proxy.size.width * run.fraction)
                }
            }.frame(height: 6)
        }.padding(16).frame(width: 230, height: 104).background(.ultraThinMaterial).cornerRadius(12)
    }
}
#endif
