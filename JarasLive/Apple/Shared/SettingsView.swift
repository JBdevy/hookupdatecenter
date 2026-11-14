import SwiftUI
import CoreAudioKit
struct SettingsView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var show: ShowController
    let backend: any BackendClient
    @AppStorage("jaras.language") private var language = "en"
    #if os(macOS)
    @AppStorage("jaras.startup.sound") private var startupSound = true
    @ObservedObject private var showMode = MacShowMode.shared
    #endif
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @ObservedObject private var recorder = TrackRecording.shared
    private var audioConfigurationLocked: Bool { recorder.recording || recorder.busy || show.isPlaying }
    enum Section: String, CaseIterable { case tp1 = "Config TP 1", tp2 = "Config TP 2", notices = "Config Recados", general = "General", audio = "Audio", midi = "MIDI", smk37 = "SMK37PRO", actions = "Actions", mappings = "Mappings", plugins = "Plugins", account = "Account"
        var icon: String { switch self { case .tp1, .tp2: return "text.alignleft"; case .notices: return "message"; case .general: return "slider.horizontal.3"; case .audio: return "speaker.wave.2"; case .midi, .smk37: return "pianokeys"; case .actions: return "keyboard"; case .mappings: return "switch.2"; case .plugins: return "puzzlepiece.extension"; case .account: return "person.crop.circle" } }
    }
    private var availableSections: [Section] {
        #if os(iOS)
        [.general, .audio, .midi, .actions, .tp1, .tp2, .notices]
        #else
        Section.allCases.filter { ![.tp1, .tp2, .notices].contains($0) }
        #endif
    }
    @ObservedObject private var mappings = ControlMappings.shared
    @State private var localSection: Section
    private var selection: Binding<Section>?
    private var section: Section { selection?.wrappedValue ?? localSection }
    @State private var signingIn = false
    @State private var pendingDevice: AuthorizedDevice?
    init(auth: AuthService, show: ShowController, backend: any BackendClient, initialSection: Section = .general,
         selection: Binding<Section>? = nil) {
        self.auth = auth; self.show = show; self.backend = backend
        self.selection = selection
        _localSection = State(initialValue: initialSection)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(availableSections, id: \.self) { item in
                    Button {
                        if let selection { selection.wrappedValue = item } else { localSection = item }
                    } label: {
                        Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                            .font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(section == item ? JarasTheme.accent.opacity(0.15) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(10).frame(width: 144).background(JarasTheme.panel)
            Divider()
            GeometryReader { viewport in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(LocalizedStringKey(section.rawValue)).font(.jarasTitle2.bold())
                    switch section {
                    case .tp1, .tp2:
                        TeleprompterConfig(embedded: true, preferences: section == .tp1 ? .shared : .second, close: {})
                            .frame(height: max(400, viewport.size.height - 90))
                    case .notices:
                        TPNoticeSettingsView()
                    case .general:
                        Text("Language").font(.jarasHeadline)
                        Picker("Language", selection: $language) { Text("English").tag("en"); Text("Português").tag("pt-BR") }.pickerStyle(.segmented).labelsHidden()
                        #if os(macOS)
                        Text("Startup sound").font(.jarasHeadline)
                        Picker("Startup sound", selection: $startupSound) {
                            Text("Disabled").tag(false)
                            Text("Enabled").tag(true)
                        }.labelsHidden().frame(width: 176)
                        Text("Show Mode").font(.jarasHeadline)
                        Picker("Show Mode", selection: Binding(get: { showMode.enabled }, set: { showMode.setEnabled($0) })) {
                            Text("Disabled").tag(false)
                            Text("Enabled").tag(true)
                        }.labelsHidden().frame(width: 176).disabled(showMode.busy || !showMode.loaded)
                        Text("When enabled, the Mac lid can be closed without stopping playback.")
                            .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if showMode.busy { ProgressView().controlSize(.small) }
                        if !showMode.error.isEmpty {
                            Text(verbatim: showMode.error).font(.jarasCaption).foregroundStyle(.red)
                            Button("Retry") { showMode.refresh() }
                        }
                        Color.clear.frame(height: 0).task { showMode.refresh() }
                        #endif
                    case .audio:
                        if audioConfigurationLocked {
                            Label("Stop the transport before changing the audio device.", systemImage: "pause.circle.fill")
                                .font(.jarasCallout.weight(.medium)).foregroundStyle(JarasTheme.yellow)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                        Text("Audio device — Input").font(.jarasHeadline)
                        Picker("Audio device — Input", selection: Binding(get: { audio.inputSelection }, set: { if !audioConfigurationLocked { audio.selectInput($0) } })) {
                            Text(verbatim: "None").tag("")
                            #if os(macOS)
                            Text("System default").tag(AudioDeviceSettings.systemDefaultUID)
                            #endif
                            if !audio.inputUID.isEmpty && audio.inputDevice == nil { Text("Disconnected").tag(audio.inputUID) }
                            ForEach(audio.inputDevices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().frame(maxWidth: .infinity).disabled(audioConfigurationLocked)
                        #if os(iOS)
                        if audio.inputUID == AudioDeviceSettings.bluetoothMobileInput {
                            Text("Using the Bluetooth microphone may reduce headset playback quality.")
                                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        }
                        #endif
                        if audio.usesSystemLoopback {
                            Text("Captura o áudio do Mac. Monitor Off silencia o retorno, mantendo a gravação e os meters de entrada.")
                                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        }
                        Text("Audio device — Output").font(.jarasHeadline)
                        Picker("Output device", selection: Binding(get: { audio.outputSelection }, set: { if !audioConfigurationLocked { audio.select($0) } })) {
                            Text(verbatim: "None").tag("none")
                            Text("System default").tag(AudioDeviceSettings.systemDefaultUID)
                            if !audio.selectedUID.isEmpty && audio.selectedUID != "none" && !audio.devices.contains(where: { $0.id == audio.selectedUID }) {
                                Text("Disconnected").tag(audio.selectedUID)
                            }
                            ForEach(audio.devices) { device in Text(device.name).tag(device.id) }
                        }.labelsHidden().frame(maxWidth: .infinity).disabled(audioConfigurationLocked)
                        Text("\(audio.channels) output channels").foregroundStyle(JarasTheme.secondary)
                        Text("Sample rate").font(.jarasHeadline)
                        Picker("Sample rate", selection: Binding(get: { audio.sampleRate }, set: { if !audioConfigurationLocked { audio.setSampleRate($0) } })) {
                            ForEach(audio.sampleRateChoices, id: \.self) { rate in Text(String(format: "%.0f Hz", rate)).tag(rate) }
                        }.labelsHidden().disabled(audioConfigurationLocked)
                        Text("Buffer size").font(.jarasHeadline)
                        Picker("Buffer size", selection: Binding(get: { audio.bufferFrames }, set: { if !audioConfigurationLocked { audio.setBuffer($0) } })) {
                            ForEach(audio.bufferChoices, id: \.self) { frames in Text("\(frames) samples").tag(frames) }
                        }.labelsHidden().disabled(audioConfigurationLocked)
                        Text("Smaller buffers reduce latency and use more CPU.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        Button("Refresh devices") { audio.refresh(); audio.refreshSampleRate(); audio.refreshBuffer() }
                        if !audio.error.isEmpty { Text(LocalizedStringKey(audio.error)).foregroundStyle(.red).font(.jarasCaption) }
                        }
                    case .midi:
                        BluetoothMIDIConnectionButton { audio.refreshMIDI() }
                        Text("MIDI inputs").font(.jarasHeadline)
                        if audio.midiSources.isEmpty { Text("No MIDI inputs").foregroundStyle(JarasTheme.secondary) }
                        ForEach(0..<6, id: \.self) { slot in
                            Picker("MIDI \(slot + 1)", selection: Binding(get: { audio.midiSlots[slot] }, set: { audio.selectMIDI($0, slot: slot) })) {
                                Text("None").tag(Int32(0))
                                if audio.midiSlots[slot] != 0 && !audio.midiDevices.contains(where: { $0.id == audio.midiSlots[slot] }) {
                                    Text(audio.midiSlotTitle(slot)).tag(audio.midiSlots[slot])
                                }
                                ForEach(audio.midiDevices.filter { device in !audio.midiSlots.enumerated().contains { $0.offset != slot && $0.element == device.id } }) { device in Text(device.name).tag(device.id) }
                            }.padding(10).background(JarasTheme.panel).cornerRadius(6)
                        }
                        Text("MIDI output").font(.jarasHeadline)
                        ForEach(0..<6, id: \.self) { slot in
                            Picker("MIDI \(slot + 1)", selection: Binding(get: { audio.midiOutputSlots[slot] }, set: { audio.selectMIDIOutput($0, slot: slot) })) {
                                Text("None").tag(Int32(0))
                                if audio.midiOutputSlots[slot] != 0 && !audio.midiOutputs.contains(where: { $0.id == audio.midiOutputSlots[slot] }) {
                                    Text(audio.midiOutputSlotTitle(slot)).tag(audio.midiOutputSlots[slot])
                                }
                                ForEach(audio.midiOutputs) { device in Text(device.name).tag(device.id) }
                            }.padding(10).background(JarasTheme.panel).cornerRadius(6)
                        }
                        if audio.midiOutputs.isEmpty { Text("No MIDI outputs").foregroundStyle(JarasTheme.secondary) }
                        Button("Refresh devices") { audio.refreshMIDI() }
                    case .smk37:
                        #if os(macOS)
                        SMK37FirmwareView(isLocked: { show.isPlaying || recorder.recording || recorder.busy })
                        #else
                        EmptyView()
                        #endif
                    case .actions:
                        DAWActionsList(show: show)
                    case .mappings:
                        ControlMappingsList()
                    case .plugins:
                        #if os(macOS)
                        PluginSettings()
                        #else
                        Text("VST3 plugins are available on desktop.").foregroundStyle(JarasTheme.secondary)
                        #endif
                    case .account:
                        Text(auth.licenseTitle ?? "Entre na sua conta").font(.jarasHeadline)
                        if let result = auth.loginResult, result.entitlement.planId != "trial" {
                            Text(result.account.email).foregroundStyle(JarasTheme.secondary)
                        }
                        Button("Login / Trocar conta") { signingIn = true }.buttonStyle(StageButtonStyle()).disabled(auth.busy || show.isPlaying)
                        Text("\(auth.devices.filter { $0.status == .active }.count) / \(auth.loginResult?.entitlement.maxDevices ?? 4) dispositivos").font(.jarasCaption)
                        ForEach(auth.devices.filter { $0.status == .active }) { device in
                            DeviceAccountRow(device: device, current: device.id == auth.installation.id) { pendingDevice = device }.disabled(auth.busy)
                        }
                        Button("Atualizar dispositivos") { Task { await auth.refreshDevices() } }.disabled(auth.busy)
                        Button("Sair e liberar dispositivo") { Task { await auth.logout() } }.buttonStyle(StageButtonStyle(color: .red)).disabled(show.isPlaying || auth.busy)
                        if !auth.message.isEmpty { Text(LocalizedStringKey(auth.message)).font(.jarasCaption).foregroundStyle(JarasTheme.yellow) }
                    }
                }.padding(24).frame(width: viewport.size.width, alignment: .leading)
            }
            }
        }.foregroundStyle(JarasTheme.text)
        .sheet(isPresented: $signingIn) {
            LoginView(auth: auth, backend: backend, offersTrial: false, onAuthorized: { signingIn = false }).frame(width: 550, height: 620)
        }
        .onDisappear { mappings.editing = nil }
        .task(id: section) { if section == .account { await auth.refreshDevices() } }
        .alert("Remover dispositivo?", isPresented: Binding(get: { pendingDevice != nil }, set: { if !$0 { pendingDevice = nil } }), presenting: pendingDevice) { device in
            Button("Cancelar", role: .cancel) { pendingDevice = nil }
            Button("Remover", role: .destructive) { Task { await auth.removeDevice(device) }; pendingDevice = nil }
        } message: { device in
            Text(device.id == auth.installation.id ? "Você sairá da conta neste computador. O áudio será interrompido e a licença ficará disponível." : "Remover \(device.deviceName) e liberar sua licença para outro computador?")
        }
        .overlay {
            if mappings.editing != nil && mappings.editing?.presentedInline != true {
                ZStack { Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { mappings.editing = nil }; ControlMappingEditor() }
            }
        }
    }
}

#if os(macOS)
import IOKit
import IOKit.pwr_mgt
import CoreGraphics
import Darwin

/// Lid notifications and backlight changes are independent of audio and UI ticks.
@MainActor final class MacShowLidBrightness {
    static let shared = MacShowLidBrightness()
    struct Backend {
        var displays: () -> [UInt32]
        var read: (UInt32) -> Float?
        var write: (UInt32, Float) -> Bool
    }
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private static let nativeBackend = Backend(displays: {
        var values = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &values, &count) == .success else { return [] }
        return values.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }, read: { display in
        guard let library = displayServices, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        typealias Read = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        var value: Float = 0
        guard unsafeBitCast(symbol, to: Read.self)(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }, write: { display, value in
        guard let library = displayServices, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return false }
        typealias Write = @convention(c) (UInt32, Float) -> Int32
        return unsafeBitCast(symbol, to: Write.self)(display, value) == 0
    })
    private let backend: Backend
    private let watchesHardware: Bool
    private var enabled = false
    private var closed = false
    private var knownDisplays = Set<UInt32>()
    private var saved: [UInt32: Float] = [:]
    private var notificationPort: IONotificationPortRef?
    private var root: io_service_t = 0
    private var notifier: io_object_t = 0
    private var wakeObservers: [NSObjectProtocol] = []
    init(backend: Backend? = nil, watchesHardware: Bool = true) {
        self.backend = backend ?? Self.nativeBackend; self.watchesHardware = watchesHardware
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            knownDisplays.formUnion(backend.displays())
            if watchesHardware { startNotifications() }
        } else {
            restore()
            stopNotifications()
        }
    }
    func lidChanged(closed: Bool) {
        self.closed = closed
        guard enabled else { return }
        if closed {
            knownDisplays.formUnion(backend.displays())
            for display in knownDisplays where saved[display] == nil {
                guard let original = backend.read(display), backend.write(display, 0) else { continue }
                saved[display] = original
            }
        } else { restore() }
    }
    func stop() { enabled = false; restore(); stopNotifications() }
    private func restore() {
        for (display, original) in saved {
            // A manual brightness adjustment takes precedence over our restore.
            if let current = backend.read(display), current > 0.002 { saved.removeValue(forKey: display); continue }
            if backend.write(display, original) { saved.removeValue(forKey: display) }
        }
    }
    private func startNotifications() {
        guard notificationPort == nil else { return }
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { stopNotifications(); return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, type, argument in
            // IOPM.h: iokit_family_msg(sub_iokit_powermanagement, 0x100).
            // Swift cannot import that function-like C macro.
            guard type == ((UInt32(0x38) << 26) | (UInt32(13) << 14) | 0x100), let context else { return }
            let closed = UInt(bitPattern: argument) & UInt(kClamshellStateBit) != 0
            MainActor.assumeIsolated { Unmanaged<MacShowLidBrightness>.fromOpaque(context).takeUnretainedValue().lidChanged(closed: closed) }
        }, context, &notifier)
        guard status == KERN_SUCCESS else { stopNotifications(); return }
        if let state = IORegistryEntryCreateCFProperty(root, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            lidChanged(closed: state)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.lidChanged(closed: self.closed) } }
            })
        }
    }
    private func stopNotifications() {
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let notificationPort { IONotificationPortDestroy(notificationPort); self.notificationPort = nil }
        if root != 0 { IOObjectRelease(root); root = 0 }
        wakeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); wakeObservers.removeAll()
    }
}

/// The same persistent pmset switch used by Hook Center. Query first: another
/// application may already have changed this computer-wide setting.
@MainActor final class MacShowMode: ObservableObject {
    static let shared = MacShowMode()
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published private(set) var error = ""
    typealias Runner = @Sendable (String, [String]) throws -> String
    private let run: Runner
    private let brightnessEnabled: @MainActor (Bool) -> Void
    init(run: @escaping Runner = { try MacShowMode.execute($0, $1) }, brightnessEnabled: @escaping @MainActor (Bool) -> Void = { MacShowLidBrightness.shared.setEnabled($0) }) {
        self.run = run; self.brightnessEnabled = brightnessEnabled
    }
    nonisolated static func isEnabled(_ output: String) -> Bool {
        output.range(of: #"\b(?:SleepDisabled|disablesleep)\s+1\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    func refresh() { update(nil) }
    func setEnabled(_ value: Bool) { update(value) }
    private func update(_ desired: Bool?) {
        guard !busy else { return }
        busy = true; error = ""
        let run = self.run
        Task {
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    if let desired {
                        _ = try run("/usr/bin/osascript", ["-e", "do shell script \"/usr/bin/pmset -a disablesleep \(desired ? 1 : 0)\" with administrator privileges"])
                    }
                    let active = Self.isEnabled(try run("/usr/bin/pmset", ["-g"]))
                    if let desired, active != desired {
                        throw NSError(domain: "CatLive.ShowMode", code: 1, userInfo: [NSLocalizedDescriptionKey: JarasLocalization.string("The system did not confirm the Show Mode change.")])
                    }
                    return active
                }.value
                enabled = value; loaded = true; brightnessEnabled(value)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    nonisolated static func execute(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), failure = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = failure
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: failure.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CatLive.ShowMode", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Unable to change Show Mode." : error])
        }
        return text
    }
}
#endif


#if os(macOS)
/// CoreAudioKit creates a normal-level window; workspace tools use a higher
/// app-local level. Keep the browser above its owning tool and fixed in size.
@MainActor private final class MacBluetoothMIDIBrowser: ObservableObject {
    private let controller = CABTLEMIDIWindowController()
    private weak var owner: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var onDismiss: (() -> Void)?

    init() {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notice in
            guard let self, let window = notice.object as? NSWindow else { return }
            if window === self.controller.window { self.onDismiss?() }
            else if window === self.owner { self.close() }
        }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    func show(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        if NSApp.keyWindow !== controller.window { owner = NSApp.keyWindow }
        guard let window = controller.window else { return }
        let wasVisible = window.isVisible
        window.identifier = NSUserInterfaceItemIdentifier("catlive.tool.bluetoothMIDI")
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.hidesOnDeactivate = true
        window.styleMask.remove([.resizable, .miniaturizable])
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        let available = owner?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 940, height: 580)
        let size = NSSize(width: min(940, available.width), height: min(540, max(240, available.height - 32)))
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        window.level = NSWindow.Level(rawValue: max(owner?.level.rawValue ?? 0, ProjectionWindow.workspaceToolLevel.rawValue) + 1)
        ProjectionWindow.followWorkspaceWindow(window)
        if !wasVisible {
            let anchor = owner?.frame ?? available
            let x = min(max(available.minX, anchor.midX - window.frame.width / 2), available.maxX - window.frame.width)
            let y = min(max(available.minY, anchor.midY - window.frame.height / 2), available.maxY - window.frame.height)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
    func close() { controller.close() }
}
#endif

/// Pair with the system's BLE MIDI browser so CoreMIDI creates actual endpoints.
/// Ordinary Bluetooth audio pairing does not necessarily create MIDI ports.
struct BluetoothMIDIConnectionButton: View {
    var onDismiss: () -> Void
    #if os(iOS)
    @State private var presenting = false
    #else
    @StateObject private var browser = MacBluetoothMIDIBrowser()
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Connect Bluetooth MIDI…") {
                #if os(iOS)
                presenting = true
                #else
                browser.show(onDismiss: onDismiss)
                #endif
            }.buttonStyle(.bordered)
            Text("Connect your MIDI controller here, even if it is already paired in Bluetooth settings.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if os(iOS)
        .background(BluetoothMIDIBrowserPresenter(isPresented: $presenting, onDismiss: onDismiss)
            .frame(width: 0, height: 0).allowsHitTesting(false))
        #else
        .onDisappear { browser.close() }
        #endif
    }
}
#if os(iOS)
private struct BluetoothMIDIBrowserPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> BluetoothMIDIBrowserHost { BluetoothMIDIBrowserHost() }
    func updateUIViewController(_ controller: BluetoothMIDIBrowserHost, context: Context) {
        controller.onDismiss = {
            isPresented = false
            onDismiss()
        }
        controller.setPresented(isPresented)
    }
    static func dismantleUIViewController(_ controller: BluetoothMIDIBrowserHost, coordinator: ()) {
        controller.onDismiss = nil
        controller.setPresented(false, animated: false)
    }
}

/// CoreAudioKit owns a UIKit browser. Keep its navigation and dismissal in
/// UIKit too: dismissing the old nested SwiftUI NavigationStack could leave
/// its sheet presenter occupied on iOS 16, preventing the next opening.
private final class BluetoothMIDIBrowserHost: UIViewController, UIAdaptivePresentationControllerDelegate {
    var onDismiss: (() -> Void)?
    private var wantsPresentation = false
    private var browser: BluetoothMIDINavigationController?
    private var closing = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        openIfNeeded()
    }

    func setPresented(_ presented: Bool, animated: Bool = true) {
        wantsPresentation = presented
        if presented {
            openIfNeeded()
        } else if let browser, !closing {
            closing = true
            browser.dismiss(animated: animated) { [weak self, weak browser] in
                if let browser { self?.didClose(browser) }
            }
        }
    }

    private func openIfNeeded() {
        guard wantsPresentation, browser == nil, !closing, viewIfLoaded?.window != nil,
              presentedViewController == nil else { return }
        let central = CABTMIDICentralViewController()
        central.title = "Bluetooth MIDI"
        central.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
            target: self, action: #selector(closeBrowser))
        let navigation = BluetoothMIDINavigationController(rootViewController: central)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 600, height: 520)
        navigation.didDismiss = { [weak self, weak navigation] in
            guard let navigation else { return }
            // Release the old presenter only after UIKit has finished closing.
            DispatchQueue.main.async { [weak self, weak navigation] in
                if let navigation { self?.didClose(navigation) }
            }
        }
        browser = navigation
        navigation.presentationController?.delegate = self
        present(navigation, animated: true)
    }

    @objc private func closeBrowser() { setPresented(false) }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let navigation = presentationController.presentedViewController as? BluetoothMIDINavigationController {
            didClose(navigation)
        }
    }

    private func didClose(_ navigation: BluetoothMIDINavigationController) {
        guard browser === navigation else { return }
        navigation.didDismiss = nil
        browser = nil
        closing = false
        wantsPresentation = false
        onDismiss?()
    }
}

private final class BluetoothMIDINavigationController: UINavigationController {
    var didDismiss: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { didDismiss?() }
    }
}
#endif
