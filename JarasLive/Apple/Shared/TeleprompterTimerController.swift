import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Changes are published only for controls and playback edges; the visible
/// displays read a monotonic clock without publishing a project update each tick.
@MainActor final class TeleprompterTimerController: NSObject, ObservableObject {
    static let shared = TeleprompterTimerController()
    @Published private(set) var state: TeleprompterTimer
    private let defaults: UserDefaults
    private let now: () -> Double
    private static let preferenceKey = "jaras.teleprompter.timer"
    private struct Preferences: Codable, Equatable {
        var mode: TeleprompterTimerMode
        var targetSeconds: Int
        var initAutoEnabled: Bool
    }
    #if os(macOS)
    private var configuration: NSPanel?
    #endif
    init(defaults: UserDefaults = .standard, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.now = now
        if let data = defaults.data(forKey: Self.preferenceKey), let saved = try? JSONDecoder().decode(Preferences.self,from: data) {
            state = TeleprompterTimer(mode: .countdown,targetSeconds: saved.targetSeconds,initAutoEnabled: saved.initAutoEnabled)
        } else { state = TeleprompterTimer(mode: .countdown) }
        super.init()
    }
    var running: Bool { state.running }
    var mode: TeleprompterTimerMode { state.mode }
    var targetSeconds: Double { Double(state.targetSeconds) }
    var initAutoEnabled: Bool { state.initAutoEnabled }
    var targetText: String { TeleprompterTimer.formatted(state.targetSeconds) }
    func displayText(spaced: Bool = false) -> String {
        let seconds = state.displaySeconds(at: now())
        let safe = seconds.isFinite ? max(-Double(Int.max / 2), min(Double(Int.max / 2), seconds)) : 0
        return TeleprompterTimer.formatted(Int(ceil(safe)), spaced: spaced)
    }
    func displayOpacity() -> Double {
        expired() && Int(now() * 2) % 2 != 0 ? 0.25 : 1
    }
    func expired() -> Bool { state.isExpired(at: now()) }
    @discardableResult func setTargetText(_ text: String) -> Bool {
        guard !running, let seconds = TeleprompterTimer.targetSeconds(from: text) else { return false }
        change { value in
            value.setMode(.countdown,at: now())
            value.setTarget(seconds: seconds,at: now())
        }
        return true
    }
    func setInitAutoEnabled(_ enabled: Bool) { change { $0.setInitAutoEnabled(enabled) } }
    func start() { change { $0.start(at: now()) } }
    func stopAndReset() { change { $0.stopAndReset() } }
    func observePlayback(_ snapshot: ShowSnapshot) {
        change { $0.observePlayback(project: snapshot.project.id,region: snapshot.transport.regionId,playing: snapshot.transport.playing,paused: snapshot.transport.paused == true,at: now()) }
    }
    private func change(_ mutation: (inout TeleprompterTimer) -> Void) {
        var next = state; mutation(&next)
        guard next != state else { return }
        let old = Preferences(mode: state.mode,targetSeconds: state.targetSeconds,initAutoEnabled: state.initAutoEnabled)
        let saved = Preferences(mode: next.mode,targetSeconds: next.targetSeconds,initAutoEnabled: next.initAutoEnabled)
        state = next
        if saved != old, let encoded = try? JSONEncoder().encode(saved) { defaults.set(encoded,forKey: Self.preferenceKey) }
    }
    func showConfiguration() {
        #if os(macOS)
        if let configuration { configuration.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 380,height: 405),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        panel.title = JarasLocalization.string("Timer")
        panel.contentMinSize = NSSize(width: 340,height: 240); panel.level = .normal; panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: LocalizedTeleprompterTimer(controller: self,close: { [weak panel] in panel?.close() }))
        configuration = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
        #endif
    }
}

#if os(macOS)
extension TeleprompterTimerController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === configuration else { return }
        configuration?.contentView = nil; configuration = nil
    }
}
#endif

private struct LocalizedTeleprompterTimer: View {
    let controller: TeleprompterTimerController
    let close: () -> Void
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        TeleprompterTimerConfiguration(controller: controller,close: close)
            .environment(\.locale,Locale(identifier: language)).preferredColorScheme(.dark)
    }
}

struct TeleprompterTimerConfiguration: View {
    @ObservedObject var controller: TeleprompterTimerController
    let close: () -> Void
    @State private var digits = ["00","00","00"]
    @State private var field = 0
    @State private var caret = 0
    @State private var confirmStop = false
    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now,by: 0.5)) { _ in
                Text(controller.displayText()).font(.system(size: 30,weight: .bold,design: .monospaced))
                    .foregroundStyle(controller.expired() ? Color.red : JarasTheme.green)
                    .opacity(controller.displayOpacity())
                    .frame(maxWidth: .infinity,minHeight: 48).background(JarasTheme.display).cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(JarasTheme.green))
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(0..<3,id: \.self) { index in
                        Button { field = index; caret = 0 } label: {
                            VStack(spacing: 4) {
                                Text(LocalizedStringKey(["Hours","Minutes","Seconds"][index])).font(.caption)
                                Text(digits[index]).font(.system(size: 24,weight: .semibold,design: .monospaced))
                            }.frame(maxWidth: .infinity,minHeight: 52).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(4).background(JarasTheme.display).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(field == index ? JarasTheme.yellow : JarasTheme.line))
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 5),count: 3),spacing: 5) {
                    ForEach(["1","2","3","4","5","6","7","8","9","Clear","0","⌫"],id: \.self) { key in
                        Button { edit(key) } label: { Text(LocalizedStringKey(key)).frame(maxWidth: .infinity,minHeight: 26).contentShape(Rectangle()) }.buttonStyle(.bordered)
                    }
                }
            }
            .disabled(controller.running)
            HStack(spacing: 10) {
                Button(controller.running ? "Stop" : "Start") {
                    if controller.running { confirmStop = true } else { controller.start() }
                }.buttonStyle(.borderedProminent).tint(controller.running ? .red : JarasTheme.green)
                Button("INIT AUTO") { controller.setInitAutoEnabled(!controller.initAutoEnabled) }
                    .buttonStyle(.bordered).tint(controller.initAutoEnabled ? JarasTheme.green : JarasTheme.secondary)
                    .jarasHelp("Start timer automatically when a song starts")
                Spacer(minLength: 0)
                Button("Close",action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(16).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { synchronizeDigits() }
            .onChange(of: controller.targetSeconds) { _ in synchronizeDigits() }
            .alert("Stop timer?",isPresented: $confirmStop) {
                Button("Cancel",role: .cancel) {}
                Button("Stop",role: .destructive) { controller.stopAndReset() }
            } message: { Text("The timer will be reset.") }
    }
    private func synchronizeDigits() { digits = controller.targetText.components(separatedBy: ":") }
    private func edit(_ key: String) {
        var chars = Array(digits[field])
        if key == "Clear" { chars = ["0","0"]; caret = 0 }
        else if key == "⌫" { if caret > 0 { caret -= 1; chars[caret] = "0" } }
        else if let char = key.first {
            if caret == 2 { chars = [chars[1],char] }
            else { chars[caret] = char; caret += 1 }
        }
        digits[field] = String(format: "%02d",min(field == 0 ? 99 : 59,Int(String(chars)) ?? 0))
        controller.setTargetText(digits.joined(separator: ":"))
    }
}
