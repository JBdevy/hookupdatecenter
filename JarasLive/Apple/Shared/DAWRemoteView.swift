import SwiftUI
import UniformTypeIdentifiers
import Combine
#if os(iOS)
import UIKit
import CoreMIDI
import GameController
#endif
struct DAWRemoteHostView: View {
    @ObservedObject var remote: DAWRemoteSession = .shared
    @State private var pin = ""
    @State private var saved = false
    @State private var noticesPIN = ""
    @State private var noticesSaved = false
    var body: some View {
        ScrollView { hostContent }.frame(width: 420).frame(maxHeight: 720)
    }
    private var hostContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Remote").font(.jarasHeadline)
            #if os(macOS)
            Text("Open Remote on your device and choose this computer.").font(.jarasCallout)
            #else
            Text("Open Remote on another device and choose this iPad.").font(.jarasCallout)
            #endif
            Text(LocalizedStringKey(remote.status)).font(.jarasCaption).foregroundStyle(remote.connected ? JarasTheme.green : JarasTheme.secondary)
            if !remote.peerName.isEmpty { Text(verbatim: remote.peerName).font(.jarasCaption) }
            #if os(macOS)
            Text("Audio continues on the Mac. Nearby Apple devices can connect directly over peer-to-peer Wi-Fi.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            #else
            Text("Audio continues on this iPad. Use the same local network or a direct connection between nearby Apple devices.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            #endif
            Divider()
            Text("Senha do modo Diretor").font(.jarasHeadline)
            Text(remote.directorRequiresPIN ? "O Diretor está protegido por senha." : "O Diretor está liberado sem senha.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            TextField("4 dígitos · vazio para remover", text: $pin)
                .textFieldStyle(.roundedBorder)
                .onChange(of: pin) { value in pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)); saved = false }
            Text("Deixe vazio e salve para entrar sem senha. Observadores entram sem senha e não controlam o PC.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            Button("Salvar senha") { saved = remote.setDirectorPIN(pin) }
                .disabled(!pin.isEmpty && pin.count != 4)
            if saved { Text("Configuração salva.").font(.jarasCaption).foregroundStyle(JarasTheme.green) }
            Divider()
            Text("Senha do modo Recados").font(.jarasHeadline)
            TextField("4 dígitos · vazio para remover", text: $noticesPIN)
                .textFieldStyle(.roundedBorder)
                .onChange(of: noticesPIN) { value in noticesPIN = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)); noticesSaved = false }
            Text("Acesso apenas aos recados. Deixe vazio para entrar sem senha.")
                .font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
            Button("Salvar senha de Recados") { noticesSaved = remote.setNoticesPIN(noticesPIN) }
                .disabled(!noticesPIN.isEmpty && noticesPIN.count != 4)
            if noticesSaved { Text("Configuração salva.").font(.jarasCaption).foregroundStyle(JarasTheme.green) }
            #if os(macOS)
            Divider()
            ProjectSyncPanel()
            #endif
            if remote.enabled { Button("Disable Remote") { remote.setHostEnabled(false) } }
        }.padding(20).frame(maxWidth: 420).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { pin = remote.savedDirectorPIN; noticesPIN = remote.savedNoticesPIN }
    }
}
#if os(iOS)
/// Phones connect to the Mac without starting a local project/audio engine.
struct PhoneRemoteHomeView: View {
    @AppStorage("jaras.language") private var language = "en"
    @State private var entering = false
    @State private var starting = true
    var body: some View {
        ZStack {
            RemoteSurface.background.ignoresSafeArea()
            if starting { StartupView(progress: nil, stage: "Iniciando…") }
            else {
                VStack(spacing: 24) {
                    Spacer()
                    Image("CatLiveSplash").resizable().scaledToFit().frame(width: 180, height: 180)
                    Text("Remote").font(.jarasTitle2.bold()).foregroundStyle(JarasTheme.green)
                    Text("Control or follow your PC’s session.").multilineTextAlignment(.center).foregroundStyle(JarasTheme.secondary)
                    Button { entering = true } label: {
                        Text("Connect to PC").font(.jarasHeadline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(.black)
                            .modifier(RemoteControlSurface(color: JarasTheme.green, radius: 10))
                    }.buttonStyle(RemoteFullAreaButtonStyle())
                        .accessibilityIdentifier("remote-connect-to-pc")
                    Picker("Language", selection: $language) {
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Português").tag("pt-BR")
                    }.pickerStyle(.segmented)
                    Spacer()
                }.padding(28).frame(maxWidth: 420)
            }
        }.preferredColorScheme(.dark).environment(\.locale, Locale(identifier: language))
            .fullScreenCover(isPresented: $entering) { DAWRemoteClientView().environment(\.locale, Locale(identifier: language)) }
            .task {
                do { try await Task.sleep(nanoseconds: 3_000_000_000); starting = false } catch {}
            }
    }
}
private struct RemoteProjectTabStrip: View {
    let tabs: [DAWRemoteState.ProjectTab]
    let enabled: Bool
    let select: (UUID) -> Void
    var body: some View {
        HStack(spacing: 1) {
            ForEach(tabs) { tab in
                Button { select(tab.id) } label: {
                    Text(verbatim: tab.name)
                        .font(.jarasSystem(size: 13, weight: .semibold))
                        .foregroundStyle(tab.selected ? Color.white : Color(hex: 0xa4a4a4))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                        .background(Color(hex: tab.selected ? 0x333333 : 0x191919))
                        .overlay(alignment: .bottom) {
                            if tab.selected { Rectangle().fill(JarasTheme.green).frame(height: 3) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(!enabled || tab.selected)
                    .accessibilityIdentifier("remote-project-tab-\(tab.id.uuidString)")
                    .accessibilityValue(tab.selected ? "Selected" : "")
            }
        }.background(Color(hex: 0x414141))
    }
}
struct DAWRemoteClientView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var remote: DAWRemoteSession = .shared
    @StateObject private var localTimer = RemoteLocalTimer()
    @State private var directorPIN = ""
    @State private var enteringMode: DAWRemoteAccess?
    @State private var batteryWarning = DAWRemoteBatteryWarning()
    @State private var lowBatteryPercent: Int?
    var body: some View {
        VStack(spacing: 0) {
            if let state = remote.remoteState, remote.presentationAccess != nil {
                if remote.presentationAccess == .notices {
                    RemoteNativeNoticesView(close: { remote.stop(); dismiss() })
                        .id(state.project)
                        .onChange(of: remote.reconnecting) { waiting in
                            if !waiting { remote.send(.init(project: state.project, action: .remotePanel, value: 3)) }
                        }
                } else {
                NativeRemoteWorkspace(state: state, computerName: remote.peerName, timer: localTimer, send: remote.send,
                                      exitRemote: { remote.stop(); dismiss() }, observer: remote.presentationAccess == .observer)
                    .id(state.project)
                }
            } else if remote.connected {
                if remote.accessMode == nil { accessPicker } else {
                    VStack(spacing: 18) {
                        ProgressView { Text(verbatim: "Aguardando a sessão do PC…\nWaiting for the PC session…") }
                        Text(verbatim: "Abra um projeto no CatLive do PC.\nOpen a project in CatLive on your PC.")
                            .foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                        if !remote.accessError.isEmpty { Text(verbatim: remote.accessError).foregroundStyle(.red).multilineTextAlignment(.center) }
                        Button { remote.browse() } label: { Text(verbatim: "Reconectar · Reconnect") }
                        Button { remote.stop(); dismiss() } label: { Text(verbatim: "Voltar · Back") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                connectionPicker
            }
        }.background(RemoteSurface.background.ignoresSafeArea()).foregroundStyle(JarasTheme.text)
            .disabled(remote.reconnecting)
            .allowsHitTesting(!remote.reconnecting)
            .accessibilityHidden(remote.reconnecting)
            .overlay {
                if remote.reconnecting {
                    ZStack {
                        Color.black.opacity(0.65).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().tint(JarasTheme.green).scaleEffect(1.25)
                            Text("Waiting for reconnection").font(.jarasTitle3.bold())
                            Text(verbatim: remote.peerName).foregroundStyle(JarasTheme.green)
                            Text("Open CatLive and enable Remote on your PC.")
                                .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                            Button("Exit Remote") { remote.stop(); dismiss() }.buttonStyle(.bordered)
                        }.padding(28).frame(maxWidth: 360)
                            .background(RemoteSurface.panel).clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(JarasTheme.green.opacity(0.4)))
                            .foregroundStyle(JarasTheme.text)
                            .accessibilityAddTraits(.isModal).padding(.horizontal, 20)
                    }.onAppear { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .statusBarHidden(true).persistentSystemOverlays(.hidden)
            .overlay {
                if let lowBatteryPercent {
                    IpadCompactModal(preferredSize: CGSize(width: 285, height: 169), onDismiss: { self.lowBatteryPercent = nil }) {
                        VStack(spacing: 12) {
                            Text("Desktop battery").font(.jarasHeadline)
                            Text(verbatim: "\(lowBatteryPercent)%")
                                .font(.jarasSystem(size: 38, weight: .bold, design: .monospaced))
                                .foregroundStyle(.red)
                                .modifier(JarasBlink(active: true, interval: 0.4, lowOpacity: 0.4))
                            Button("OK") { self.lowBatteryPercent = nil }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refreshBatteryWarning() }
            .onChange(of: remote.remoteState?.desktopBatteryPercent) { _ in refreshBatteryWarning() }
            .onAppear {
                remote.resumeBrowsing()
                JarasMobileApplicationDelegate.setRemoteOrientation(active: true, director: remote.presentationAccess == .director)
            }
            .onDisappear {
                remote.stop()
                JarasMobileApplicationDelegate.setRemoteOrientation(active: false)
            }
            .onChange(of: remote.presentationAccess) { access in
                JarasMobileApplicationDelegate.setRemoteOrientation(active: true, director: access == .director)
            }
            .onChange(of: remote.connected) { connected in
                directorPIN = ""; enteringMode = nil
                if !connected { batteryWarning.reset(); lowBatteryPercent = nil }
                if connected && !remote.reconnecting {
                    localTimer.resetSynchronization()
                    localTimer.synchronize(remote.remoteState?.timer)
                }
            }
            .onChange(of: remote.reconnecting) { waiting in
                if !waiting && remote.connected {
                    localTimer.resetSynchronization(); localTimer.synchronize(remote.remoteState?.timer)
                }
            }
            .onChange(of: remote.remoteState?.timer) { localTimer.synchronize($0) }
    }
    private func refreshBatteryWarning() {
        guard remote.connected, let percent = remote.remoteState?.desktopBatteryPercent else { return }
        if let warning = batteryWarning.update(percent, now: ProcessInfo.processInfo.systemUptime) {
            lowBatteryPercent = warning
        }
    }

    private var accessPicker: some View {
        ScrollView {
        VStack(spacing: 20) {
            Text(verbatim: remote.peerName).font(.jarasTitle2.bold())
            Text(verbatim: "Escolha como acompanhar esta sessão\nChoose how to join this session").foregroundStyle(JarasTheme.secondary)
            let layout = UIDevice.current.userInterfaceIdiom == .phone ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                Button {
                    directorPIN = ""
                    if remote.directorRequiresPIN { enteringMode = .director }
                    else { remote.requestAccess(.director) }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3").font(.jarasLargeTitle)
                        Text(verbatim: "Diretor · Director").font(.jarasTitle3.bold())
                        Text(verbatim: "Controle o CatLive no PC\nControl CatLive on your PC").font(.jarasCaption)
                    }.frame(width: 220, height: 140).modifier(RemoteControlSurface(radius: 12))
                }
                Button { directorPIN = ""; remote.requestAccess(.observer) } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "eye").font(.jarasLargeTitle)
                        Text(verbatim: "Observador · Observer").font(.jarasTitle3.bold())
                        Text(verbatim: UIDevice.current.userInterfaceIdiom == .phone ? "Repertório e teleprompters\nRepertoire and teleprompters" : "Acompanhe Setlist e teleprompters\nFollow the setlist and teleprompters").font(.jarasCaption)
                    }.frame(width: 220, height: 140).modifier(RemoteControlSurface(radius: 12))
                }
                Button {
                    directorPIN = ""
                    if remote.noticesRequiresPIN { enteringMode = .notices }
                    else { remote.requestAccess(.notices) }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble").font(.jarasLargeTitle)
                        Text(verbatim: "Recados · Notices").font(.jarasTitle3.bold())
                        Text(verbatim: "Envie recados aos teleprompters\nSend notices to the teleprompters").font(.jarasCaption)
                    }.frame(width: 220, height: 140).modifier(RemoteControlSurface(radius: 12))
                }
            }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green).disabled(remote.authorizing)
            if let enteringMode {
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield").font(.jarasSystem(size: 30)).foregroundStyle(JarasTheme.green)
                    Text(verbatim: enteringMode == .notices ? "Acesso Recados · Notices access" : "Acesso Diretor · Director access").font(.jarasHeadline)
                    Text(verbatim: remote.peerName).font(.jarasSubheadline).foregroundStyle(JarasTheme.secondary)
                    SecureField("", text: $directorPIN, prompt: Text(verbatim: "••••"))
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(.jarasSystem(size: 30, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center).padding(12).frame(width: 180)
                        .background(RemoteSurface.background).clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Senha de quatro dígitos · Four-digit PIN")
                        .onChange(of: directorPIN) { value in directorPIN = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)) }
                    Button { remote.requestAccess(enteringMode, pin: directorPIN) } label: {
                        HStack { if remote.authorizing { ProgressView() }; Text(verbatim: "Conectar · Connect"); Image(systemName: "arrow.right") }
                            .font(.jarasHeadline).padding(.vertical, 12).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(JarasTheme.green)
                        .disabled(directorPIN.count != 4 || remote.authorizing)
                }.padding(20).frame(maxWidth: 330).background(RemoteSurface.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            if !remote.accessError.isEmpty { Text(verbatim: remote.accessError).foregroundStyle(.red) }
            if remote.authorizing { ProgressView() }
            Button { remote.browse(); directorPIN = ""; enteringMode = nil } label: { Text(verbatim: "Escolher outro PC · Choose another PC") }
                .foregroundStyle(JarasTheme.secondary)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionPicker: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button { remote.stop(); dismiss() } label: {
                        Label { Text(verbatim: "Voltar · Back") } icon: { Image(systemName: "chevron.left") }.font(.jarasSystem(size: 14, weight: .semibold))
                    }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary)
                    Spacer()
                }.padding(24)
                Spacer(minLength: 12)
                VStack(spacing: 22) {
                    Image(systemName: "desktopcomputer").font(.jarasSystem(size: 38, weight: .light))
                        .foregroundStyle(JarasTheme.green).frame(width: 80, height: 80)
                        .background(JarasTheme.green.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 8) {
                        Text(verbatim: "Conectar ao PC ou iPad · Connect to PC or iPad").font(.jarasSystem(size: 23, weight: .semibold))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: "Conecte os aparelhos à mesma rede. Ative Remote no CatLive do PC ou no modo Nativo do iPad e escolha-o abaixo.\n\nConnect both devices to the same network. Enable Remote in CatLive on your PC or in Native mode on your iPad, then choose it below.")
                            .font(.jarasSystem(size: 14)).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Label { Text(verbatim: "Entre dispositivos Apple: conexão direta por Wi-Fi, sem roteador. Mantenha Wi-Fi e Bluetooth ligados nos dois aparelhos.\nBetween Apple devices: direct peer-to-peer Wi-Fi, without a router. Keep Wi-Fi and Bluetooth enabled on both devices.") } icon: { Image(systemName: "wifi") }
                            .font(.jarasSystem(size: 12, weight: .medium)).foregroundStyle(JarasTheme.green)
                    }
                    VStack(spacing: 10) {
                        HStack {
                            Text(verbatim: "Dispositivos disponíveis · Available devices").font(.jarasSystem(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary)
                            Spacer()
                            Button { remote.browse() } label: {
                                Image(systemName: "arrow.clockwise").font(.jarasSystem(size: 14, weight: .semibold)).frame(width: 32, height: 30)
                            }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green).disabled(remote.connecting)
                                .accessibilityLabel(Text(verbatim: "Buscar PCs novamente · Refresh PCs"))
                        }
                        if remote.peers.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().tint(JarasTheme.green)
                                Text(verbatim: "Procurando PCs… · Searching for PCs…").font(.jarasSystem(size: 14)).foregroundStyle(JarasTheme.secondary)
                            }.frame(maxWidth: .infinity).frame(height: 76).background(RemoteSurface.background).cornerRadius(10)
                        } else {
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(remote.peers, id: \.self) { peer in
                                        Button { remote.connect(peer) } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: "desktopcomputer").font(.jarasSystem(size: 22)).foregroundStyle(JarasTheme.green)
                                                Text(verbatim: peer.displayName).font(.jarasSystem(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                                Spacer()
                                                if remote.connecting && remote.peerName == peer.displayName { ProgressView().tint(JarasTheme.green) }
                                                else { Image(systemName: "chevron.right").font(.jarasSystem(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary) }
                                            }.padding(16).background(RemoteSurface.background).cornerRadius(10)
                                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(remote.connecting && remote.peerName == peer.displayName ? JarasTheme.green : JarasTheme.line))
                                        }.buttonStyle(RemoteFullAreaButtonStyle()).disabled(remote.connecting)
                                    }
                                }
                            }.frame(height: min(220, CGFloat(remote.peers.count) * 68))
                        }
                        if remote.status.hasPrefix("Connection failed") {
                            Text(verbatim: "Não foi possível conectar. Aproxime os aparelhos e confira o Remote no PC.\nCould not connect. Bring the devices closer and check Remote on your PC.")
                                .font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.yellow)
                        } else if remote.status == "Disconnected" {
                            Text(verbatim: "Conexão encerrada. Escolha o PC para reconectar.\nDisconnected. Choose your PC to reconnect.")
                                .font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.secondary)
                        }
                    }
                }.padding(28).frame(maxWidth: 520).modifier(RemoteControlSurface(radius: 18))
                    .padding(.horizontal, 24)
                Spacer(minLength: 40)
            }.frame(maxWidth: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

#endif

@MainActor enum DAWRemoteHostBridge {
    static weak var documents: ProjectDocuments?
    static var projectTabsProvider: () -> [DAWRemoteState.ProjectTab] = { [] }
    static var selectProjectTabHandler: ((UUID) -> Void)?
    static var closeProjectTabHandler: ((UUID) -> Void)?
    private static var noticeImageDate = Date.distantPast
    private static var noticeImageData: Data?
    private static var lastTimerState: TeleprompterTimer?
    private static var timerRevision = UUID()
    private static var lastFadeoutCommandID: UUID?
    private static var lastTimerCommandID: UUID?
    private static var cachedProject: UUID?, cachedSong: UUID?, cachedRevision: UInt64?
    private static var cachedGridTempo: [DAWRemoteState.GridTempo] = []
    private static var cachedItems: [UUID: (clips: [DAWRemoteState.Clip], lanes: Int)] = [:]
    private static var cachedNetworkItems: [UUID: (clips: [DAWRemoteState.Clip], lanes: Int)] = [:]
    private struct PresentationKey: Equatable {
        var project: UUID
        var song: UUID?
        var revision: UInt64
        var setlistRevision: UInt64
        var playlist: UUID?
        var regionColor: UInt32
        var unifiedColor: UInt32
        var blockSymbols: Bool
    }
    private static var cachedPresentationKey: PresentationKey?
    private static var cachedRegions: [DAWRemoteState.Region] = []
    private static var cachedTimelineRegions: [DAWRemoteState.Region] = []
    private static var cachedMarkers: [DAWRemoteState.Marker] = []
    private static var cachedBlocks: [DAWRemoteState.SetlistBlock] = []
    private static var cachedPlaylistSeconds = 0.0
    private static var cachedDuration = 0.0
    private static var cachedPlayedSet: Set<UUID> = []
    private static var cachedPlayedIDs: [UUID] = []
    static func bind(_ show: ShowController, session: DAWRemoteSession = .shared) {
        cachedProject = nil; cachedSong = nil; cachedRevision = nil; cachedItems.removeAll(); cachedNetworkItems.removeAll(); cachedPresentationKey = nil

        session.stateProviderForSession = { [weak show] remote in
            guard let show, remote.connected else { return nil }
            let requestedPanel = remote.requestedPanel
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            var snapshot = show.snapshot
            if remote.isLocalWorkspace { snapshot.transport = show.timelinePlaybackTransport }
            let song = show.current, transport = snapshot.transport
            if remote.isLocalWorkspace { TPNoticeController.shared.observeTransport(playing: transport.playing || transport.subPlay.playing) }
            let playedLiveIDs = show.playedLiveRegionIDs
            let sendsPeaks = remote.accessMode == .director
            // Geometry and item metadata change with project edits, not transport ticks.
            if cachedProject != snapshot.project.id || cachedSong != song?.id || cachedRevision != show.projectRevision {
                cachedProject = snapshot.project.id; cachedSong = song?.id; cachedRevision = show.projectRevision
                cachedGridTempo = (song?.tempoSections(until: max(song?.duration ?? 0, song?.parts.map(\.endTime).max() ?? 0)) ?? []).map {
                    .init(start: $0.start, end: $0.end, bpm: $0.bpm, beats: $0.beats, unit: $0.unit)
                }
                cachedItems = Dictionary(uniqueKeysWithValues: (song?.tracks ?? []).map { track in
                    let lanes = TrackLanes(track: track)
                    let clips = track.clips.map { DAWRemoteState.Clip(id: $0.id, name: $0.name, start: $0.startTime, duration: $0.duration,
                        gain: $0.gain ?? 1, muted: $0.muted ?? false, lane: lanes.lanes[$0.id] ?? 0, waveform: $0.waveform, waveformLoopLength: $0.loopLength, waveformOffset: $0.sourceOffset - ($0.loopStart ?? 0), waveformRate: $0.audioRate) }
                    return (track.id, (clips: clips, lanes: lanes.count))
                })
                // Both presentations share revision-bound geometry, but LAN
                // clients never receive the native workspace's waveform arrays.
                cachedNetworkItems = cachedItems.mapValues { value in
                    (clips: value.clips.map { clip in
                        var metadata = clip
                        metadata.waveform = nil; metadata.waveformLoopLength = nil
                        metadata.waveformOffset = nil; metadata.waveformRate = nil
                        return metadata
                    }, lanes: value.lanes)
                }
            }
            let selectedPlaylist = show.selectedRegionPlaylist
            let regionTextColor = UInt32(AppearanceColor.shared(selectedPlaylist == nil ? "jaras.setlist.allRegionsTextColor" : "jaras.setlist.playlistTextColor",
                default: selectedPlaylist == nil ? 0xffffff : 0x00ff9a).value)
            let unifiedTextColor = UInt32(AppearanceColor.shared("jaras.setlist.unifiedTextColor", default: 0xffeb3b).value)
            @MainActor func region(_ part: Part) -> DAWRemoteState.Region {
                .init(id: part.id, name: part.displayName, start: part.startTime, end: part.endTime, color: part.color ?? 0x705264,
                      nameColor: part.parentRegionID != nil ? unifiedTextColor : regionTextColor, parentRegion: part.parentRegionID,
                      sourceRegionId: show.isPlaylistDuplicate(part.id) ? show.playlistRegionSourceID(part.id) : nil)
            }
            let presentationKey = PresentationKey(project: snapshot.project.id, song: song?.id,
                revision: show.projectRevision, setlistRevision: show.setlistRevision, playlist: selectedPlaylist?.id,
                regionColor: regionTextColor, unifiedColor: unifiedTextColor,
                blockSymbols: UserDefaults.standard.object(forKey: "jaras.blocks.symbol") as? Bool ?? true)
            let presentationChanged = cachedPresentationKey != presentationKey
            if presentationChanged {
                cachedPresentationKey = presentationKey
                cachedRegions = show.listedRegions.map(region)
                cachedTimelineRegions = (song?.parts ?? []).map(region)
                cachedMarkers = (song?.markers ?? []).filter { !$0.isTempo }.map {
                    .init(id: $0.id, name: song?.markerLabel($0) ?? $0.name, position: $0.position,
                        color: $0.color, section: $0.isSection, loopSection: $0.isLoopSection,
                        unifiedRegionID: $0.unifiedRegionID, sourceRegionID: $0.sourceRegionID)
                }
                cachedBlocks = show.listedBlocks.map {
                    .init(id: $0.id, name: $0.name, color: $0.color, beforeRegion: $0.beforeRegionId, symbol: presentationKey.blockSymbols)
                }
                cachedPlaylistSeconds = cachedRegions.reduce(0) { $0 + max(0, $1.end - $1.start) }
                cachedDuration = song?.duration ?? 0
            }
            if presentationChanged || cachedPlayedSet != playedLiveIDs {
                cachedPlayedSet = playedLiveIDs
                cachedPlayedIDs = (song?.parts ?? []).filter { playedLiveIDs.contains($0.id) }.map(\.id)
            }
            let selected = transport.playing ? show.pitchRegion : song?.parts.first { $0.id == (show.focusedRegion.map(show.playlistRegionSourceID) ?? transport.regionId) }
            let hasMultiLoop = transport.multiLoopsBypassed != true && (selected.map { part in
                part.totalLoop == true || (part.multiLoops ?? []).contains(where: { $0.enabled != false }) || (song?.parts.contains { candidate in
                    (candidate.id == part.parentRegionID || candidate.parentRegionID == part.id) &&
                    (candidate.totalLoop == true || (candidate.multiLoops ?? []).contains(where: { $0.enabled != false }))
                } ?? false)
            } ?? false)
            let information = !show.capacityWarning.isEmpty ? JarasLocalization.string(show.capacityWarning) : transport.automaticSectionNotice ?? (transport.loop.enabled ? "Loop Ativo" : transport.ignoreNextAfter != nil ? "Ignore Next" : hasMultiLoop ? JarasLocalization.string("This song has an active multiloop") : "")
            let internalNext = transport.playing && transport.ignoreNextAfter == nil ? song?.nextDrawerRegion(transport.regionId, position: transport.position) : nil
            let queued = transport.subPlay.playing
                ? song?.parts.first { transport.subPlay.position >= $0.startTime && transport.subPlay.position < $0.endTime }
                : song?.parts.first { $0.id == transport.queuedRegionId }
            let sectionRegion = transport.playing ? song?.sectionPlaybackRegion(for: transport)
                : song?.parts.first(where: { $0.id == show.focusedRegion.map(show.playlistRegionSourceID) }) ?? song?.sectionRegion(at: transport.editPosition ?? transport.position)
            let secondarySectionRegion = transport.subPlay.playing ? song?.sectionRegion(at: transport.subPlay.position)
                : song?.parts.first(where: { $0.id == transport.queuedRegionId })
            let displays = TransportSongDisplays(song: song, transport: transport, focusedRegion: show.focusedRegion.map(show.playlistRegionSourceID))
            let nextSection = transport.queuedSectionMarkerId == nil ? nil : song?.nextSectionTrigger(for: transport)
            return DAWRemoteState(project: snapshot.project.id, projectName: snapshot.project.name,
                song: song?.id, songName: song?.name ?? "—",
                songs: snapshot.project.songs.map { .init(id: $0.id, name: $0.name) },
                tracks: (song?.tracks ?? []).filter { remote.isLocalWorkspace || $0.kind == .standard }.map { track in
                    let items = remote.isLocalWorkspace ? cachedItems[track.id] : cachedNetworkItems[track.id]
                    return .init(id: track.id, name: track.name, color: track.color ?? JarasTheme.roleHex(track.role),
                          volume: show.mixerPlaybackGain(track: track.id, manual: track.volume), pan: track.pan, mute: track.mute, solo: track.solo,
                          clips: items?.clips ?? [],
                          nameColor: JarasTheme.trackNameHex(track, emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute),
                          emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute, laneCount: items?.lanes ?? 1, linkedTrack: track.stereoLink?.partner, heightScale: track.heightScale, compactComponents: remote.isLocalWorkspace && track.allowsCompactMixerHeight ? true : nil,
                          minimumHeight: remote.isLocalWorkspace && track.kind == .programChange ? Double(track.programChangeLaneCount * 24 + 8) : nil,
                          peakDB: sendsPeaks && track.kind != .chords && track.kind != .timecode && track.kind != .programChange ? StemAudioPlayback.shared.meter(for: track.id).peakHold.decibels : nil,
                          canMeter: track.kind != .chords && track.kind != .timecode && track.kind != .programChange, parentTrack: track.parentTrackID,
                          instrumentIcon: track.instrumentIcon, role: track.role.rawValue,
                          outputRoutes: remote.isLocalWorkspace ? nil : track.outputPatches)
                }, regions: cachedRegions, timelineRegions: cachedTimelineRegions,
                currentRegion: transport.regionId, queuedRegion: transport.queuedRegionId, focusedRegion: show.focusedRegion,
                currentPlaylistEntryId: transport.playlistEntryId, queuedPlaylistEntryId: transport.queuedPlaylistEntryId,
                position: transport.position, duration: cachedDuration,
                bpm: show.tempoControlBPM,
                playing: transport.playing, paused: transport.paused ?? false,
                subPlaying: transport.subPlay.playing, loop: transport.loop.enabled,
                masterVolume: show.mixerPlaybackGain(track: nil, manual: snapshot.project.masterVolume ?? 1), masterMute: snapshot.project.masterMute ?? false,
                masterSolo: snapshot.project.masterSolo ?? false, masterMono: snapshot.project.masterMono ?? false,
                pendingSave: show.hasUnsavedChanges, saving: show.saving, message: show.message,
                tempoNeedsRender: show.tempoControlNeedsRender,
                loopStart: transport.loop.start ?? song?.parts.first(where: { $0.id == transport.regionId })?.startTime,
                loopEnd: transport.loop.end ?? song?.parts.first(where: { $0.id == transport.regionId })?.endTime,
                multiLoopsBypassed: transport.multiLoopsBypassed == true,
                setlistLiveEnabled: show.setlistLiveEnabled,
                playedLiveRegionIDs: cachedPlayedIDs,
                masterPeakDB: sendsPeaks ? StemAudioPlayback.shared.masterMeter.peakHold.decibels : nil,
                masterPan: snapshot.project.masterPan ?? 0,
                patchOutputChannels: remote.isLocalWorkspace ? nil : min(1024, AudioDeviceSettings.shared.channels),
                masterOutputRoutes: remote.isLocalWorkspace ? nil : snapshot.project.masterOutputPatches,
                pitchRegion: show.pitchRegion?.id, pitchSemitones: show.pitchRegion?.semitones,
                setlistFontStyle: UserDefaults.standard.integer(forKey: "jaras.setlist.fontStyle"),
                prepareOnly: show.regionSetlist.preparesWithoutPlayback,
                masterColor: MixerTrackStyle.surfaceHex(for: .current),
                masterNameColor: MixerTrackStyle.surfaceTextHex,
                regionAuto: show.regionSetlist.autoAdvance, regionAutoUntilBlockEnd: show.regionSetlist.autoUntilBlockEnd, queueStartedAt: transport.queueStartedAt,
                playbackEnd: transport.ignoreNextEnd ?? song?.parts.first(where: { $0.id == transport.regionId })?.endTime,
                projectSavedAt: show.lastSavedAt ?? snapshot.project.updatedAt, footerInformation: information,
                footerLoopBeatPhase: FooterInformationDisplay.loopBeatPhase(transport: transport, song: song),
                upcomingName: (internalNext ?? queued)?.displayName,
                upcomingKind: internalNext != nil ? "Next song" : transport.subPlay.playing ? "Sub Play" : "Queued song",
                playlists: show.regionSetlist.playlists.filter { $0.songId == song?.id }.map { .init(id: $0.id, name: $0.name) },
                selectedPlaylist: selectedPlaylist?.id,
                gridRegion: transport.playing ? song?.playingSetlistRegion(transport.regionId, position: transport.position, expanded: [])?.id : (show.focusedRegion.map(show.playlistRegionSourceID) ?? transport.regionId),
                markers: cachedMarkers,
                projects: projectBrowser(documents),
                projectTabs: projectTabsProvider(),
                teleprompters: (1...2).contains(requestedPanel) ? [teleprompter(index: requestedPanel, snapshot: snapshot, directory: documents?.currentURL?.deletingLastPathComponent(), remote: remote)] : nil,
                notices: requestedPanel == 0 ? nil : notices(project: snapshot.project.id, remote: remote), timer: timerState(),
                fadeout: .init(runID: show.transportFadeout.run?.id, duration: show.transportFadeout.run?.duration ?? show.transportFadeout.duration, remaining: show.transportFadeout.run?.remaining ?? 0, lastCommandID: lastFadeoutCommandID),
                gridTempo: cachedGridTempo, gridDivisions: song?.projectTime.divisions,
                gridLines: UserDefaults.standard.object(forKey: "jaras.timeline.gridlines") as? Bool ?? (GlobalProjectTiming.load()?.settings.divisions != 0),
                gridPrimaryColor: TimelineThemeColor.verticalGrid.current(),
                gridSecondaryColor: UInt32(AppearanceColor.shared("jaras.timeline.secondaryGrid", default: TimelineAppearanceDefaults.secondaryGrid).value),
                gridBackgroundColor: TimelineThemeColor.background.current(),
                playCursorColor: UInt32(AppearanceColor.shared("jaras.timeline.playCursor", default: TimelineAppearanceDefaults.playCursor).value),
                editCursorColor: UInt32(AppearanceColor.shared("jaras.timeline.editCursor", default: TimelineAppearanceDefaults.editCursor).value),
                subPlayCursorColor: UInt32(TimelineAppearanceDefaults.subPlayCursor),
                editPosition: transport.editPosition ?? transport.position,
                subPlayPosition: transport.subPlay.position,
                sectionPlayback: .init(currentRegion: sectionRegion?.id, secondaryRegion: secondarySectionRegion?.id,
                    position: transport.playing ? transport.position : transport.editPosition ?? transport.position,
                    secondaryPosition: transport.subPlay.playing ? transport.subPlay.position : nil,
                    queuedMarker: transport.queuedSectionMarkerId, queueStartedAt: transport.sectionQueueStartedAt, nextTrigger: nextSection,
                    currentEnd: transport.ignoreNextEnd ?? sectionRegion?.endTime),
                songDisplays: .init(current: displays.current?.displayName ?? song?.name, currentBPM: displays.currentBPM,
                    next: displays.next?.displayName, nextBPM: displays.nextBPM, queued: displays.queued?.displayName, queuedBPM: displays.queuedBPM,
                    playlistSeconds: cachedPlaylistSeconds),
                setlistBlocks: cachedBlocks.map { block in
                    var block = block
                    block.nameColor = UInt32(AppearanceColor.shared("jaras.setlist.blockTextColor", default: 0x69ed91).value)
                    return block
                },
                previewActive: TeleprompterWindow.shared.previewActive,
                previewPage: TeleprompterWindow.shared.previewPage,
                vinhetas: VinhetasController.shared.remoteState, recording: TrackRecording.shared.recording,
                smkLoopName: SMK37Link.loopLabel(show).name, smkLoopColor: SMK37Link.loopLabel(show).color)
        }
        session.noticeSendHandler = { [weak show] command in
            guard command.valid, command.action == .noticeSend, let show,
                  command.project == show.snapshot.project.id else { return false }
            let model = TPNoticeController.shared
            model.select(Int(command.value)); model.draft = command.text ?? ""
            return model.send()
        }
        session.commandHandler = { [weak show, weak session] command in
            guard command.valid else { return }
            if [.timerStart, .timerStartProgressive, .timerSetMode, .timerStop].contains(command.action) {
                lastTimerCommandID = command.id; timerRevision = UUID()
            }
            if command.action == .vinhetasUp { VinhetasController.shared.applyRemote(command); return }
            guard let show, command.project == show.snapshot.project.id else { return }
            if [.vinhetasDown, .vinhetasPreset, .vinhetasVolume, .vinhetasGate, .vinhetasPanic].contains(command.action) {
                VinhetasController.shared.applyRemote(command); return
            }
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            if command.action == .remotePanel { return }
            if command.action == .toggleRecord { TrackRecording.shared.toggle(show: show); return }
            if command.action == .browseRegion { if let target = command.target { show.browseRegion(target) }; return }
            if command.action == .togglePreview { TeleprompterWindow.shared.togglePreview(); return }
            if command.action == .selectPreviewPage { TeleprompterWindow.shared.selectPreviewPage(Int(command.value)); return }
            if handleNotice(command) { return }
            if command.action == .timerSetMode {
                TeleprompterTimerController.shared.setMode(command.value == 0 ? .progressive : .countdown)
                return
            }
            if command.action == .timerStartProgressive {
                let timer = TeleprompterTimerController.shared
                timer.stopAndReset(); timer.setMode(.progressive); timer.start()
                return
            }
            if command.action == .timerStart {
                let timer = TeleprompterTimerController.shared, seconds = Int(command.value)
                timer.stopAndReset(); timer.setMode(.countdown)
                if timer.setTargetText(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)) { timer.start() }
                return
            }
            if command.action == .timerStop { TeleprompterTimerController.shared.stopAndReset(); return }
            if command.action == .selectProjectTab {
                if let target = command.target { Self.selectProjectTabHandler?(target) }
                return
            }
            if command.action == .closeProjectTab {
                if let target = command.target { Self.closeProjectTabHandler?(target) }
                return
            }
            if command.action == .openRecentProject || command.action == .openRecentProjectInNewTab {
                #if os(macOS)
                if let target = command.target {
                    documents?.openRemoteProject(target, inNewTab: command.action == .openRecentProjectInNewTab, commandID: command.id)
                }
                #endif
                return
            }
            guard documents?.busy != true, command.song == show.current?.id else { return }
            if command.action == .transportFadeout {
                guard lastFadeoutCommandID != command.id else { return }
                lastFadeoutCommandID = command.id
                if command.enabled == true {
                    if !show.transportFadeout.active { show.triggerTransportFadeout(explicit: true) }
                } else { show.cancelTransportFadeout() }
                return
            }
            if [.volume, .pan, .mute, .solo, .resetMeterPeak].contains(command.action), let target = command.target {
                guard show.current?.tracks.contains(where: { $0.id == target }) == true else { return }
            }
            if [.clipGain, .clipMute].contains(command.action) {
                guard let target = command.target, show.current?.tracks.contains(where: { track in
                    (session?.isLocalWorkspace == true || track.kind == .standard) && track.clips.contains { $0.id == target }
                }) == true else { return }
            }
            switch command.action {
            case .setOutputRoutes:
                guard let routes = command.outputRoutes else { return }
                if let target = command.target {
                    guard show.current?.tracks.contains(where: { $0.id == target && $0.kind == .standard }) == true else { return }
                }
                let channels = AudioDeviceSettings.shared.channels
                let current = command.target.flatMap { id in show.current?.tracks.first { $0.id == id }?.outputPatches }
                    ?? show.snapshot.project.masterOutputPatches
                guard routes.allSatisfy({ $0.firstChannel <= 0 || $0.firstChannel + $0.channelCount - 1 <= channels || current.contains($0) }) else { return }
                show.setOutputPatches(track: command.target, patches: routes)
            case .editRegion:
                guard let id = command.target, let name = command.text, show.playlistRegion(id) != nil else { return }
                show.editRegion(show.playlistRegionSourceID(id), name: name, color: UInt32(command.value))
            case .deleteRegion:
                guard let id = command.target, let part = show.playlistRegion(id), part.parentRegionID == nil else { return }
                if let playlist = command.playlist {
                    guard show.regionSetlist.playlists.contains(where: { $0.id == playlist && $0.songId == show.current?.id && $0.regionIds.contains(id) }) else { return }
                }
                show.deleteRegion(id, playlist: command.playlist)
            case .duplicateRegion:
                guard let id = command.target, command.playlist == show.selectedRegionPlaylist?.id, command.playlist != nil else { return }
                _ = show.duplicatePlaylistRegion(id)
            case .renamePlaylist:
                if let id = command.target, let name = command.text { show.renameRegionPlaylist(id, name: name) }
            case .duplicatePlaylist:
                if let id = command.target { show.cloneRegionPlaylist(id) }
            case .deletePlaylist:
                if let id = command.target { show.deleteRegionPlaylist(id) }
            case .save: Task { await show.save() }
            case .toggleRegionAuto: show.toggleRegionAuto()
            case .toggleSetlistLive: show.toggleSetlistLive()
            case .resetMeterPeak:
                if let id = command.target { StemAudioPlayback.shared.meter(for: id).peakHold.clear() }
                else { StemAudioPlayback.shared.masterMeter.peakHold.clear() }
            case .clipGain:
                if let target = command.target { show.setItemGain(target, gain: command.value) }
            case .clipMute: show.send(.clipMute, target: command.target)
            case .queueSection:
                guard let target = command.target, show.current?.sectionDestinationPosition(target) != nil else { return }
                show.send(.queueSection, target: target)
            case .selectPlaylist:
                if let target = command.target {
                    guard show.regionSetlist.playlists.contains(where: { $0.id == target && $0.songId == show.current?.id }) else { return }
                }
                show.selectRegionPlaylist(command.target)
            case .toggleRecord, .browseRegion: break
            case .selectRegion:
                guard let target = command.target, show.playlistRegion(target) != nil else { return }
                show.focusRegion(target)
            case .selectSong:
                guard let target = command.target, show.snapshot.project.songs.contains(where: { $0.id == target }) else { return }
                show.send(show.isPlaying ? .queue : .select, target: target)
            case .pitch:
                guard let song = show.current, let region = show.pitchRegion, region.id == command.target else { return }
                let targets = song.pitchTargets(region)
                show.setRegionPitch(region.id, semitones: Int(command.value), tracks: targets.tracks, groups: targets.groups)
            case .tempo: show.setTempo(command.value)
            case .seek:
                // Native grid taps move the edit cursor, just like the desktop.
                // A transport seek would restart the running audio at this point.
                if session?.isLocalWorkspace == true { show.send(.editSeek, value: command.value); return }
                guard !show.isPlaying, let song = show.current,
                      let target = command.target, target == (show.focusedRegion ?? show.snapshot.transport.regionId),
                      let region = song.parts.first(where: { $0.id == show.playlistRegionSourceID(target) }) else { return }
                show.send(.seek, value: min(region.endTime, max(region.startTime, command.value)))
            default:
                guard let action = ShowCommand(rawValue: command.action.rawValue) else { return }
                show.send(action, target: command.target, value: command.value)
            }
        }
    }

    private static func projectBrowser(_ documents: ProjectDocuments?) -> DAWRemoteState.ProjectBrowser? {
        #if os(macOS)
        return documents?.remoteProjectBrowser
        #else
        return nil
        #endif
    }

    private static func timerState() -> DAWRemoteTimerState {
        let state = TeleprompterTimerController.shared.state
        if lastTimerState != state { lastTimerState = state; timerRevision = UUID() }
        return .init(revision: timerRevision, targetSeconds: state.targetSeconds, running: state.running,
                     remainingSeconds: state.displaySeconds(at: ProcessInfo.processInfo.systemUptime), commandID: lastTimerCommandID, mode: state.mode.rawValue)
    }

    private static func boundedNotice(_ text: String) -> String {
        var text = String(text.prefix(500))
        while text.utf8.count > 4000 { text.removeLast() }
        return text
    }
    private static func handleNotice(_ command: DAWRemoteCommand) -> Bool {
        let model = TPNoticeController.shared
        switch command.action {
        case .noticeClear: model.clear()
        case .noticePin:
            if model.pinned != (command.value == 1) { model.togglePin() }
        case .noticePinStopped:
            model.setPinWhenStopped(command.enabled == true, text: command.text, selectedSlot: Int(command.value))
        case .noticeDestination:
            if command.value == 1 { model.appearance.window1 = command.enabled == true }
            else { model.appearance.window2 = command.enabled == true }
        case .noticeSaveTemplate: model.templates[Int(command.value)] = command.text ?? ""
        default: return false
        }
        return true
    }
    private static func notices(project: UUID, remote: DAWRemoteSession) -> DAWRemoteNotices {
        let model = TPNoticeController.shared, appearance = model.appearance
        if noticeImageDate != model.sentAt {
            noticeImageDate = model.sentAt
            noticeImageData = model.remoteImage.flatMap { value in
                value.firstIndex(of: ",").flatMap { Data(base64Encoded: String(value[value.index(after: $0)...])) }
            }
        }
        let imageID = model.active ? noticeImageData.flatMap {
            remote.imageID(for: $0, project: project, key: "notice-\(model.sentAt.timeIntervalSince1970)")
        } : nil
        return .init(templates: model.templates.map(boundedNotice), imageSlots: model.images.map { $0 != nil },
                     message: boundedNotice(model.message), active: model.active, pinned: model.pinned,
                     remaining: min(20, max(0, Int(ceil(model.remaining())))), window1: appearance.window1, window2: appearance.window2,
                     textColor: appearance.text, backgroundColor: appearance.background, flashColor: appearance.flash,
                     font: appearance.font, scale: appearance.scale, emoji: appearance.emojiEnabled ? appearance.emoji : "",
                     cleanDisplay: appearance.cleanDisplay, sentAt: model.sentAt.timeIntervalSince1970, imageID: imageID,
                     pinWhenStopped: model.pinWhenStopped, stoppedNoticeActive: model.stoppedNoticeActive)
    }
    static func teleprompter(index: Int, snapshot: ShowSnapshot, directory: URL?, remote: DAWRemoteSession) -> DAWRemoteTeleprompter {
        var settings = (index == 1 ? TeleprompterPreferences.shared : .second).settings
        #if os(iOS)
        settings.isClear = false
        #endif
        #if os(macOS)
        let controller = index == 1 ? TeleprompterWindow.shared : .second
        let previewActive = controller.previewActive, previewPage = controller.previewPage
        #else
        let previewActive = TeleprompterWindow.shared.previewActive, previewPage = TeleprompterWindow.shared.previewPage
        #endif
        let transport = snapshot.transport
        let original = snapshot.project.songs.first { $0.id == transport.songId } ?? snapshot.project.songs.first
        let song = original.map { transport.multiLoop?.projectionSong($0) ?? $0 }
        let position = transport.playing ? transport.position : transport.editPosition ?? transport.position
        let region = song?.parts.filter { position >= $0.startTime && position < $0.endTime }
            .min { $0.endTime - $0.startTime < $1.endTime - $1.startTime }
        let queued = song?.parts.first { $0.id == transport.queuedRegionId }
        let kind: TrackKind = index == 1 ? .teleprompt : .teleprompt2
        var lyric: AudioClip?, chord: AudioClip?, media: AudioClip?
        for track in song?.tracks ?? [] where !track.mute && (track.kind == kind || track.kind == .chords) {
            let active = track.clips.filter { $0.muted != true && position >= $0.startTime && position < $0.startTime + $0.duration }
            if track.kind == kind {
                if lyric == nil { lyric = active.filter { !$0.isProjectionMedia }.max { $0.startTime < $1.startTime } }
                if media == nil {
                    media = active.first { clip in
                        guard clip.isProjectionMedia, let path = clip.audioFile?.path else { return false }
                        return UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .image) == true
                    }
                }
            } else if chord == nil { chord = active.filter { !$0.isProjectionMedia }.max { $0.startTime < $1.startTime } }
        }
        var style = DAWRemoteTeleprompter.Style()
        style.textColor = settings.textColor; style.chordColor = settings.chordColor
        style.songColor = settings.songNameColor; style.queueColor = settings.queueNameColor
        style.clockColor = settings.clockColor; style.localClockColor = settings.localClockColor
        style.borderColor = settings.borderColor; style.textBoxColor = settings.textBoxColor; style.progressColor = settings.progressColor
        style.font = settings.fontFamily; style.chordFont = settings.chordFontFamily; style.textAlignment = settings.textAlignment
        style.textScale = settings.textScale; style.chordScale = settings.chordScale
        style.windowBorder = settings.windowBorderEnabled; style.textBox = settings.textBoxEnabled
        style.songEnabled = settings.songNameEnabled; style.queueEnabled = settings.queueNameEnabled
        style.clockEnabled = settings.clockEnabled; style.localClockEnabled = settings.localClockEnabled
        style.chordsEnabled = settings.chordsEnabled; style.progressEnabled = settings.progressEnabled
        style.clockPosition = settings.clockPosition; style.songPosition = settings.songNamePosition
        style.queuePosition = settings.queueNamePosition; style.chordPosition = settings.chordPosition; style.progressPosition = settings.progressPosition
        let progressClip = settings.progressMode == "chords" ? chord : lyric
        let progress = progressClip.map { min(1, max(0, (position - $0.startTime) / max(0.001, $0.duration))) } ?? 0
        let queueName = queued?.name ?? snapshot.project.songs.first { $0.id == transport.queue.songId }?.name ?? ""
        var result = DAWRemoteTeleprompter(index: index, text: settings.display(ItemTextColors.plain(lyric?.text ?? "")), chords: settings.display(ItemTextColors.plain(chord?.text ?? "")),
            song: settings.display(region?.name ?? ""), queued: settings.display(queueName), progress: progress,
            style: style, preview: settings.displaysPreview(previewActive), settings: settings)
        result.textStyled = lyric?.text; result.chordsStyled = chord?.text
        result.loopActive = transport.loop.enabled
        if result.preview, let song {
            let setlist = snapshot.project.regionSetlist ?? RegionSetlist()
            let played = SetlistLivePlaybackTracker.previewMarks(project: snapshot.project)
            let playlist = setlist.playlists.first { $0.id == setlist.selectedId && $0.songId == song.id }
            let playback = TeleprompterPreviewPlayback(song: song, transport: transport, playlist: playlist)
            let entries = TeleprompterPreviewEntry.make(song: song, playlist: playlist)
            let headers = Dictionary(grouping: (setlist.blocks ?? []).filter { $0.songId == song.id && $0.playlistId == playlist?.id }, by: \.beforeRegionId)
            var blocks = [DAWRemoteTeleprompter.Block(id: song.id, name: "", color: 0xffea00, rows: [])]
            for entry in entries {
                let part = entry.region
                for header in entry.blockAnchors.flatMap({ headers[$0] ?? [] }) {
                    blocks.append(.init(id: header.id, name: settings.display(header.name), color: header.color, rows: []))
                }
                let last = blocks.count - 1
                blocks[last].rows.append(.init(id: entry.id, name: settings.display(part.displayName),
                    color: part.id == (transport.playlistEntryId ?? region?.id) ? settings.highlightColor : part.id == (transport.queuedPlaylistEntryId ?? queued?.id) ? settings.queueNameColor : part.color ?? blocks[last].color,
                    duration: max(0, part.endTime - part.startTime),
                    liveExecuted: played.contains(part.id),
                    playing: playback.playingEntry == entry.id, queued: playback.queuedEntry == entry.id,
                    playbackProgress: playback.progress(for: entry.id)))
            }
            blocks += (headers[nil] ?? []).map { .init(id: $0.id, name: settings.display($0.name), color: $0.color, rows: []) }
            for index in blocks.indices { blocks[index].nameColor = UInt32(AppearanceColor.shared("jaras.setlist.blockTextColor", default: 0x69ed91).value) }
            result.blocks = Array(blocks.filter { !$0.name.isEmpty || !$0.rows.isEmpty }.dropFirst(previewPage * 4).prefix(4))
        }
        if !result.preview, let media, let file = media.audioFile, let directory,
           UTType(filenameExtension: URL(fileURLWithPath: file.path).pathExtension)?.conforms(to: .image) == true {
            result.imageID = remote.imageID(for: directory.appendingPathComponent(file.path), project: snapshot.project.id)
            result.mediaName = media.name
        }
        return result
    }
}
#if os(iOS)
/// UIKit owns both gestures so iOS 16 does not let a SwiftUI high-priority
/// hold swallow the normal Button action (or toggle Remote twice).
private struct IpadTapHoldButtonStyle: PrimitiveButtonStyle {
    let hold: () -> Void
    var surface = false
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if surface { configuration.label.modifier(RemoteControlSurface()) }
            else { configuration.label }
        }
            .overlay { IpadTapHoldTouchSurface(tap: configuration.trigger, hold: hold).clipShape(RoundedRectangle(cornerRadius: 6)) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { configuration.trigger() }
    }
}
/// Shared target picker for native transport layouts, including full screen.
struct NativeTunerTargets: ViewModifier {
    var show: ShowController?
    @State private var editing: Part?
    func body(content: Content) -> some View {
        content.overlay {
            if let show {
                IpadTapHoldTouchSurface(tap: {}, hold: { editing = show.pitchRegion })
                    .accessibilityLabel("Escolher pistas e grupos do Tuner")
            }
        }.sheet(item: $editing) { region in
            if let show, let song = show.current {
                RegionPitchTargets(show: show, song: song, region: region, close: { editing = nil })
            }
        }
    }
}
struct IpadTapHoldTouchSurface: UIViewRepresentable {
    let tap: () -> Void
    let hold: () -> Void
    var shiftTap: (() -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    func makeUIView(context: Context) -> IpadTapHoldControl { IpadTapHoldControl() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: IpadTapHoldControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 44, height: proposal.height ?? 44)
    }
    func updateUIView(_ view: IpadTapHoldControl, context: Context) {
        view.tapAction = tap; view.holdAction = hold; view.shiftTapAction = shiftTap; view.isEnabled = enabled
    }
}
final class IpadTapHoldControl: UIButton {
    var tapAction: (() -> Void)?
    var holdAction: (() -> Void)?
    var shiftTapAction: (() -> Void)?
    private var suppressTapAfterHold = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(self, action: #selector(released(_:forEvent:)), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        hold.minimumPressDuration = 0.5; hold.allowableMovement = 12
        hold.cancelsTouchesInView = true
        addGestureRecognizer(hold)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryPressed))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        secondary.cancelsTouchesInView = true
        addGestureRecognizer(secondary)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func secondaryPressed() {
        guard isEnabled else { return }
        suppressTapAfterHold = true; isHighlighted = false; holdAction?()
    }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? UIColor.white.withAlphaComponent(0.12) : .clear }
    }
    @objc private func pressed() { suppressTapAfterHold = false }
    @objc private func released(_ sender: UIButton, forEvent event: UIEvent) {
        guard isEnabled, !suppressTapAfterHold else { return }
        if event.modifierFlags.contains(.shift), let shiftTapAction { shiftTapAction() }
        else { tapAction?() }
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard isEnabled, gesture.state == .began else { return }
        suppressTapAfterHold = true; isHighlighted = false; holdAction?()
    }
}
private struct IpadTeleprompterRemoteHold: ViewModifier {
    var open: (() -> Void)?
    var surface = false
    @ViewBuilder func body(content: Content) -> some View {
        if let open { content.buttonStyle(IpadTapHoldButtonStyle(hold: open, surface: surface)) }
        else { content.buttonStyle(RemoteFullAreaButtonStyle(surface: surface)) }
    }
}
private struct IpadNativeRemoteToggle: View {
    let openSettings: () -> Void
    let width: CGFloat
    @ObservedObject private var host = DAWRemoteSession.nativeHost
    var body: some View {
        Button { host.setHostEnabled(!host.enabled) } label: {
            Label {
                Text(verbatim: "Remote")
            } icon: {
                ControlIcon(name: "dot.radiowaves.left.and.right", active: host.enabled, size: 16)
            }
                .font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                .foregroundStyle(JarasTheme.toolbarTint(active: host.enabled)).frame(width: width, height: 32)
                .modifier(RemoteControlSurface(radius: 5))
                .contentShape(Rectangle())
        }
            .modifier(IpadTeleprompterRemoteHold(open: openSettings))
            .accessibilityLabel("Remote").accessibilityValue(host.enabled ? "On" : "Off")
            .accessibilityAction(named: Text("Configurações"), openSettings)
    }
}

private struct IpadNativeAudioStatus: View {
    let openSettings: () -> Void
    @ObservedObject private var audio = AudioDeviceSettings.shared
    private var status: String {
        guard audio.channels > 0 else { return "No Device" }
        return "\(audio.bufferFrames) · \(Int(audio.sampleRate)) Hz"
    }
    var body: some View {
        Button(action: openSettings) {
            Text(verbatim: status).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(JarasTheme.secondary).lineLimit(1).truncationMode(.middle)
                .frame(minHeight: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Configurações de áudio")
            .accessibilityValue(Text(verbatim: status))
    }
}

/// A fixed touch target and a real gap keep adjacent controls distinct on
/// both devices. The rail scrolls on short screens instead of shrinking labels.
private enum RemoteSidebarMetrics {
    static let buttonSize: CGFloat = 44
    static let spacing: CGFloat = 8
    static let groupSpacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 8
    static let width = buttonSize + horizontalPadding * 2
}

private struct RemoteDesktopBatteryBadge: View {
    let percent: Int?
    let vertical: Bool

    var body: some View {
        if let percent {
            let icon = HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(lineWidth: 1.25)
                    .frame(width: 19, height: 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).frame(width: 15 * CGFloat(min(100, max(0, percent))) / 100, height: 6)
                            .padding(.leading, 2)
                    }
                Capsule().frame(width: 2, height: 4)
            }.fixedSize().accessibilityHidden(true)
            let value = Text(verbatim: "\(percent)%").font(.jarasSystem(size: 9, weight: .semibold)).monospacedDigit()
            Group {
                if vertical { VStack(spacing: 2) { icon; value } }
                else { HStack(spacing: 4) { icon; value } }
            }.foregroundStyle(percent <= 20 ? Color.red : JarasTheme.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: vertical ? 44 : 0, minHeight: 25)
                .accessibilityElement(children: .ignore).accessibilityLabel("Desktop battery")
                .accessibilityValue(Text(verbatim: "\(percent)%"))
        }
    }
}

private struct RemoteSidebarRail<Content: View>: View {
    let hidden: Bool
    var width: CGFloat = RemoteSidebarMetrics.width
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: RemoteSidebarMetrics.spacing, content: content)
                    .frame(width: width - RemoteSidebarMetrics.horizontalPadding * 2)
                    .frame(minHeight: max(0, geometry.size.height - RemoteSidebarMetrics.verticalPadding * 2))
                    .padding(.horizontal, RemoteSidebarMetrics.horizontalPadding)
                    .padding(.vertical, RemoteSidebarMetrics.verticalPadding)
            }
        }.frame(width: hidden ? 0 : width)
            .clipped().allowsHitTesting(!hidden).accessibilityHidden(hidden)
            .background(RemoteSurface.panel)
    }
}

enum TrackMixControl: Equatable {
    case pan, mute, solo

    func display(_ value: Double) -> String {
        switch self {
        case .pan:
            let percent = Int((abs(value) * 100).rounded())
            return percent == 0 ? "Center" : "\(percent)%\(value < 0 ? "L" : "R")"
        case .mute, .solo:
            return JarasLocalization.string(self == .mute ? "Mute" : "Solo") + " " + JarasLocalization.string(value == 0 ? "Off" : "On")
        }
    }
}

@MainActor final class TrackMixFeedback: ObservableObject {
    struct Reading {
        let track: UUID
        let name: String
        let control: TrackMixControl
        let value: Double
    }

    @Published private(set) var reading: Reading?
    private var hide: Task<Void, Never>?

    func show(track: UUID, name: String, control: TrackMixControl, value: Double) {
        reading = Reading(track: track, name: name, control: control, value: value)
        resetTimeout(control)
    }

    func dismiss() {
        hide?.cancel()
        hide = nil
        reading = nil
    }

    private func resetTimeout(_ control: TrackMixControl) {
        hide?.cancel()
        let delay: UInt64 = control == .pan ? 2_000_000_000 : 1_500_000_000
        hide = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.dismiss()
        }
    }
}

private struct TrackMixFeedbackKey: EnvironmentKey {
    static let defaultValue: TrackMixFeedback? = nil
}

extension EnvironmentValues {
    var trackMixFeedback: TrackMixFeedback? {
        get { self[TrackMixFeedbackKey.self] }
        set { self[TrackMixFeedbackKey.self] = newValue }
    }
}

private struct TrackMixFeedbackPanel: View {
    @ObservedObject var feedback: TrackMixFeedback

    var body: some View {
        if let reading = feedback.reading {
            HStack {
                Text(verbatim: reading.name).font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: reading.control.display(reading.value))
                    .font(.jarasSystem(size: 13, weight: .semibold, design: .monospaced))
            }
            .padding(10).frame(width: 218)
            .background(RemoteSurface.display)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(JarasTheme.line).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            .accessibilityIdentifier("track-mix-feedback")
            .allowsHitTesting(false)
            .id(reading.track.uuidString + String(describing: reading.control))
        }
    }
}

@MainActor struct NativeRemoteWorkspace: View {
    @Environment(\.isEnabled) private var controlsEnabled
    let state: DAWRemoteState
    let computerName: String
    let timer: RemoteLocalTimer
    let send: (DAWRemoteCommand) -> Void
    let exitRemote: () -> Void
    var observer = false
    var local = false
    var openHome: (() -> Void)? = nil
    var openNativeProject: (() -> Void)? = nil
    var exportNativeAudio: (() -> Void)? = nil
    var localShow: ShowController? = nil
    var timelineFocus: IpadTimelineFocus? = nil
    var openMetronome: (() -> Void)? = nil
    @Environment(\.multitrackAction) private var multitrackAction
    var openRegionActions: ((UUID) -> Void)? = nil
    var detectRegionBPM: ((UUID) -> Void)? = nil
    var openPatch: ((UUID?) -> Void)? = nil
    var openPlugin: ((UUID?, String) -> Void)? = nil
    var openSelectedPatch: (([UUID]) -> Void)? = nil
    var openTrackAutomation: ((UUID) -> Void)? = nil
    var openTrackDetails: ((Set<UUID>) -> Void)? = nil
    var openTrackIcon: ((Set<UUID>) -> Void)? = nil
    var openClickSound: ((UUID) -> Void)? = nil
    var openItemMenu: ((UUID) -> Void)? = nil
    var openSelectedItemMenu: ((UUID, Set<UUID>) -> Void)? = nil
    var processSelectedItems: ((Set<UUID>, DAWAction) -> Void)? = nil
    var openItemFX: ((UUID) -> Void)? = nil
    var addTrack: (() -> Void)? = nil
    var addTrackAudio: ((UUID) -> Void)? = nil
    var addTrackText: ((UUID) -> Void)? = nil
    var addTrackLyrics: ((UUID) -> Void)? = nil
    var addTrackMedia: ((UUID) -> Void)? = nil
    var createPlaylist: ((String, [UUID]) -> Bool)? = nil
    var addBlock: (() -> Void)? = nil
    var toggleRegionStop: (() -> Void)? = nil
    var stopsAtRegionEnd = false
    @State private var addingToPlaylist: UUID?
    @State private var creatingPlaylist = false
    var shareProject: (() -> Void)? = nil
    var groupTracks: ((Set<UUID>) -> Void)? = nil
    var groupableTracks: Set<UUID> = []
    @State private var regionMovePreview: IpadRegionMovePreview?
    @State private var editingTracks = false
    private struct TrackHeightPreview {
        let project: UUID
        let song: UUID
        let track: UUID
        let scale: Double
    }
    @GestureState private var trackHeightPreview: TrackHeightPreview? = nil
    @State private var trackMixFeedback = TrackMixFeedback()
    @AppStorage("jaras.ipad.transport.hidden") private var hiddenTransport = ""
    @State private var fadeoutSettingsOpen = false
    @State private var confirmingMainMono = false
    @State private var pendingFadeout: (id: UUID, active: Bool, sent: Date)?
    @State private var fadeoutReceivedAt = Date()
    @State private var tempoStepPending = false
    @State private var tempoStepGate = LiveTempoEditGate()
    @State private var tempoStepRequest = UUID()
    @State private var pitchStepPending = false
    @State private var selectedTracks: Set<UUID> = []
    @State private var trackActionsOpen = false
    @StateObject private var trackReordering = IpadTrackReorderController()
    var openRegionLoops: ((UUID) -> Void)? = nil
    var openAdvanced: (() -> Void)? = nil
    var nativeAdvancedOpen = false
    var openMatrixPatch: (() -> Void)? = nil
    var nativeMatrixOpen = false
    var toggleHozMixer: (() -> Void)? = nil
    var hozMixerOpen = false
    var openSettings: (() -> Void)? = nil
    var nativeSettingsOpen = false
    var openAudioSettings: (() -> Void)? = nil
    var openRemoteSettings: (() -> Void)? = nil
    var openTeleprompterRemote: ((Int) -> Void)? = nil
    @ObservedObject var remote: DAWRemoteSession = .shared
    @State private var phonePanel: DAWRemotePhonePanel = .setlist
    @State private var transientFooterNotice = ""
    @State private var navigationOpen = false
    @State private var sidebarHidden = false
    @State private var remotePortrait = false
    private var phoneLayout: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var sidebarCollapsed: Bool { sidebarHidden || prompterFullscreen }
    @State private var projectsOpen = false
    @State private var playlistPickerOpen = false
    private struct EntryEditor: Identifiable {
        let id: UUID
        let playlist: Bool
        var name: String
        var color: UInt32
        var block = false
    }
    private struct NativeSetlistRemoval {
        let project: UUID
        let song: UUID
        let playlist: UUID?
        let ids: Set<UUID>
        let blocksOnly: Bool
    }
    @State private var editingEntry: EntryEditor?
    @State private var editingBlockSymbol = true
    @State private var removal: DAWRemoteCommand?
    @State private var nativeSetlistRemoval: NativeSetlistRemoval?
    @State private var confirmingRemoval = false
    @State private var duplicateQueueWarning = false
    @State private var selectedSetlistEntries: Set<UUID> = []
    @State private var nativeKeyboardBrowsing = false
    @State private var nativePianoOpen = false
    @State private var nativeMIDIPreviewOpen = false
    @State private var nativeMIDIPreviewDetached = false
    @AppStorage("jaras.ipad.midiPreview.height") private var nativeMIDIPreviewHeight = 273.0
    @GestureState private var nativeMIDIPreviewResize: CGFloat = 0
    @State private var setlistSelectionAnchor: UUID?
    @State private var draggingSetlistEntries: Set<UUID> = []
    private enum PrompterPanel: Int, Identifiable {
        case first = 1, second = 2
        var id: Int { rawValue }
    }
    @State private var prompterPanel: PrompterPanel?
    @State private var prompterFullscreen = false
    @State private var noticesOpen = false
    @State private var timerOpen = false
    @State private var sectionsOpen = false
    @State private var horizontalPartsOpen = false
    @AppStorage("jaras.mobile.parts.heightScale") private var horizontalPartsHeightScale = 1.0
    @State private var partsTabSelection = CurrentValueSubject<PartsTabSelectionRequest?, Never>(nil)
    @State private var smkNavigation = SMK37Navigation()
    @State private var pendingSMKAction: SMK37Action?
    @State private var smkExpectedState: Bool?
    @State private var smkRequestedPage: Int?
    @State private var sectionsInList = false
    @AppStorage("jaras.ipad.parts.left.open") private var nativeLeftPartsOpen = false
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var nativeInterfaceTheme = JarasInterfaceTheme.defaultTheme
    @AppStorage("jaras.ipad.hozMixer.height") private var nativeMixerHeight = 273.0
    @State private var nativeHozMixerDetached = false
    @GestureState private var mixerHeightTranslation: CGFloat = 0
    @AppStorage("jaras.ipad.focus.open") private var nativeFocusOpen = false
    @AppStorage("jaras.ipad.library.open") private var nativeLibraryOpen = false
    @AppStorage("jaras.ipad.transport.proMode") private var nativeProMode = false
    @State private var nativeProDock: Bool?
    @State private var nativeClockPositionOpen = false
    @AppStorage("jaras.timeline.proTool") private var nativeProTool = ProGridTool.select
    @AppStorage("jaras.ipad.library.width") private var nativeLibraryWidth = 300.0
    @State private var liveLibraryWidth: Double?
    @AppStorage(WorkspaceLibrary.folderWidthKey, store: WorkspaceLayoutPreferences.storage)
    private var nativeLibraryFoldersWidth = WorkspaceLibrary.defaultFolderWidth
    @AppStorage("jaras.ipad.parts.left.preferredWidth") private var nativeLeftPartsWidth = 240.0
    @AppStorage("jaras.ipad.vinhetas.open") private var nativeVinhetasOpen = false
    @State private var remoteVinhetasOpen = false
    @State private var remoteVinhetasFeedback = DAWRemoteVinhetasFeedback()
    @State private var remoteVinhetasDetached = false
    @AppStorage("jaras.ipad.vinhetas.detached") private var nativeVinhetasDetached = false
    @State private var nativeLeftPartsDragStart: Double?
    @State private var liveNativeLeftPartsWidth: Double?
    @AppStorage("catlive.remote.sections.preferredWidth") private var preferredPartsWidth = 240.0
    @State private var partsDragStart: Double?
    @State private var livePartsWidth: Double?
    @State private var remoteMIDISetlistID: UUID?
    @State private var remoteMIDIPartID: UUID?
    @State private var remoteMIDIPlaylistID: UUID?
    @AppStorage("jaras.remote.observer.setlistScale") private var observerSetlistScale = 1.0
    @State private var settingsOpen = false
    @State private var remotePatch: RemoteOutputPatchRequest?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var keyboardVisible = false
    @AppStorage("jaras.setlist.allRegionsOrder") private var allRegionsOrder = 0
    @State private var expandedRegions: Set<UUID> = []
    @State private var itemLayoutCache = DAWRemoteItemLayoutCache()
    @State private var setlistRowsCache = DAWRemoteSetlistRowsCache()
    @StateObject private var trackScrolling = RemoteTrackScrollController()
    @ObservedObject private var trackVisibility = TrackVisibilityPreferences.shared
    @State private var hardwareModifiers: HardwareKeyboardModifiers = []
    @State private var deletingTracks: (project: UUID, song: UUID, ids: Set<UUID>)?
    @State private var splittingItems: (project: UUID, song: UUID, ids: Set<UUID>, position: Double)?
    @State private var nativeNormalization = false
    @State private var nativeMarker: TimelineMarker?
    @State private var automaticSectionSource: UUID?
    @State private var configInitRegion: UUID?
    @State private var autoSettings = false
    @State private var unifyingRegion: UUID?
    @State private var unifyName = ""
    @AppStorage("jaras.remote.mixerHidden") private var mixerHidden = false
    @AppStorage("jaras.timeline.showRegionLanes") private var showNativeRegionLanes = true
    @AppStorage("jaras.timeline.showTempoLane") private var showNativeTempoLane = true
    @AppStorage("jaras.remote.trackWidth") private var savedTrackFraction = 0.30
    @AppStorage("jaras.remote.setlistWidth") private var savedSetlistFraction = 0.32
    @AppStorage("jaras.remote.setlistRestoreWidth") private var savedVisibleSetlistFraction = 0.32
    @AppStorage("jaras.remote.teleprompterSetlistWidth") private var savedPrompterSetlistFraction = 0.30
    @AppStorage("jaras.remote.teleprompterSetlistHidden") private var prompterSetlistHidden = false
    @State private var livePrompterSetlistFraction: Double?
    @State private var prompterResizeStart: Double?
    @State private var livePanelWidths: DAWRemotePanelWidths?
    @State private var trackResizeStart: DAWRemotePanelWidths?
    @State private var setlistResizeStart: DAWRemotePanelWidths?
    private var panelWidths: DAWRemotePanelWidths {
        livePanelWidths ?? .init(track: mixerHidden ? 0 : savedTrackFraction, setlist: savedSetlistFraction)
    }
    private var mixerCollapsed: Bool { panelWidths.track == 0 }
    private var prompterSetlistFraction: Double {
        if let livePrompterSetlistFraction { return livePrompterSetlistFraction }
        guard !prompterSetlistHidden else { return 0 }
        return savedPrompterSetlistFraction.isFinite ? min(1, max(0, savedPrompterSetlistFraction)) : 0.30
    }
    private func persistPrompterSetlistFraction(_ fraction: Double) {
        let width = min(1, max(0, fraction))
        if width > 0, abs(savedPrompterSetlistFraction - width) > 0.0001 { savedPrompterSetlistFraction = width }
        if prompterSetlistHidden != (width == 0) { prompterSetlistHidden = width == 0 }
    }
    private func finishPrompterResize() {
        if let livePrompterSetlistFraction { persistPrompterSetlistFraction(livePrompterSetlistFraction) }
        livePrompterSetlistFraction = nil; prompterResizeStart = nil
    }
    private func togglePrompterSetlist() {
        let restore = savedPrompterSetlistFraction.isFinite && savedPrompterSetlistFraction > 0 ? savedPrompterSetlistFraction : 0.30
        persistPrompterSetlistFraction(prompterSetlistFraction == 0 ? restore : 0)
        livePrompterSetlistFraction = nil; prompterResizeStart = nil
    }
    private func showPrompter(_ panel: PrompterPanel?) {
        finishPanelResize(); finishPrompterResize()
        if panel == nil { prompterFullscreen = false }
        else if local { VideoPlayback.shared.setVisible(false) }
        prompterPanel = panel
    }
    private func togglePrompterFullscreen() {
        guard prompterPanel != nil else { return }
        searchFocused = false
        finishPrompterResize()
        prompterFullscreen.toggle()
    }
    private func persistPanelWidths(_ widths: DAWRemotePanelWidths) {
        // A zero mixer width retains its previous nonzero size for the sidebar
        // toggle. The existing hidden preference records the collapsed state.
        if widths.track > 0, abs(savedTrackFraction - widths.track) > 0.0001 { savedTrackFraction = widths.track }
        if widths.setlist > 0 { savedVisibleSetlistFraction = widths.setlist }
        if abs(savedSetlistFraction - widths.setlist) > 0.0001 { savedSetlistFraction = widths.setlist }
        if mixerHidden != (widths.track == 0) { mixerHidden = widths.track == 0 }
    }
    private var mainSetlistVisible: Bool {
        !prompterFullscreen && (prompterPanel == nil ? panelWidths.setlist > 0 : prompterSetlistFraction > 0)
    }
    private func toggleNativeFocus() {
        nativeFocusOpen.toggle()
        if nativeFocusOpen && !horizontalPartsOpen { nativeLeftPartsOpen = false }
    }
    private func toggleMainTrackMixer() {
        finishPanelResize()
        let current = panelWidths
        let restored = savedTrackFraction.isFinite && savedTrackFraction > 0 ? savedTrackFraction : 0.30
        let expand = prompterPanel != nil || mixerCollapsed
        showPrompter(nil)
        persistPanelWidths(.init(track: expand ? min(restored, 1 - current.setlist) : 0, setlist: current.setlist))
    }
    private func toggleMainSetlist() {
        finishPanelResize()
        let current = panelWidths
        let restore = savedVisibleSetlistFraction.isFinite && savedVisibleSetlistFraction > 0 ? min(0.8, savedVisibleSetlistFraction) : 0.32
        let width = current.setlist > 0 ? 0 : restore
        persistPanelWidths(.init(track: min(current.track, 1 - width), setlist: width))
    }
    private func finishPanelResize() {
        if let livePanelWidths { persistPanelWidths(livePanelWidths) }
        livePanelWidths = nil; trackResizeStart = nil; setlistResizeStart = nil
    }
    private func finishNativePartsResize(available: Double, leftVisible: Bool, rightVisible: Bool) {
        guard nativeLeftPartsDragStart != nil || partsDragStart != nil else { return }
        let layout = RemoteNativePartsLayout(available: available,
            leftRequested: liveNativeLeftPartsWidth ?? nativeLeftPartsWidth,
            rightRequested: livePartsWidth ?? preferredPartsWidth,
            leftVisible: leftVisible, rightVisible: rightVisible)
        if leftVisible { nativeLeftPartsWidth = layout.left.content }
        if rightVisible { preferredPartsWidth = layout.right.content }
        liveNativeLeftPartsWidth = nil; nativeLeftPartsDragStart = nil
        livePartsWidth = nil; partsDragStart = nil
    }
    @State private var scrubPosition: Double?
    @State private var pendingSeek: Double?
    @State private var seekSentAt = Date.distantPast
    private var displayedPosition: Double {
        if !state.playing, let scrubPosition { return scrubPosition }
        if !state.playing, let pendingSeek, Date().timeIntervalSince(seekSentAt) < 2,
           abs(state.position - pendingSeek) > 0.1 { return pendingSeek }
        return state.position
    }
    private var selectedTimelineRegion: DAWRemoteState.Region? {
        let id = state.playing ? state.currentRegion : (state.focusedRegion ?? state.currentRegion)
        return (state.timelineRegions + state.regions).first { $0.id == id }
    }
    private var gridRegion: DAWRemoteState.Region? {
        DAWRemoteTimelinePresentation.region(in: state)
    }
    private var visibleTracks: [DAWRemoteState.Track] {
        guard local, let original = localShow?.current else { return itemLayoutCache.tracks(state.tracks, within: gridRegion) }
        let hidden = trackVisibility.state(for: state.project).effectiveHidden(in: original.tracks, area: .trackMixer)
        let timecode = Set(original.tracks.filter { $0.kind == .timecode }.map(\.id))
        var visible = state.tracks.filter { !hidden.contains($0.id) && !timecode.contains($0.id) }
        if editingTracks, let preview = trackHeightPreview,
           preview.project == state.project, preview.song == state.song,
           let index = visible.firstIndex(where: { $0.id == preview.track }) {
            visible[index].heightScale = preview.scale
        }
        var song = regionMovePreview.map { original.previewMovingRegion($0.id, to: $0.start) } ?? original
        if let move = trackScrolling.itemMove {
            song = song.movingItems(move.items, anchor: move.anchor, start: move.start, track: move.track) ?? song
        }
        if let mix = trackScrolling.itemMix { song = mix.applying(to: song) }
        guard regionMovePreview != nil || trackScrolling.itemMove != nil || trackScrolling.itemMix != nil else { return visible }
        let sourceTracks = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, $0) })
        let sourceClips = Dictionary(uniqueKeysWithValues: state.tracks.flatMap(\.clips).map { ($0.id, $0) })
        return visible.map { source in
            guard let native = sourceTracks[source.id] else { return source }
            var track = source
            let lanes = TrackLanes(track: native)
            track.laneCount = lanes.count
            track.clips = native.clips.compactMap { clip in
                guard var result = sourceClips[clip.id] else { return nil }
                result.start = clip.startTime; result.duration = clip.duration; result.gain = clip.gain
                result.lane = lanes.lanes[clip.id] ?? 0
                return result
            }
            return track
        }
    }
    private func toggleDrawer(_ id: UUID) {
        setDrawer(id, expanded: !expandedRegions.contains(id))
    }
    private func setDrawer(_ id: UUID, expanded: Bool) {
        guard DAWRemoteSetlistPresentation.canToggleDrawer(id, in: state) else { return }
        withAnimation(nil) {
            if expanded { expandedRegions.insert(id) }
            else { expandedRegions.remove(id) }
        }
    }
    private func action(_ action: DAWRemoteCommand.Action, target: UUID? = nil, value: Double = 0, playlist: UUID? = nil) {
        if action == .selectRegion, let target, !DAWRemoteSetlistPresentation.canQueueDuplicate(target, in: state) {
            duplicateQueueWarning = true
            return
        }
        if local, action == .selectRegion { trackScrolling.selectionScope = .setlist }
        send(.init(project: state.project, song: state.song, action: action, target: target, value: value, playlist: playlist))
    }
    private func showRemotePatch(_ track: UUID?) {
        let row = track.flatMap { id in state.tracks.first { $0.id == id } }
        guard track == nil || row != nil else { return }
        remotePatch = RemoteOutputPatchRequest(project: state.project, song: state.song, track: track,
            name: row?.name ?? "Main", channels: state.patchOutputChannels, hasGroup: row?.parentTrack != nil,
            routes: track == nil ? state.masterOutputRoutes : row?.outputRoutes)
    }
    private func updatePanelSubscription() {
        guard state.timer != nil else { return }
        let panel = phoneLayout ? (observer && phonePanel.subscription > 2 ? 0 : phonePanel.subscription) : (prompterPanel?.rawValue ?? (noticesOpen ? 3 : 0))
        action(.remotePanel, value: Double(panel))
    }
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if !local, !observer, !prompterFullscreen, phonePanel != .vinhetas, let tabs = state.projectTabs, tabs.count > 1 {
                RemoteProjectTabStrip(tabs: tabs, enabled: controlsEnabled && state.projects?.busy != true) {
                    action(.selectProjectTab, target: $0)
                }
            }
            Group {
                if phoneLayout {
                    if observer { phoneRepertoire } else { phoneDirectorWorkspace }
                }
                else if observer { observerWorkspace }
                else { directorWorkspace }
            }
        }
        .overlay(alignment: .top) {
            if observer, controlsEnabled, let cue = DAWRemoteSectionCue.current(in: state) {
                RemoteObserverSectionCue(cue: cue).padding(16).allowsHitTesting(false)
            }
        }
        .overlay {
            if creatingPlaylist, let createPlaylist {
                IpadCompactModal(preferredSize: CGSize(width: 540, height: 520)) {
                    IpadPlaylistCreator(regions: state.timelineRegions.filter { region in
                        guard region.parentRegion == nil else { return false }
                        guard let id = addingToPlaylist, let show = localShow,
                              let list = show.regionSetlist.playlists.first(where: { $0.id == id }) else { return true }
                        return !list.regionIds.contains(region.id)
                    },
                        adding: addingToPlaylist != nil, create: { name, ids in
                            if let id = addingToPlaylist { return localShow?.addRegionsToPlaylist(id, selected: ids) ?? false }
                            return createPlaylist(name, ids)
                        }, close: { creatingPlaylist = false; addingToPlaylist = nil })
                }
            }
        }
        .onChange(of: state.project) { _ in creatingPlaylist = false }
        .overlay {
            if let entry = editingEntry { IpadCompactModal {
                NameColorEditor(title: entry.block ? "Edit block" : entry.playlist ? "Rename playlist" : "Editar região", initialName: entry.name,
                    initialColor: entry.color, save: { name, color in
                    if entry.block { localShow?.editSetlistBlock(entry.id, name: name, color: color, symbol: editingBlockSymbol) }
                    else {
                        send(.init(project: state.project, song: state.song, action: entry.playlist ? .renamePlaylist : .editRegion,
                            target: entry.id, value: Double(color), text: name))
                    }
                }, close: { editingEntry = nil }, symbol: entry.block ? $editingBlockSymbol : nil)

            } }
        }
        .overlay {
            if let source = automaticSectionSource, let show = localShow {
                IpadCompactModal(preferredSize: CGSize(width: 700, height: 500)) {
                    AutomaticSectionEditor(show: show, source: source, close: { automaticSectionSource = nil })
                }
            } else if let id = configInitRegion, let show = localShow {
                IpadCompactModal { IpadRegionInitEditor(show: show, id: id, close: { configInitRegion = nil }) }
            } else if autoSettings, let show = localShow {
                IpadCompactModal { IpadAutoQueueEditor(show: show, close: { autoSettings = false }) }
            } else if let id = unifyingRegion, let show = localShow {
                IpadCompactModal {
                    VStack(spacing: 16) {
                        Text("Unify regions").font(.jarasHeadline)
                        TextField("Name", text: $unifyName).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Cancel") { unifyingRegion = nil }
                            Spacer()
                            Button("Unify") { if show.unifyRegions(containing: id, name: unifyName) { unifyingRegion = nil } }
                                .disabled(unifyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(18).frame(width: 300)
                }
            }
        }
        .alert("CatLive", isPresented: $duplicateQueueWarning) {
            Button("OK", role: .cancel) { }
        } message: { Text("Cannot queue a duplicate of the song that is playing.") }
        .overlay { if local { NativeSetlistControlMappingOverlay() } }
        .overlay { if !local && !observer { RemoteSetlistBlockMappingOverlay() } }
        .alert("Delete", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { removal = nil; nativeSetlistRemoval = nil }
            Button("Delete", role: .destructive) {
                if nativeSetlistRemoval != nil { confirmNativeSetlistRemoval() }
                else if let removal { send(removal) }
                removal = nil
            }
        } message: {
            if nativeSetlistRemoval?.blocksOnly == true {
                Text("Delete selected blocks?") + Text("\n\n") + Text("Only the selected block headers will be removed. Songs and timeline items will be kept.")
            } else {
                Text(removal?.action == .deletePlaylist ? "Delete playlist?" : (nativeSetlistRemoval?.playlist ?? removal?.playlist) == nil ? "Only the selected regions will be removed. Timeline items and their audio will be kept." : "Remove from playlist?")
            }
        }
        .onChange(of: state.project) { _ in editingEntry = nil; removal = nil; nativeSetlistRemoval = nil; confirmingRemoval = false }
        .onChange(of: controlsEnabled) { enabled in
            if !enabled {
                navigationOpen = false; projectsOpen = false; playlistPickerOpen = false
                noticesOpen = false; timerOpen = false; settingsOpen = false
                searchFocused = false; scrubPosition = nil; pendingSeek = nil
            } else { updatePanelSubscription() }
        }
        .confirmationDialog("Tracks", isPresented: $trackActionsOpen, titleVisibility: .visible) {
            if !selectedTracks.isEmpty, let openTrackDetails {
                Button("Set Track Color") { openTrackDetails(selectedTracks) }
            }
            if local, !selectedTracks.isEmpty, let openTrackIcon {
                Button("Set Track Icon") { openTrackIcon(selectedTracks) }
            }
            if !selectedTracks.isEmpty, let openSelectedPatch {
                Button("Patch") { openSelectedPatch(state.tracks.filter { selectedTracks.contains($0.id) }.map(\.id)) }
            }
            if selectedTracks.count == 1, let id = selectedTracks.first, groupableTracks.contains(id), let addTrackAudio {
                Button("Insert media") { addTrackAudio(id) }
            }
            Button("Create group") { groupTracks?(selectedTracks) }
                .disabled(selectedTracks.count < 2 || !selectedTracks.isSubset(of: groupableTracks))
            if localShow?.current?.groupsForTrackSelection(selectedTracks).isEmpty == false {
                Button("Ungroup") { localShow?.ungroupTracks(selectedTracks) }
            }
            if localShow?.current?.linkableTracks(selectedTracks) != nil {
                Button("Link tracks") { linkSelectedTracks(selectedTracks) }
            }
            if localShow?.current?.tracks.contains(where: { selectedTracks.contains($0.id) && $0.parentTrackID != nil }) == true {
                Button("Remove from group") {
                    for id in selectedTracks { localShow?.removeTrackFromGroup(id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var workspaceState: some View {
        AnyView(workspaceContent)
        .onChange(of: state.vinhetas) { next in if let next { remoteVinhetasFeedback.receive(next) } }
        .onChange(of: state.focusedRegion) { id in
            if local && nativeKeyboardBrowsing { selectedSetlistEntries = id.map { [$0] } ?? []; setlistSelectionAnchor = id }
        }
        .onChange(of: state.showsSetlistSelection) { visible in
            if !visible { selectedSetlistEntries = []; setlistSelectionAnchor = nil }
        }
        .onChange(of: state.selectedPlaylist) { _ in selectedSetlistEntries = []; draggingSetlistEntries = []; setlistSelectionAnchor = nil; nativeSetlistRemoval = nil; confirmingRemoval = false; localShow?.selectSetlistBlock(nil) }
        .onChange(of: state.project) { _ in remoteVinhetasFeedback.reset(); selectedSetlistEntries = []; draggingSetlistEntries = []; setlistSelectionAnchor = nil; editingTracks = false; selectedTracks.removeAll(); regionMovePreview = nil; trackReordering.cancel(); trackScrolling.selectedItem = nil; trackScrolling.pointerReset = UUID(); deletingTracks = nil; splittingItems = nil; nativeMarker = nil; nativeNormalization = false; tempoStepPending = false; tempoStepGate.reset(); tempoStepRequest = UUID(); pitchStepPending = false }
        .onAppear {
            if !local && !observer {
                RemoteMIDIActions.shared.start()
                SMK37Link.shared.bindRemote(sources: RemoteMIDIActions.shared.smkSourceIDs, event: remoteSMKEvent, poll: remoteSMKFeedback)
            }
            if local, let localShow {
                localShow.togglePartsPanel = { toggleLeftParts() }
                localShow.showPartsPanel = { showMappedParts() }
                localShow.smkPartsVisibility = {
                    ((nativeLeftPartsOpen || horizontalPartsOpen) && prompterPanel == nil && !prompterFullscreen,
                     phoneLayout ? phonePanel == .sections : sectionsOpen)
                }
                localShow.toggleSetlistPanel = { toggleMainSetlist() }
                localShow.toggleFocusPanel = { toggleNativeFocus() }
                localShow.toggleLibraryPanel = { nativeLibraryOpen.toggle() }
                localShow.toggleTracksPanel = { toggleMainTrackMixer() }
                localShow.toggleTeleprompterWindow = { showPrompter(prompterPanel == .first ? nil : .first) }
            }
        }
        .onDisappear { if !local { SMK37Link.shared.unbindRemote(); RemoteMIDIActions.shared.stop() } }
        .onReceive(trackScrolling.$itemSelection) { selection in
            if local { localShow?.reportItemSelection(selection.items) }
        }
        .onChange(of: state) { _ in
            guard !local, !observer else { return }
            SMK37Link.shared.updateRemote(event: remoteSMKEvent, poll: remoteSMKFeedback)
            finishRemoteSMKAction()
        }
        .onReceive(RemoteMIDIActions.shared.$event.dropFirst().compactMap { $0 }) { event in
            if !local && !observer {
                if let number = event.blockNumber { performRemoteBlockMIDI(number) }
                else if let action = event.action { performRemoteMIDI(action) }
            }
        }
        .onReceive(localShow?.setlistNavigationEvents.map(Optional.some).eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            guard local, let request, let localShow, let song = localShow.current else { return }
            let parts = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
            let entries: [SetlistEntry] = setlistRowsCache.entries(in: state, expanded: expandedRegions, query: search, order: local && state.selectedPlaylist == nil ? allRegionsOrder : nil).compactMap { entry in
                guard case .region(let row) = entry, let part = localShow.playlistRegion(row.region.id) ?? parts[row.region.id] else { return nil }
                return .region(part, number: row.number ?? 0)
            }
            if !entries.isEmpty {
                trackScrolling.selectionScope = .setlist
                nativeKeyboardBrowsing = true
                localShow.stepRegion(request.direction, entries: entries)
                selectedSetlistEntries = localShow.focusedRegion.map { [$0] } ?? []
                setlistSelectionAnchor = localShow.focusedRegion
            }
        }
        .onReceive(localShow?.$smkNavigation.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { smkNavigation = $0 }
        .onReceive(localShow?.$trackSelectionRequest.dropFirst().compactMap { $0 }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            trackScrolling.revealTrack(request.track)
        }
        .onReceive(localShow?.smkTrackScroll.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { trackScrolling.step($0) }
        .onReceive(localShow?.$selectedProgramChangeID.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { id in
            guard local, id != nil else { return }
            trackScrolling.itemSelection.replace([]); trackScrolling.selectionScope = .grid
            selectedTracks = []; localShow?.setMixerTrackSelection([], anchor: nil)
            TimelineAreaSelection.shared.clear()
        }
        .onChange(of: state.playing || state.subPlaying) { running in
            if !running { tempoStepGate.reset(); tempoStepPending = false; tempoStepRequest = UUID() }
        }
        .onChange(of: state.bpm) { _ in tempoStepPending = false }
        .onChange(of: state.pitchSemitones) { _ in pitchStepPending = false }
        .onChange(of: state.pitchRegion) { _ in tempoStepPending = false; pitchStepPending = false }
        .onChange(of: state.tracks.map(\.id)) { ids in selectedTracks.formIntersection(ids) }
        .onChange(of: visibleItemIDs) { ids in
            if local { trackScrolling.itemSelection.retain(ids) }
        }
        .onChange(of: state.tracks.filter { $0.emphasized == true }.map(\.id)) { ids in
            if local { selectedTracks = Set(ids) }
        }
    }
    private var nativeEditingWorkspace: some View {
        workspaceState
        .background {
            if local {
                IpadHardwareKeyboard(enabled: nativeInputEnabled,
                    onKey: handleNativeKey, onModifiersChanged: { hardwareModifiers = $0; trackScrolling.modifiers = $0 })
            }
        }
        .alert("Delete selected tracks and their items?", isPresented: Binding(
            get: { deletingTracks != nil }, set: { if !$0 { deletingTracks = nil } }), presenting: deletingTracks) { request in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if request.project == state.project, request.song == state.song { deleteNativeTracks(request.ids) }
            }
        }
        .alert("Split selected items at the edit cursor?", isPresented: Binding(
            get: { splittingItems != nil }, set: { if !$0 { splittingItems = nil } }), presenting: splittingItems) { request in
            Button("Cancel", role: .cancel) { }
            Button("Split") {
                if request.project == state.project, request.song == state.song { localShow?.splitItems(request.ids, at: request.position) }
            }
        }
        .sheet(isPresented: $nativeNormalization) {
            if let localShow, let documents = DAWRemoteHostBridge.documents {
                ItemNormalizationEditor(show: localShow, documents: documents, items: trackScrolling.itemSelection.items,
                    close: { nativeNormalization = false })
            }
        }
        .overlay {
            if let marker = nativeMarker {
                IpadCompactModal {
                    if marker.isTempo {
                        TempoMarkerEditor(marker: marker, save: { localShow?.setMarker($0) }, close: { nativeMarker = nil })
                    } else {
                        NameColorEditor(title: marker.isSection ? "Section marker" : "Editar marcador", initialName: marker.markerEditorName,
                            initialColor: marker.color, save: { name, color in
                                var edited = marker; edited.name = name; edited.color = color; localShow?.setMarker(edited)
                            }, close: { nativeMarker = nil }, maximumNameLength: marker.isSection ? TimelineMarker.maximumSectionNameLength : TimelineMarker.maximumNameLength)
                    }
                }
            }
        }
        .onReceive(localShow?.$addTrackRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            if nativeInputEnabled { addTrack?() }
        }
        .onReceive(localShow?.$splitItemsRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in beginNativeSplit() }
        .onReceive(localShow?.splitItemSelection.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { ids in
            if local { trackScrolling.itemSelection.replace(ids); trackScrolling.selectionScope = .grid }
        }
        .onReceive(localShow?.$normalizeItemsRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            if nativeInputEnabled, !trackScrolling.itemSelection.items.isEmpty { nativeNormalization = true }
        }
        .onReceive(localShow?.$itemProcessingRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            guard nativeInputEnabled, let request, !trackScrolling.itemSelection.items.isEmpty else { return }
            if request.action == .createRegionsFromItems {
                localShow?.regionsFromSelection(trackScrolling.itemSelection.items)
                return
            }
            processSelectedItems?(trackScrolling.itemSelection.items, request.action)
        }
        .onReceive(localShow?.$tempoMarkerRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in beginNativeMarker(tempo: true) }
    }
    var body: some View {
        AnyView(nativeEditingWorkspace)
        .onChange(of: selectedTracks) { ids in
            if local { AudioExportSelection.shared.setTracks(ids, song: state.song) }
        }
        .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
        .onChange(of: state.fadeout) { next in
            fadeoutReceivedAt = Date()
            if next?.lastCommandID == pendingFadeout?.id { pendingFadeout = nil }
        }
        .onChange(of: state.project) { _ in pendingFadeout = nil; fadeoutSettingsOpen = false }
        .overlay { fadeoutPresentation }
        .overlay(alignment: local ? .center : .topTrailing) {
            TrackMixFeedbackPanel(feedback: trackMixFeedback)
                .padding(.top, local ? 0 : phoneLayout ? 68 : 94)
                .padding(.trailing, local ? 0 : 12)
        }
        .onChange(of: state.project) { _ in trackMixFeedback.dismiss() }
        .onChange(of: state.song) { _ in trackMixFeedback.dismiss() }
        .onDisappear { trackMixFeedback.dismiss() }
        .sheet(item: $remotePatch) { request in
            RemoteOutputPatchSheet(request: request) { routes in
                guard state.project == request.project, state.song == request.song else { return }
                send(.init(project: request.project, song: request.song, action: .setOutputRoutes,
                    target: request.track, outputRoutes: routes))
            }
        }
        .task(id: state.project.uuidString + "\n" + state.message) {
            transientFooterNotice = local ? "" : state.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transientFooterNotice.isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            transientFooterNotice = ""
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { remotePortrait = geometry.size.height > geometry.size.width }
                .onChange(of: geometry.size) { size in remotePortrait = size.height > size.width }
        })
        .onChange(of: remotePortrait) { portrait in
            if portrait && horizontalPartsOpen { toggleLeftParts() }
        }
        .onChange(of: phoneLayout) { compact in
            if !local && !observer {
                if compact, let panel = prompterPanel { phonePanel = panel == .first ? .teleprompter1 : .teleprompter2 }
                else if !compact { prompterPanel = phonePanel == .teleprompter1 ? .first : phonePanel == .teleprompter2 ? .second : nil }
            }
            updatePanelSubscription()
        }
        .background(RemoteKeyboardDismissal(active: searchFocused) { searchFocused = false })
        .background(RemoteSidebarEdgeReveal(active:
            sidebarHidden && !prompterFullscreen && controlsEnabled && state.projects?.busy != true &&
                !navigationOpen && !projectsOpen && !playlistPickerOpen && !settingsOpen &&
                !timerOpen && !noticesOpen,
            reveal: revealSidebar))
        .overlay(alignment: .bottomLeading) {
            // These layouts have no visible transport footer. Keep a local
            // way back without adding playback controls to Observer mode.
            if sidebarHidden && !prompterFullscreen && (observer || keyboardVisible) {
                restoreSidebarButton(height: 31).background(RemoteSurface.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 4)).padding(.leading, 6)
                    .disabled(state.projects?.busy == true)
            }
        }
    }
    private var visibleItemIDs: Set<UUID> { Set(visibleTracks.flatMap(\.clips).map(\.id)) }
    private var nativeInputEnabled: Bool {
        local && !observer && controlsEnabled && state.projects?.busy != true && !creatingPlaylist &&
        editingEntry == nil && !trackActionsOpen && !confirmingRemoval && !duplicateQueueWarning &&
        !settingsOpen && !projectsOpen && !playlistPickerOpen && !timerOpen && !noticesOpen &&
        deletingTracks == nil && splittingItems == nil && !nativeNormalization &&
        nativeMarker == nil && configInitRegion == nil && unifyingRegion == nil && !autoSettings && !searchFocused
    }
    private func handleNativeKey(_ event: HardwareKeyboardEvent) -> Bool {
        guard event.phase == .down, let show = localShow else { return false }
        if ControlMappings.shared.editing != nil { return ControlMappings.shared.handleHardwareKey(event) }
        let flags = event.modifiers
        let command = flags == .command || flags == .control
        let shiftCommand = flags == [.command, .shift] || flags == [.control, .shift]
        if command || shiftCommand {
            switch event.keyCode {
            case 6: // Undo / Redo
                if !event.isRepeat { if shiftCommand { show.redo() } else { show.undo() } }
                return true
            case 0 where command:
                if trackScrolling.selectionScope == .tracks {
                    selectedTracks = Set(visibleTracks.filter { groupableTracks.contains($0.id) }.map(\.id))
                    show.setMixerTrackSelection(selectedTracks, anchor: selectedTracks.first)
                } else if trackScrolling.selectionScope == .grid {
                    trackScrolling.itemSelection.replace(Set(visibleTracks.flatMap(\.clips).map(\.id)))
                }
                return true
            case 8 where command, 7 where command:
                if trackScrolling.selectionScope == .tracks {
                    if !event.isRepeat && event.keyCode == 8 { _ = show.copyTracks(selectedTracks) }
                    return true
                }
                if show.selectedProgramChange != nil {
                    if !event.isRepeat { show.copyProgramChange() }
                    return true
                }
                guard trackScrolling.selectionScope == .grid else { return ControlMappings.shared.handleHardwareKey(event) }
                if !event.isRepeat { _ = show.copyItems(trackScrolling.itemSelection.items, moving: event.keyCode == 7) }
                return true
            case 9 where command:
                if show.hasTrackClipboard {
                    if !event.isRepeat {
                        let ids = show.pasteTracks()
                        if !ids.isEmpty { selectedTracks = ids; trackScrolling.selectionScope = .tracks }
                    }
                    return true
                }
                if show.hasProgramChangeClipboard {
                    if !event.isRepeat { show.pasteProgramChange() }
                    return true
                }
                if !event.isRepeat {
                    let pasted = show.pasteItems(selectedTracks: selectedTracks)
                    if !pasted.isEmpty { trackScrolling.itemSelection.replace(pasted); trackScrolling.selectionScope = .grid }
                }
                return true
            case 2 where command:
                if !event.isRepeat {
                    if trackScrolling.selectionScope == .tracks { show.duplicateTracks(selectedTracks) }
                    else if trackScrolling.selectionScope == .grid {
                        let ids = show.duplicateItems(trackScrolling.itemSelection.items)
                        if !ids.isEmpty { trackScrolling.itemSelection.replace(ids) }
                    }
                }
                return true
            default: break
            }
        }
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            if !event.isRepeat {
                if let marker = show.selectedProgramChangeID,
                   let track = show.current?.tracks.first(where: { ($0.programChanges ?? []).contains { $0.id == marker } }) {
                    show.removeProgramChange(track: track.id, marker: marker)
                } else { deleteNativeSelection() }
            }
            return true
        }
        if flags.isEmpty, event.keyCode == 53 {
            if !event.isRepeat {
                trackScrolling.pointerReset = UUID()
                show.send(.escape); show.selectProgramChange(nil)
                trackScrolling.itemSelection.replace([]); selectedTracks = []
                show.setMixerTrackSelection([], anchor: nil)
                selectedSetlistEntries = []; setlistSelectionAnchor = nil; show.selectSetlistBlock(nil)
            }
            return true
        }
        if flags.isEmpty, [36,76].contains(event.keyCode), trackScrolling.selectionScope == .setlist {
            if !event.isRepeat {
                _ = show.activateSetlistSelection()
                selectedSetlistEntries = show.focusedRegion.map { [$0] } ?? []
                setlistSelectionAnchor = show.focusedRegion
            }
            return true
        }
        if ControlMappings.shared.handleHardwareKey(event) { return true }
        if flags.isEmpty, event.keyCode == 125 || event.keyCode == 126,
           !mainSetlistVisible, panelWidths.track > 0, !visibleTracks.isEmpty {
            let tracks = visibleTracks.map(\.id)
            if let next = show.stepMixerTrack(event.keyCode == 125 ? 1 : -1, visible: tracks) {
                selectedTracks = [next]
                trackScrolling.selectionScope = .tracks
            }
            return true
        }
        if (flags == .shift || flags == .option), event.keyCode == 46 {
            if !event.isRepeat { beginNativeMarker(section: flags == .option) }
            return true
        }
        return false
    }
    private func deleteNativeSelection() {
        guard let show = localShow, show.current != nil else { return }
        switch trackScrolling.selectionScope {
        case .grid:
            show.deleteItems(trackScrolling.itemSelection.items.intersection(visibleTracks.flatMap(\.clips).map(\.id)))
            trackScrolling.itemSelection.retain(Set(show.current?.tracks.flatMap(\.clips).map(\.id) ?? []))
        case .tracks:
            requestNativeTrackDeletion(selectedTracks)
        case .setlist:
            requestNativeSetlistRemoval(selectedSetlistEntries)
        }
    }
    private func requestNativeSetlistRemoval(_ selection: Set<UUID>) {
        guard local, let show = localShow, let song = show.current,
              show.snapshot.project.id == state.project, song.id == state.song else { return }
        let ids = show.deletableSetlistEntries(selection)
        guard !ids.isEmpty else { return }
        trackScrolling.selectionScope = .setlist
        nativeSetlistRemoval = .init(project: state.project, song: song.id, playlist: show.selectedRegionPlaylist?.id,
            ids: ids, blocksOnly: ids.isSubset(of: Set(show.listedBlocks.map(\.id))))
        removal = nil; confirmingRemoval = true
    }
    private func confirmNativeSetlistRemoval() {
        defer { nativeSetlistRemoval = nil; confirmingRemoval = false }
        guard let request = nativeSetlistRemoval, let show = localShow,
              show.snapshot.project.id == request.project, show.current?.id == request.song,
              show.selectedRegionPlaylist?.id == request.playlist else { return }
        guard show.deleteSetlistEntries(request.ids) else { return }
        selectedSetlistEntries.subtract(request.ids)
        if let anchor = setlistSelectionAnchor, request.ids.contains(anchor) { setlistSelectionAnchor = nil }
        show.selectSetlistBlock(selectedSetlistEntries.count == 1 ? selectedSetlistEntries.first : nil)
    }
    private func requestNativeTrackDeletion(_ selection: Set<UUID>) {
        guard let show = localShow, let song = show.current else { return }
        let ids = selection.intersection(song.tracks.map(\.id))
        guard !ids.isEmpty else { return }
        if show.snapshot.project.tracksContainItems(ids) { deletingTracks = (state.project, song.id, ids) }
        else { deleteNativeTracks(ids) }
    }
    private func deleteNativeTracks(_ ids: Set<UUID>) {
        guard let show = localShow else { return }
        show.deleteTracks(ids)
        selectedTracks.formIntersection(show.current?.tracks.map(\.id) ?? [])
        show.setMixerTrackSelection(selectedTracks, anchor: selectedTracks.first)
    }
    private func beginNativeSplit() {
        guard nativeInputEnabled, let show = localShow, let song = show.current else { return }
        let time = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        let selection = trackScrolling.itemSelection.items
        let ids = Set(song.tracks.filter { $0.kind != .timecode }.flatMap(\.clips).filter {
            (selection.isEmpty || selection.contains($0.id)) && $0.startTime < time && $0.startTime + $0.duration > time
        }.map(\.id))
        if !ids.isEmpty { splittingItems = (state.project, song.id, ids, time) }
    }
    private func beginNativeMarker(section: Bool = false, tempo: Bool = false) {
        guard nativeInputEnabled, let show = localShow, let song = show.current else { return }
        let position = show.snapshot.transport.editPosition ?? show.snapshot.transport.position
        guard show.canCreateMarker(at: position, tempo: tempo), !section || show.canCreateSectionMarker(at: position) else { return }
        let settings = song.tempoSection(at: position)
        nativeMarker = TimelineMarker(id: UUID(), name: tempo ? "TEMPO" : "", position: position, color: 0x51ef93,
            tempoBPM: tempo ? settings.bpm : nil, tempoBeats: tempo ? settings.beats : nil,
            tempoUnit: tempo ? settings.unit : nil, tempoTimebase: tempo ? .global : nil, section: section ? true : nil)
    }
    private func hideSidebar() {
        finishPanelResize(); finishPrompterResize()
        searchFocused = false; navigationOpen = false; playlistPickerOpen = false
        noticesOpen = false; timerOpen = false; settingsOpen = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(nil) { sidebarHidden = true }
    }
    private func revealSidebar() {
        withAnimation(nil) { sidebarHidden = false }
    }
    private func hideSidebarButton(width: CGFloat) -> some View {
        Button(action: hideSidebar) {
            Image(systemName: "chevron.left").font(.jarasSystem(size: 13, weight: .semibold))
                .frame(width: width, height: RemoteSidebarMetrics.buttonSize).contentShape(Rectangle())
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green).accessibilityLabel("Hide sidebar")
    }
    private func restoreSidebarButton(height: CGFloat = 25) -> some View {
        Button(action: revealSidebar) {
            Image(systemName: "chevron.right").font(.jarasSystem(size: 15, weight: .bold))
                .frame(width: 44, height: height).contentShape(Rectangle())
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green)
            .accessibilityLabel("Show sidebar").accessibilityIdentifier("remote-show-sidebar")
    }
    private func openHorizontalParts() {
        guard !remotePortrait, !observer else { return }
        searchFocused = false
        if phoneLayout {
            if phonePanel == .sections || phonePanel == .vinhetas { choosePhonePanel(.grid) }
        } else {
            showPrompter(nil)
            prompterFullscreen = false
            nativeLeftPartsOpen = false
            sectionsOpen = false
            liveNativeLeftPartsWidth = nil; nativeLeftPartsDragStart = nil
        }
        horizontalPartsOpen = true
    }
    private func toggleLeftParts() {
        if horizontalPartsOpen {
            horizontalPartsOpen = false
        } else if phoneLayout {
            choosePhonePanel(.sections)
        } else {
            nativeLeftPartsOpen.toggle()
            if local && nativeLeftPartsOpen { nativeFocusOpen = false }
            liveNativeLeftPartsWidth = nil; nativeLeftPartsDragStart = nil
        }
    }
    private func choosePhonePanel(_ panel: DAWRemotePhonePanel) {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let next = phonePanel.selecting(panel)
        phonePanel = observer && next == .grid ? .setlist : next
        horizontalPartsOpen = false
        prompterFullscreen = false
        scrubPosition = nil; pendingSeek = nil
    }
    @ViewBuilder private func phonePanelButton(_ panel: DAWRemotePhonePanel, title: String, icon: String? = nil) -> some View {
        let active = phonePanel == panel || (panel == .sections && horizontalPartsOpen)
        let button = Button { choosePhonePanel(panel) } label: {
            Group {
                if panel == .sections { ControlIcon(name: "list.bullet.indent", active: active, size: 21) }
                else if let icon { ControlIcon(name: icon, active: active, size: 21) }
                else { Text(verbatim: title).font(.jarasSystem(size: 11, weight: .bold)) }
            }.frame(width: 44, height: 44)
                .modifier(RemoteControlSurface(color: active ? JarasTheme.green.opacity(0.14) : nil, radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle())
            .foregroundStyle(JarasTheme.toolbarTint(active: active))
            .accessibilityLabel(LocalizedStringKey(title)).accessibilityValue(active ? "Shown" : "Hidden")
        if panel == .sections && !remotePortrait && !observer {
            button.overlay { IpadTapHoldTouchSurface(tap: toggleLeftParts, hold: openHorizontalParts) }
                .accessibilityAction(named: Text("Hoz-Parts"), openHorizontalParts)
        } else {
            button
        }
    }
    private var remoteVinhetasScreen: some View {
        RemoteVinhetasScreen(state: state.vinhetas, project: state.project, song: state.song,
            phone: phoneLayout, send: send, feedback: $remoteVinhetasFeedback)
    }
    private var cancelSectionButton: some View {
        Button { action(.cancelSection) } label: {
            Text("Cancel").font(.jarasSystem(size: 12, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 28)
                .contentShape(Rectangle())
        }.buttonStyle(RemoteCancelSectionButtonStyle())
            .disabled(state.sectionPlayback?.queuedMarker == nil)
            .accessibilityLabel("Cancel queued section")
    }
    private var phoneDirectorPanel: AnyView {
                    switch phonePanel {
                    case .vinhetas: return AnyView(remoteVinhetasScreen)
                    case .mixer: return AnyView(trackMixer)
                    case .setlist: return AnyView(setlist)
                    case .grid:
                        return AnyView(RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition, local: local, localShow: localShow, timelineFocus: timelineFocus, editorEnabled: nativeInputEnabled,
                                    touchItemEditing: editingTracks, showRegionLanes: showNativeRegionLanes, showTempoLane: showNativeTempoLane, regionDrag: $regionMovePreview, openRegionActions: openRegionActions, openItemMenu: openItemMenu, openSelectedItemMenu: openSelectedItemMenu, openItemFX: openItemFX, openMarkerEditor: { nativeMarker = $0 }, regionCommand: { id, command in
                            if command == "bpm" { detectRegionBPM?(id) }
                            else if command == "loops" { openRegionLoops?(id) }
                            else if command == "unify" { unifyName = ""; unifyingRegion = id }
                            else if command == "init" { configInitRegion = id }
                            else if command == "multitrack" { multitrackAction?(id, localShow?.selectedTimelineRegions ?? []) }
                        },
                            control: { action($0, target: $1, value: $2) }, preview: { scrubPosition = $0 }, seek: { position in
                                scrubPosition = nil
                                if local { action(.seek, value: position); return }
                                guard !state.playing, let region = selectedTimelineRegion else { return }
                                pendingSeek = position; seekSentAt = Date(); action(.seek, target: region.id, value: position)
                            }))
                    case .teleprompter1, .teleprompter2:
                        return AnyView(RemoteNativeTeleprompterPanel(index: phonePanel.subscription, timer: timer,
                            fullscreen: prompterFullscreen, toggleFullscreen: { prompterFullscreen.toggle() }, managesSubscription: false, remote: remote))
                    case .notices:
                        return AnyView(RemoteNativeNoticesView(close: { choosePhonePanel(.grid) }, managesSubscription: false, remote: remote))
                    case .sections: return AnyView(remoteSections())
                    }

    }
    private var phoneDirectorWorkspace: some View {
        GeometryReader { geometry in
        HStack(spacing: sidebarCollapsed ? 0 : 1) {
            RemoteSidebarRail(hidden: sidebarCollapsed) {
                Menu {
                    Button("Projects") { projectsOpen = true }
                    Button("Exit Remote", action: exitRemote)
                } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Menu")
                phonePanelButton(.mixer, title: "Track Mixer", icon: "trackMixer")
                phonePanelButton(.setlist, title: "Setlist", icon: "list.bullet.indent")
                phonePanelButton(.grid, title: "Grid", icon: "square.grid.3x3")
                phonePanelButton(.sections, title: "Parts")
                phonePanelButton(.vinhetas, title: "Pads", icon: "square.grid.3x2.fill")
                phonePanelButton(.teleprompter1, title: "TP1")
                phonePanelButton(.teleprompter2, title: "TP2")
                phonePanelButton(.notices, title: "Notices", icon: "text.bubble")
                Button { timerOpen = true } label: { ControlIcon(name: "stopwatch", active: timerOpen, size: 21).frame(width: 44, height: 44) }
                    .foregroundStyle(JarasTheme.toolbarTint(active: timerOpen)).accessibilityLabel("Timer")
                IpadPreviewButton(width: 44, horizontal: false, active: state.previewActive == true, page: state.previewPage ?? 0, toggle: { action(.togglePreview) }, selectPage: { action(.selectPreviewPage, value: Double($0)) }).disabled(state.previewActive == nil)
                Button { action(.save) } label: {
                    ControlIcon(name: "save", active: state.pendingSave, size: 21).frame(width: 44, height: 44)
                }.foregroundStyle(JarasTheme.toolbarTint(active: state.saving)).disabled(!state.pendingSave || state.saving)
                    .accessibilityLabel("Save")
                Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                RemoteDesktopBatteryBadge(percent: state.desktopBatteryPercent, vertical: true)
                Button { if let openSettings { openSettings() } else { settingsOpen = true } } label: { ControlIcon(name: "gearshape", active: settingsOpen, size: 21).frame(width: 44, height: 44) }
                    .foregroundStyle(JarasTheme.toolbarTint(active: settingsOpen)).accessibilityLabel("Configurações")
                if UIDevice.current.userInterfaceIdiom == .pad { hideSidebarButton(width: 44) }
            }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarInactive)
            VStack(spacing: 1) {
                if !prompterFullscreen && phonePanel != .vinhetas { phoneTransport }
                phoneDirectorPanel.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                if phonePanel == .setlist || phonePanel == .sections {
                    setlistControls.padding(.horizontal, 10)
                }
                if horizontalPartsOpen && !remotePortrait && !prompterFullscreen {
                    horizontalPartsDock(defaultHeight: min(192, geometry.size.height * 0.42))
                }
                if !keyboardVisible && !prompterFullscreen && phonePanel != .vinhetas {
                    VStack(spacing: 0) {
                        SongNameDisplay(title: "Next song label", name: state.songDisplays?.next, bpm: state.songDisplays?.nextBPM)
                            .frame(height: 25)
                        Rectangle().fill(JarasTheme.line).frame(height: 1)
                        SongNameDisplay(title: state.subPlaying ? "Sub Play" : "Queued", name: state.songDisplays?.queued, bpm: state.songDisplays?.queuedBPM)
                            .frame(height: 25)
                        Rectangle().fill(JarasTheme.line).frame(height: 1)
                        HStack(spacing: 0) {
                            if sidebarHidden { restoreSidebarButton() }
                            phoneInformationDisplay.frame(maxWidth: .infinity)
                        }.frame(height: 25)
                    }.background(RemoteSurface.display)
                        .overlay(Rectangle().stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
                }
            }.frame(maxWidth: .infinity).disabled(state.projects?.busy == true)
        }
        }.background(RemoteSurface.background)
            .onAppear(perform: updatePanelSubscription)
            .onChange(of: phonePanel) { _ in updatePanelSubscription() }
            .onChange(of: state.project) { _ in updatePanelSubscription() }
            .onDisappear { action(.remotePanel, value: 0) }
            .onChange(of: state.position) { position in
                if let pendingSeek, abs(position - pendingSeek) <= 0.1 { self.pendingSeek = nil }
            }
            .onChange(of: state.playing) { _ in scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.focusedRegion) { _ in scrubPosition = nil; pendingSeek = nil }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            .sheet(isPresented: $timerOpen) {
                RemoteNativeTimerView(timer: timer, send: {
                    guard state.timer != nil else { return }
                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                }, close: { timerOpen = false }).presentationDetents([.height(280)]).preferredColorScheme(.dark)
            }
            .sheet(isPresented: $settingsOpen) { NativeRemoteSettingsView().presentationDetents([.large]).preferredColorScheme(.dark) }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) },
                    openInNewTab: { action(.openRecentProjectInNewTab, target: $0) },
                    close: { projectsOpen = false }, exit: { projectsOpen = false; exitRemote() })
            }
    }
    private func phoneTransportButton(_ title: String, icon: String, active: Bool = false, color: Color = JarasTheme.green,
                                      iconOnly: Bool = false, solid: Bool = false, perform: @escaping () -> Void) -> some View {
        let label = title == "Stop" ? Text(verbatim: title) : Text(LocalizedStringKey(title))
        return Button(action: perform) {
            VStack(spacing: 3) {
                TransportControlIcon(name: icon, size: 16)
                if !iconOnly { label.font(.jarasSystem(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7) }
            }.frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteControlSurface(color: solid ? color : active ? color.opacity(0.35) : nil, radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(solid ? (active ? Color.black : .white) : color).accessibilityLabel(label)
    }
    private var transportProgress: some View {
        let region = state.transportDisplayRegion
        return SongProgressBar(position: state.playing || state.paused ? state.position : nil,
                               start: region?.start, end: region?.end)
    }
    private var phoneTransport: some View {
        VStack(spacing: 4) {
            Text(verbatim: state.currentSongName)
                .font(.jarasSystem(size: 13, weight: .semibold))
                .foregroundStyle(state.playing ? JarasTheme.green : JarasTheme.text)
                .lineLimit(1).truncationMode(.tail).padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 25)
                .background(RemoteSurface.display)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottom) { transportProgress.padding(.horizontal, 3) }
            HStack(spacing: 4) {
                phoneTransportButton(state.playing || state.paused ? "Stop" : "Play", icon: state.playing || state.paused ? "stopall" : "play", active: state.playing) {
                    action(state.playing || state.paused ? .stop : .play)
                }
                fadeoutButton(width: nil, height: 44)
                phoneTransportButton(state.paused ? "Play" : "Pause", icon: state.paused ? "play" : "pause", active: state.paused,
                                     color: JarasTheme.pauseBackground(state.paused), iconOnly: true, solid: true) {
                    action(state.paused ? .play : .pause)
                }.disabled(!state.playing && !state.paused)
                phoneTransportButton("Repeat", icon: "loop", active: state.loop, color: state.loop ? JarasTheme.yellow : Color(hex: 0x454545), iconOnly: true, solid: true) { action(.toggleLoop) }
            }
            GeometryReader { geometry in
                let width = max(0, (geometry.size.width - 4) / 2)
                HStack(spacing: 4) {
                    nativeTransportStepper(width: width, pitch: false)
                    nativeTransportStepper(width: width, pitch: true)
                }
            }.frame(height: 32)
        }.padding(6).background(RemoteSurface.panel)
    }
    private var footerInformationText: String {
        if !transientFooterNotice.isEmpty { return transientFooterNotice }
        return state.loop ? "Loop Ativo" : state.footerInformation ?? ""
    }
    private var phoneInformationDisplay: some View {
        TransportInformationMessage(message: footerInformationText,
            beatPhase: transientFooterNotice.isEmpty && state.loop ? state.footerLoopBeatPhase : nil, steady: !transientFooterNotice.isEmpty || !state.loop)
            .font(.jarasSystem(size: 10, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
            .multilineTextAlignment(.center).accessibilityLabel("Information")
    }
    private var observerSettingsButton: some View {
        Button { settingsOpen = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
            .foregroundStyle(JarasTheme.toolbarTint(active: settingsOpen)).accessibilityLabel("Configurações")
            .popover(isPresented: $settingsOpen) { NativeRemoteSettingsView(observer: true).preferredColorScheme(.dark) }
    }
    private var phoneRepertoire: some View {
        HStack(spacing: sidebarCollapsed ? 0 : 1) {
            RemoteSidebarRail(hidden: sidebarCollapsed) {
                Menu { Button("Exit Remote", action: exitRemote) } label: {
                    Image(systemName: "line.3.horizontal").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Menu")
                phonePanelButton(.setlist, title: "Setlist", icon: "list.bullet.indent")
                phonePanelButton(.teleprompter1, title: "TP1")
                phonePanelButton(.teleprompter2, title: "TP2")
                Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                RemoteDesktopBatteryBadge(percent: state.desktopBatteryPercent, vertical: true)
                observerSettingsButton
                if UIDevice.current.userInterfaceIdiom == .pad { hideSidebarButton(width: 44) }
            }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarInactive)
            VStack(spacing: 1) {
                if !prompterFullscreen {
                    VStack(spacing: 5) {
                        phoneObserverDisplay(nil, name: state.currentSongName, color: JarasTheme.green)
                        phoneObserverDisplay("Queued", name: state.songDisplays?.queued ?? observerQueuedName, color: JarasTheme.yellow)
                        phoneInformationDisplay
                            .overlay(Rectangle().stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
                    }.padding(6).background(RemoteSurface.panel)
                }
                if phonePanel == .teleprompter1 || phonePanel == .teleprompter2 {
                    RemoteNativeTeleprompterPanel(index: phonePanel.subscription, timer: timer,
                        fullscreen: prompterFullscreen, toggleFullscreen: { prompterFullscreen.toggle() }, managesSubscription: false, remote: remote)
                } else { observerSetlist }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(RemoteSurface.background)
            .onAppear(perform: updatePanelSubscription)
            .onChange(of: phonePanel) { _ in updatePanelSubscription() }
            .onChange(of: state.project) { _ in updatePanelSubscription() }
            .onDisappear { action(.remotePanel, value: 0) }
    }
    private func phoneObserverDisplay(_ title: String?, name: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(LocalizedStringKey(title)).font(.jarasSystem(size: 10, weight: .bold, design: .rounded)).foregroundStyle(JarasTheme.secondary)
            }
            Text(verbatim: name).font(.jarasSystem(size: 13, weight: .semibold)).foregroundStyle(color).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RemoteSurface.display).cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
    }
    private var observerWorkspace: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - (sidebarCollapsed ? 0 : RemoteSidebarMetrics.width + 1))
            let portrait = geometry.size.height > geometry.size.width
            let headerLayout = portrait ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            HStack(spacing: sidebarCollapsed ? 0 : 1) {
                RemoteSidebarRail(hidden: sidebarCollapsed) {
                    Button { navigationOpen.toggle() } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }
                        .accessibilityLabel("Abrir barra lateral")
                    topPrompterButton(.first, title: "TP1", minimumHeight: RemoteSidebarMetrics.buttonSize)
                    topPrompterButton(.second, title: "TP2", minimumHeight: RemoteSidebarMetrics.buttonSize)
                    Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                    RemoteDesktopBatteryBadge(percent: state.desktopBatteryPercent, vertical: true)
                    observerSettingsButton
                if UIDevice.current.userInterfaceIdiom == .pad { hideSidebarButton(width: 44) }
                }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                VStack(spacing: 8) {
                    if !prompterFullscreen {
                        HStack(spacing: 8) {
                            headerLayout {
                                observerDisplay(state.playing ? "Tocando" : "Selecionada", value: observerCurrentName, color: JarasTheme.green)
                                observerDisplay("Fila de espera", value: observerQueuedName, color: JarasTheme.yellow)
                            }.frame(maxWidth: .infinity)
                            headerLayout {
                                topPrompterButton(.first, title: "TP1", minimumHeight: portrait ? 44 : 25).frame(width: 52)
                                topPrompterButton(.second, title: "TP2", minimumHeight: portrait ? 44 : 25).frame(width: 52)
                            }
                        }.padding(8).background(RemoteSurface.panel)
                    }
                    GeometryReader { content in
                        let listVisible = !prompterFullscreen && (prompterPanel == nil || prompterSetlistFraction > 0)
                        let sharedHeight = max(0, content.size.height - 8)
                        let layout = portrait ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                        // Keep both panels mounted when rotating so the selected
                        // teleprompter and the list's scroll position are retained.
                        layout {
                            if let panel = prompterPanel {
                                RemoteNativeTeleprompterPanel(index: panel.rawValue, timer: timer,
                                    fullscreen: prompterFullscreen, toggleFullscreen: togglePrompterFullscreen,
                                    toggleSetlist: togglePrompterSetlist, setlistVisible: prompterSetlistFraction > 0, managesSubscription: false, remote: remote)
                                    .frame(width: portrait || !listVisible ? width : width * 0.70,
                                           height: portrait ? (listVisible ? sharedHeight * 0.60 : content.size.height) : nil)
                                    .clipped()
                            }
                            if listVisible {
                                observerSetlist
                                    .frame(height: portrait && prompterPanel != nil ? sharedHeight * 0.40 : nil)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(maxHeight: .infinity)
                }.frame(width: width)
            }
        }.background(RemoteSurface.background)
            .overlay(alignment: .topLeading) {
                if navigationOpen {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.3).onTapGesture { navigationOpen = false }
                        VStack(alignment: .leading) {
                            Button(action: exitRemote) { Label("Sair", systemImage: "rectangle.portrait.and.arrow.right").padding(16) }
                            Spacer()
                        }.frame(width: 190).frame(maxHeight: .infinity).background(RemoteSurface.panel)
                    }
                }
            }
            .onAppear(perform: updatePanelSubscription)
            .onChange(of: prompterPanel) { _ in updatePanelSubscription() }
            .onChange(of: state.project) { _ in updatePanelSubscription() }
            .onDisappear { action(.remotePanel, value: 0) }
    }
    private var observerCurrentName: String {
        let id = state.playing ? state.currentRegion : state.focusedRegion ?? state.currentRegion
        return state.timelineRegions.first { $0.id == id }?.name ?? state.regions.first { $0.id == id }?.name ?? state.songName
    }
    private var observerQueuedName: String {
        state.timelineRegions.first { $0.id == state.queuedRegion }?.name ?? state.regions.first { $0.id == state.queuedRegion }?.name ?? "—"
    }
    private func observerDisplay(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.jarasCaption2).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: value).font(.jarasSystem(size: 15, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RemoteSurface.display).cornerRadius(5)
    }
    private var observerSetlist: some View {
        let played = Set(state.playedLiveRegionIDs ?? [])
        let focus = DAWRemoteSetlistPresentation.observerFocus(in: state, expanded: expandedRegions)
        return ScrollViewReader { scroll in
        ScrollView(.vertical) {
            LazyVStack(spacing: 5) {
                ForEach(setlistRowsCache.entries(in: state, expanded: expandedRegions, query: "")) { entry in
                    switch entry {
                    case .block(let block): RemoteSetlistBlockLabel(block: block, fontStyle: state.setlistFontStyle ?? 0, scale: min(2.5, max(1, observerSetlistScale))).equatable()
                    case .region(let row):
                    let region = row.region
                    setlistLabel(region.name, number: row.number, played: played.contains(region.sourceRegionId ?? region.id), selected: region.id == focus,
                        active: state.playing && observerRegion(region.id, contains: state.setlistCurrentEntryId), queued: observerRegion(region.id, contains: state.setlistQueuedEntryId),
                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? 0xffffff),
                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.setlistCurrentEntryId ? state.position : region.start)))),
                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                        .modifier(NativeRegionDrawerGesture(enabled: !phoneLayout && row.hasDrawer,
                            expanded: expandedRegions.contains(region.id),
                            change: { setDrawer(region.id, expanded: $0) }))
                        .modifier(RemoteRegionDrawerGesture(enabled: phoneLayout && row.hasDrawer, toggle: { toggleDrawer(region.id) }))
                        .padding(.leading, row.child ? 20 : 0)
                    }
                }
                if !local && state.regions.isEmpty && (state.setlistBlocks?.isEmpty ?? true) {
                    ForEach(state.songs) { song in Text(verbatim: song.name).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RemoteSurface.panel).cornerRadius(5) }
                }
            }.padding(8)
        }
        .onAppear { if let focus { scroll.scrollTo(DAWRemoteSetlistPresentation.Entry.ID.region(focus)) } }
        .onChange(of: focus) { id in
            if let id { scroll.scrollTo(DAWRemoteSetlistPresentation.Entry.ID.region(id)) }
        }
        }
    }
    private func observerRegion(_ region: UUID, contains id: UUID?) -> Bool {
        guard let id else { return false }
        return id == region || state.timelineRegions.first { $0.id == id }?.parentRegion == region
    }
    @ViewBuilder private func leftPartsButton(width: CGFloat) -> some View {
        let button = Button(action: toggleLeftParts) {
            ControlIcon(name: "list.bullet.indent", active: nativeLeftPartsOpen || horizontalPartsOpen).frame(width: width, height: 32)
        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
            .foregroundStyle(JarasTheme.toolbarTint(active: nativeLeftPartsOpen || horizontalPartsOpen))
            .accessibilityLabel("Parts à esquerda")
            .accessibilityValue(nativeLeftPartsOpen || horizontalPartsOpen ? "Shown" : "Hidden")
        if remotePortrait {
            button
        } else {
            button.overlay { IpadTapHoldTouchSurface(tap: toggleLeftParts, hold: openHorizontalParts) }
                .accessibilityAction(named: Text("Hoz-Parts"), openHorizontalParts)
        }
    }
    private var directorWorkspace: some View {
        GeometryReader { geometry in
            let railButton: CGFloat = 34
            let contentWidth = max(0, geometry.size.width)
            let showNativePanels = local && prompterPanel == nil && !prompterFullscreen && localShow != nil
            let proWidth = showNativePanels && nativeProMode && nativeProDock != nil ? min(290,contentWidth * 0.23) : 0
            let focusWidth = showNativePanels && nativeFocusOpen ? FooterHorizontalMixer.focusWidth : 0
            let referenceSpace = max(1, contentWidth - (local && prompterPanel == nil ? 10 : 20))
            let minimumTrack = Double(SidebarWidthLimits.nativeTrackMixer)
            let libraryAvailable = max(0, referenceSpace - focusWidth - (mixerCollapsed ? 0 : minimumTrack))
            let libraryMaximum = WorkspaceLibrary.maximumWidth(folders: nativeLibraryFoldersWidth, available: libraryAvailable)
            let libraryWidth = showNativePanels && nativeLibraryOpen ? min(libraryMaximum, liveLibraryWidth ?? nativeLibraryWidth) : 0
            let panelSpace = max(1, referenceSpace - libraryWidth - focusWidth - proWidth)
            let nativeWidths = NativeWorkspacePanelWidths(preferred: panelWidths, reference: referenceSpace, available: panelSpace,
                                                          minimumTrack: minimumTrack, iconWidth: 0)
            let trackWidth = local ? nativeWidths.track : panelSpace * panelWidths.track
            let normalSetlist = local ? nativeWidths.setlist : panelSpace * panelWidths.setlist
            let baseSetlist = prompterFullscreen ? 0 : prompterPanel == nil ? normalSetlist : max(1, contentWidth - 10) * prompterSetlistFraction
            let gridWidth = local ? nativeWidths.grid : max(0, panelSpace - trackWidth - normalSetlist)
            let freeSpace = prompterPanel == nil ? gridWidth : max(0, contentWidth - 10 - baseSetlist)
            let rightPartsVisible = sectionsOpen && !horizontalPartsOpen && baseSetlist > 0 && !prompterFullscreen
            let nativeParts = RemoteNativePartsLayout(available: freeSpace,
                leftRequested: liveNativeLeftPartsWidth ?? nativeLeftPartsWidth,
                rightRequested: livePartsWidth ?? preferredPartsWidth,
                leftVisible: nativeLeftPartsOpen && !horizontalPartsOpen && prompterPanel == nil && !prompterFullscreen,
                rightVisible: rightPartsVisible)
            let leftParts = nativeParts.left
            let parts = nativeParts.right
            let padsHeight = local && nativeVinhetasOpen && !nativeVinhetasDetached && !prompterFullscreen
                ? min(260, geometry.size.height * 0.42) : 0
            let pianoHeight: CGFloat = local && nativePianoOpen && !prompterFullscreen ? 108 : 0
            let partsHeight = horizontalPartsOpen && !prompterFullscreen && prompterPanel == nil
                ? min(192, geometry.size.height * 0.42) * min(1.5, max(1, horizontalPartsHeightScale)) : 0
            let dockAvailable = max(0, geometry.size.height - 250 - padsHeight - pianoHeight - partsHeight)
            let mixerDocked = local && hozMixerOpen && !nativeHozMixerDetached && !prompterFullscreen
            let previewMaximum = min(724, max(0, dockAvailable - (mixerDocked ? 160 : 0)))
            let previewMinimum = min(170, previewMaximum)
            let previewInitial = min(previewMaximum, max(previewMinimum, nativeMIDIPreviewHeight))
            let previewHeight = local && nativeMIDIPreviewOpen && !nativeMIDIPreviewDetached && !prompterFullscreen && prompterPanel == nil
                ? min(previewMaximum, max(previewMinimum, previewInitial - nativeMIDIPreviewResize)) : 0
            let dockLimit = max(0, dockAvailable - previewHeight)
            let maximumDockHeight = min(724, dockLimit)
            let minimumDockHeight = min(160, maximumDockHeight)
            let initialDockHeight = min(maximumDockHeight, max(minimumDockHeight, nativeMixerHeight))
            let dockHeight = mixerDocked
                ? min(maximumDockHeight, max(minimumDockHeight, initialDockHeight - mixerHeightTranslation)) : 0
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if local, let openHome, let openNativeProject, let exportNativeAudio {
                        Menu {
                            Button("Home", action: openHome)
                            Button { openNativeProject() } label: { Text(verbatim: "Open") }
                            Button { action(.save) } label: { Text(verbatim: "Save") }
                            Button { exportNativeAudio() } label: { Text(verbatim: "Export") }
                        } label: {
                            ControlIcon(name: "line.3.horizontal", active: false).font(.jarasSystem(size: 17, weight: .semibold))
                                .frame(width: railButton, height: 32).contentShape(Rectangle())
                        }.accessibilityLabel(Text(verbatim: "File")).accessibilityIdentifier("native-file-menu")
                            .buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarTint(active: false))
                    } else {
                        Button { projectsOpen = true } label: {
                            ControlIcon(name: "line.3.horizontal", active: projectsOpen).font(.jarasSystem(size: 17, weight: .semibold))
                                .frame(width: railButton, height: 32).contentShape(Rectangle())
                        }.accessibilityLabel("Home")
                            .buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarTint(active: projectsOpen))
                    }
                    if local {
                        Button { nativeLibraryOpen.toggle() } label: {
                            ControlIcon(name: "books.vertical", active: nativeLibraryOpen).frame(width: railButton, height: 32)
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .foregroundStyle(JarasTheme.toolbarTint(active: nativeLibraryOpen))
                            .accessibilityLabel(Text(verbatim: "Library"))
                        Button(action: toggleNativeFocus) {
                            ControlIcon(name: "sidebar.left", active: nativeFocusOpen).frame(width: railButton, height: 32)
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .foregroundStyle(JarasTheme.toolbarTint(active: nativeFocusOpen))
                            .accessibilityLabel(Text(verbatim: "Track - I"))
                    }
                    Button { withAnimation(nil) {
                        toggleMainTrackMixer()
                    } } label: {
                        ControlIcon(name: "trackMixer", active: prompterPanel == nil && !mixerCollapsed)
                            .font(.jarasSystem(size: 15, weight: .semibold))
                            .foregroundStyle(JarasTheme.toolbarTint(active: prompterPanel == nil && !mixerCollapsed))
                            .frame(width: railButton, height: 32).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                        .accessibilityLabel(prompterPanel != nil || mixerCollapsed ? "Expandir Track-Mixer" : "Recolher Track-Mixer")
                        .accessibilityValue(prompterPanel != nil || mixerCollapsed ? "Hidden" : "Shown")
                    if let toggleHozMixer {
                        Button(action: toggleHozMixer) {
                            ControlIcon(name: "hozMixer", active: hozMixerOpen)
                                .frame(width: railButton, height: 32).contentShape(Rectangle())
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .foregroundStyle(JarasTheme.toolbarTint(active: hozMixerOpen))
                            .accessibilityLabel("Hoz-Mixer")
                            .contextMenu {
                                Button(nativeHozMixerDetached ? "Indexar" : "Desindexar") {
                                    nativeHozMixerDetached.toggle()
                                    if !hozMixerOpen { toggleHozMixer() }
                                }
                            }
                    }
                    if let openMatrixPatch {
                        Button(action: openMatrixPatch) {
                            ControlIcon(name: "square.grid.3x3", active: nativeMatrixOpen)
                                .frame(width: railButton, height: 32)
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .foregroundStyle(JarasTheme.toolbarTint(active: nativeMatrixOpen))
                            .accessibilityLabel("Matrix Patch")
                    }
                    leftPartsButton(width: railButton)
                    if !local {
                        tabletPadsButton(width: railButton)
                        tabletPrompterButton(.first, width: railButton)
                        tabletPrompterButton(.second, width: railButton)
                    }
                    Button { noticesOpen = true } label: {
                        ControlIcon(name: "text.bubble", active: noticesOpen).font(.jarasSystem(size: 15, weight: .medium)).frame(width: railButton, height: 32)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarTint(active: noticesOpen)).accessibilityLabel("Notices")
                        .popover(isPresented: $noticesOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                            RemoteNativeNoticesView(close: { noticesOpen = false }, managesSubscription: false, remote: remote)
                                // An ideal size lets UIKit reduce the popover
                                // above the keyboard instead of cropping it.
                                .frame(idealWidth: 440, maxWidth: 440, idealHeight: 500, maxHeight: 500)
                                .preferredColorScheme(.dark)
                        }
                    Button { timerOpen = true } label: {
                        ControlIcon(name: "stopwatch", active: timerOpen).font(.jarasSystem(size: 16, weight: .medium)).frame(width: railButton, height: 32)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarTint(active: timerOpen)).accessibilityLabel("Timer")
                        .popover(isPresented: $timerOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                            VStack(spacing: 0) {
                                RemoteNativeTimerView(timer: timer, send: {
                                    guard state.timer != nil else { return }
                                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                                }, close: { timerOpen = false })
                                if state.timer == nil {
                                    Text("Atualize o CatLive no PC para sincronizar o cronômetro.")
                                        .font(.jarasCaption).foregroundStyle(JarasTheme.secondary).padding(12).frame(width: 300)
                                }
                            }.background(RemoteSurface.panel).preferredColorScheme(.dark)
                        }
                    if local {
                        Button {
                            nativePianoOpen.toggle()
                            if nativePianoOpen { nativeVinhetasOpen = false }
                        } label: {
                            ControlIcon(name: "pianokeys", active: nativePianoOpen)
                                .frame(width: railButton, height: 32)
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .foregroundStyle(JarasTheme.toolbarTint(active: nativePianoOpen))
                            .accessibilityLabel(Text(verbatim: "Keyboard"))
                            .accessibilityValue(nativePianoOpen ? "On" : "Off")
                        Button {
                            nativeMIDIPreviewOpen.toggle()
                            if nativeMIDIPreviewOpen { nativeVinhetasOpen = false }
                        } label: {
                            ControlIcon(name: "midiPreview", active: nativeMIDIPreviewOpen)
                                .frame(width: railButton, height: 32)
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .accessibilityLabel(Text(verbatim: "MIDI Preview"))
                            .contextMenu {
                                Button(nativeMIDIPreviewDetached ? "Indexar" : "Desindexar") {
                                    nativeMIDIPreviewDetached.toggle()
                                    nativeMIDIPreviewOpen = true
                                    nativeVinhetasOpen = false
                                }
                            }
                        tabletPadsButton(width: railButton)
                        if let openAdvanced {
                            Button(action: openAdvanced) {
                                ControlIcon(name: "info.circle", active: nativeAdvancedOpen)
                                    .font(.jarasSystem(size: 17, weight: .semibold))
                                    .frame(width: railButton, height: 32).contentShape(Rectangle())
                            }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                                .foregroundStyle(JarasTheme.toolbarTint(active: nativeAdvancedOpen))
                                .accessibilityLabel(Text(verbatim: "Advanced"))
                        }
                    }
                    if !local {
                        IpadPreviewButton(width: 54, horizontal: true, active: state.previewActive == true,
                            page: state.previewPage ?? 0,
                            toggle: { action(.togglePreview) },
                            selectPage: { action(.selectPreviewPage, value: Double($0)) })
                            .disabled(state.previewActive == nil)
                        Text(verbatim: "Mode Remote Controller Desktop")
                            .font(.jarasSystem(size: 11, weight: .semibold))
                            .foregroundStyle(JarasTheme.green)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 8)
                    }
                }
                }.frame(maxWidth: local ? 566 : .infinity).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if local {
                        HStack(spacing: 5) {
                            tabletPrompterButton(.first, width: railButton)
                            tabletPrompterButton(.second, width: railButton)
                            IpadNativePreviewButton(width: 54, horizontal: true)
                            IpadNativeVideoButton()
                            if let openRemoteSettings {
                                IpadNativeRemoteToggle(openSettings: openRemoteSettings, width: 68)
                            }
                            IpadNativeAudioStatus { openAudioSettings?() }
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    if !local { RemoteDesktopBatteryBadge(percent: state.desktopBatteryPercent, vertical: false) }
                    Button { if let openSettings { openSettings() } else { settingsOpen = true } } label: {
                        ControlIcon(name: "gearshape", active: settingsOpen || nativeSettingsOpen).font(.jarasSystem(size: 17, weight: .semibold))
                            .frame(width: railButton, height: 32).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.toolbarTint(active: settingsOpen || nativeSettingsOpen))
                        .accessibilityLabel("Configurações")
                        .popover(isPresented: $settingsOpen) { NativeRemoteSettingsView().preferredColorScheme(.dark) }
                }.environment(\.toolbarIconSurface, true)
                    .padding(.horizontal, 4).frame(height: 36).background(tabletToolbarBackground)
                VStack(spacing: 1) {
                    if local || !prompterFullscreen { transportBar }
                    HStack(alignment: .top, spacing: 0) {
                        if let localShow, libraryWidth > 0 {
                            ResizableWorkspaceLibrary(theme: JarasInterfaceTheme.current, show: localShow,
                                             width: libraryWidth, maximumWidth: libraryMaximum, preferredWidth: Binding(get: { liveLibraryWidth ?? nativeLibraryWidth }, set: { liveLibraryWidth = $0 }),
                                             finishOuterResize: {
                                                 if let liveLibraryWidth { nativeLibraryWidth = liveLibraryWidth }
                                                 liveLibraryWidth = nil
                                             })
                                .frame(width: libraryWidth)
                        }
                        if let localShow, focusWidth > 0 {
                            FooterHorizontalMixer(show: localShow, focused: true)
                                .environment(\.trackMixFeedback, trackMixFeedback)
                                .environment(\.openFX, openNativeFX)
                                .frame(width: focusWidth)
                        }
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                if let panel = prompterPanel {
                                    let space = max(1, contentWidth - 10)
                                    RemoteNativeTeleprompterPanel(index: panel.rawValue, timer: timer,
                                        fullscreen: prompterFullscreen, toggleFullscreen: togglePrompterFullscreen,
                                        toggleSetlist: togglePrompterSetlist, setlistVisible: prompterSetlistFraction > 0, managesSubscription: false, remote: remote)
                                        .frame(width: prompterFullscreen ? contentWidth : max(0, space * (1 - prompterSetlistFraction) - parts.total)).clipped()
                                        .allowsHitTesting(prompterFullscreen || prompterSetlistFraction < 1)
                                        .accessibilityHidden(!prompterFullscreen && prompterSetlistFraction == 1)
                                resizeHandle(label: "Ajustar largura do Setlist", changed: { translation in
                                    let start = prompterResizeStart ?? prompterSetlistFraction
                                    if prompterResizeStart == nil { prompterResizeStart = start }
                                    let width = min(1, max(0, start - translation / space))
                                    if prompterSetlistFraction != width { livePrompterSetlistFraction = width }
                                }, ended: finishPrompterResize)
                                    .frame(width: prompterFullscreen ? 0 : 10).clipped()
                                    .allowsHitTesting(!prompterFullscreen).accessibilityHidden(prompterFullscreen)
                            } else {
                                if leftParts.total > 0 {
                                    remoteSections(placement: .left).frame(width: leftParts.content).clipped()
                                    resizeHandle(label: "Resize Parts", changed: { translation in
                                        if nativeLeftPartsDragStart == nil {
                                            nativeLeftPartsDragStart = leftParts.content
                                            liveNativeLeftPartsWidth = leftParts.content
                                            if rightPartsVisible { livePartsWidth = parts.content }
                                        }
                                        let start = nativeLeftPartsDragStart ?? leftParts.content
                                        liveNativeLeftPartsWidth = min(max(0, freeSpace - leftParts.handle), max(min(80, start), start + translation))
                                    }, ended: {
                                        finishNativePartsResize(available: freeSpace, leftVisible: true, rightVisible: rightPartsVisible)
                                    }).frame(width: leftParts.handle).clipped()
                                }
                                trackMixer.frame(width: trackWidth).clipped()
                                    .allowsHitTesting(!mixerCollapsed).accessibilityHidden(mixerCollapsed)
                                resizeHandle(label: "Ajustar largura do Track-Mixer", showsRail: !local, changed: { translation in
                                    let start = trackResizeStart ?? panelWidths
                                    if trackResizeStart == nil { trackResizeStart = start }
                                    let widths: DAWRemotePanelWidths
                                    if local {
                                        let width = min(panelSpace, max(minimumTrack, start.track * referenceSpace + translation))
                                        widths = .init(track: width / referenceSpace, setlist: start.setlist)
                                    } else { widths = start.resizingTrack(by: translation / panelSpace) }
                                    if panelWidths != widths { livePanelWidths = widths }
                                }, ended: finishPanelResize)
                                RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition, local: local, localShow: localShow, timelineFocus: timelineFocus, editorEnabled: nativeInputEnabled,
                                    touchItemEditing: editingTracks, showRegionLanes: showNativeRegionLanes, showTempoLane: showNativeTempoLane, regionDrag: $regionMovePreview, openRegionActions: openRegionActions, openItemMenu: openItemMenu, openSelectedItemMenu: openSelectedItemMenu, openItemFX: openItemFX, openMarkerEditor: { nativeMarker = $0 }, regionCommand: { id, command in
                                    if command == "bpm" { detectRegionBPM?(id) }
                                    else if command == "loops" { openRegionLoops?(id) }
                                    else if command == "unify" { unifyName = ""; unifyingRegion = id }
                                    else if command == "init" { configInitRegion = id }
                                    else if command == "multitrack" { multitrackAction?(id, localShow?.selectedTimelineRegions ?? []) }
                                },
                                    control: { action($0, target: $1, value: $2) },
                                    preview: { scrubPosition = $0 }, seek: { position in
                                        scrubPosition = nil
                                        if local {
                                            localShow?.send(.editSeek, value: position)
                                            return
                                        }
                                        guard !state.playing, let region = selectedTimelineRegion else { return }
                                        pendingSeek = position; seekSentAt = Date()
                                        action(.seek, target: region.id, value: position)
                                    }, rulerSeek: local ? { position in
                                        scrubPosition = nil
                                        if TimelineEditPreferences.enabled(TimelineEditPreferences.native) { localShow?.send(.queueBeatSeek, value: position) }
                                        else { action(.seek, value: position) }
                                    } : nil).frame(width: max(0, gridWidth - parts.total - leftParts.total)).clipped()
                                        .allowsHitTesting(gridWidth > 0).accessibilityHidden(gridWidth == 0)
                                        .environment(\.timelineSetlistResize, local ? TimelineSetlistResize(change: { translation in
                                        let start = setlistResizeStart ?? .init(track: panelWidths.track, setlist: normalSetlist / referenceSpace)
                                        if setlistResizeStart == nil { setlistResizeStart = start }
                                        let width = min(max(0, panelSpace - trackWidth - TimelineVerticalBar.width), max(0, start.setlist * referenceSpace - translation))
                                        let widths = DAWRemotePanelWidths(track: start.track, setlist: width / referenceSpace)
                                        if panelWidths != widths { livePanelWidths = widths }
                                    }, finish: finishPanelResize) : nil)
                                if !local {
                                    resizeHandle(label: "Ajustar largura do Setlist", changed: { translation in
                                        let start = setlistResizeStart ?? panelWidths
                                        if setlistResizeStart == nil { setlistResizeStart = start }
                                        let widths = start.resizingSetlist(by: translation / panelSpace)
                                        if panelWidths != widths { livePanelWidths = widths }
                                    }, ended: finishPanelResize)
                                }
                                }
                            }
                            if dockHeight > 0, let localShow {
                                Capsule().fill(JarasTheme.secondary)
                                    .frame(width: 48, height: 3)
                                    .frame(maxWidth: .infinity).frame(height: 18)
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                        .updating($mixerHeightTranslation) { drag, offset, _ in offset = drag.translation.height }
                                        .onEnded { drag in
                                            let height = min(maximumDockHeight, max(minimumDockHeight, initialDockHeight - drag.translation.height))
                                            if height != initialDockHeight { nativeMixerHeight = height }
                                        })
                                    .accessibilityLabel("Ajustar altura do Hoz Mixer")
                                    .accessibilityAdjustableAction { direction in
                                        let step: CGFloat = direction == .increment ? 24 : -24
                                        let height = min(maximumDockHeight, max(minimumDockHeight, initialDockHeight + step))
                                        if height != initialDockHeight { nativeMixerHeight = height }
                                    }
                                FooterHorizontalMixer(show: localShow)
                                    .environment(\.trackMixFeedback, trackMixFeedback)
                                    .environment(\.openFX, openNativeFX)
                                    .frame(height: max(0, dockHeight - 18))
                            }
                            if previewHeight > 0, let localShow {
                                VStack(spacing: 0) {
                                    let gripHeight = min(14, previewHeight)
                                    Color.clear.frame(height: gripHeight)
                                        .overlay { Capsule().fill(JarasTheme.secondary).frame(width: 48, height: 3) }
                                        .contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                            .updating($nativeMIDIPreviewResize) { drag, value, _ in value = drag.translation.height }
                                            .onEnded { drag in
                                                nativeMIDIPreviewHeight = min(previewMaximum, max(previewMinimum, previewInitial - drag.translation.height))
                                            })
                                        .accessibilityLabel("Resize MIDI Preview")
                                        .accessibilityAdjustableAction { direction in
                                            nativeMIDIPreviewHeight = min(previewMaximum, max(previewMinimum, previewInitial + (direction == .increment ? 24 : -24)))
                                        }
                                    RecordingPianoPreview(show: localShow)
                                        .frame(height: previewHeight - gripHeight)
                                        .clipped()
                                }.frame(height: previewHeight, alignment: .top).clipped()
                            }
                        }.frame(width: max(0, contentWidth - libraryWidth - focusWidth - baseSetlist - parts.total - proWidth)).clipped()
                        let setlistWidth = prompterFullscreen ? 0 : prompterPanel == nil ? normalSetlist : max(1, contentWidth - 10) * prompterSetlistFraction
                        // Clipping only hides drawing; constrain touches too so a narrow
                        // setlist cannot cover the teleprompter's toggle or the divider.
                        setlist.frame(width: setlistWidth).contentShape(Rectangle()).clipped()
                            .opacity(setlistWidth > 0 ? 1 : 0)
                            .animation(nil, value: setlistWidth == 0)
                            .allowsHitTesting(setlistWidth > 0).accessibilityHidden(setlistWidth == 0)
                        if parts.total > 0 {
                            resizeHandle(label: "Resize sections", changed: { translation in
                                if partsDragStart == nil {
                                    partsDragStart = parts.content
                                    if leftParts.total > 0 {
                                        liveNativeLeftPartsWidth = leftParts.content
                                        livePartsWidth = parts.content
                                    }
                                }
                                let start = partsDragStart ?? parts.content
                                livePartsWidth = min(max(0, freeSpace - parts.handle), max(local ? min(80, start) : 80, start - translation))
                            }, ended: {
                                finishNativePartsResize(available: freeSpace, leftVisible: leftParts.total > 0, rightVisible: true)
                            })
                            remoteSections().frame(width: parts.content).clipped()
                        }
                        if proWidth > 0, let nativeProDock, let localShow {
                            Group {
                                if nativeProDock { WorkspaceNotesDock(theme: nativeInterfaceTheme) }
                                else { WorkspaceLibrary(theme: nativeInterfaceTheme, show: localShow, samplersOnly: true) }
                            }.frame(width: proWidth).clipped()
                        }
                    }.overlay {
                        if local {
                            IpadNativeVideoPanel(
                                leading: prompterPanel == nil ? trackWidth + leftParts.total : 0,
                                trailing: baseSetlist + parts.total + proWidth
                            ).padding(.bottom, dockHeight)
                        }
                    }
                    if horizontalPartsOpen && !remotePortrait && !prompterFullscreen && prompterPanel == nil {
                        horizontalPartsDock(defaultHeight: min(192, geometry.size.height * 0.42))
                    }
                    if !local, remoteVinhetasOpen, !remoteVinhetasDetached, !prompterFullscreen {
                        remoteVinhetasScreen.frame(height: min(260, geometry.size.height * 0.42))
                    }
                    if local, nativeVinhetasOpen, !nativeVinhetasDetached, !prompterFullscreen, let localShow {
                        IpadVinhetasPanel(touchMenusEnabled: editingTracks, createTrack: { _ = localShow.createVinhetasTrack() })
                            .frame(height: padsHeight)
                    }
                    if local && nativePianoOpen && !prompterFullscreen {
                        FooterPianoKeyboard().frame(height: 108)
                    }
                    if !keyboardVisible && !prompterFullscreen { footer }


                }.frame(width: contentWidth).disabled(state.projects?.busy == true)
            }
        }.background(JarasTheme.line)
            .overlay(alignment: .top) {
                if local && nativeProMode && nativeClockPositionOpen, let localShow {
                    NativeClockPosition(show: localShow) { nativeClockPositionOpen = false }
                }
            }
            .overlay(alignment: .topLeading) {
                if !local, remoteVinhetasOpen, remoteVinhetasDetached {
                    IpadVinhetasFloatingPanel(touchMenusEnabled: false, createTrack: {},
                        remoteContent: AnyView(remoteVinhetasScreen), dock: { remoteVinhetasDetached = false },
                        close: { remoteVinhetasOpen = false })
                }
                if local, nativeMIDIPreviewOpen, nativeMIDIPreviewDetached, !prompterFullscreen, let localShow {
                    IpadWorkspaceFloatingPanel(title: "MIDI Preview", dock: { nativeMIDIPreviewDetached = false },
                                              close: { nativeMIDIPreviewOpen = false }) {
                        RecordingPianoPreview(show: localShow)
                    }
                }
                if local, hozMixerOpen, nativeHozMixerDetached, !prompterFullscreen, let localShow, let toggleHozMixer {
                    IpadWorkspaceFloatingPanel(title: "Hoz Mixer", dock: { nativeHozMixerDetached = false },
                                              close: toggleHozMixer) {
                        FooterHorizontalMixer(show: localShow)
                            .environment(\.trackMixFeedback, trackMixFeedback)
                            .environment(\.openFX, openNativeFX)
                    }
                }
                if local, nativeVinhetasOpen, nativeVinhetasDetached, let localShow {
                    IpadVinhetasFloatingPanel(touchMenusEnabled: editingTracks, createTrack: { _ = localShow.createVinhetasTrack() },
                        dock: { nativeVinhetasDetached = false }, close: { nativeVinhetasOpen = false })
                }
            }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) },
                    openInNewTab: { action(.openRecentProjectInNewTab, target: $0) },
                    close: { projectsOpen = false }, exit: { projectsOpen = false; exitRemote() })
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
            #endif
            .onAppear(perform: updatePanelSubscription)
            .onDisappear { if state.timer != nil { action(.remotePanel, value: 0) } }
            .onChange(of: prompterPanel) { _ in updatePanelSubscription() }
            .onChange(of: noticesOpen) { _ in updatePanelSubscription() }
            .onChange(of: state.project) { _ in expandedRegions.removeAll(); playlistPickerOpen = false; updatePanelSubscription() }
            .onChange(of: state.song) { _ in expandedRegions.removeAll(); scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.playing) { _ in scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.focusedRegion) { _ in scrubPosition = nil; pendingSeek = nil }
            .onChange(of: state.position) { position in
                if let pendingSeek, abs(position - pendingSeek) <= 0.1 { self.pendingSeek = nil }
            }
    }
    private var setlistControls: some View {
        SetlistFooterControls(projectID: state.project, bypassed: state.multiLoopsBypassed == true,
            liveEnabled: state.setlistLiveEnabled == true,
            partsOpen: UIDevice.current.userInterfaceIdiom == .phone ? phonePanel == .sections : sectionsOpen && sectionsInList,
            toggleBypass: { action(.toggleMultiLoopBypass) },
            toggleLive: { if state.setlistLiveEnabled != nil { action(.toggleSetlistLive) } },
            toggleParts: {
                searchFocused = false
                if phoneLayout {
                    choosePhonePanel(phonePanel.togglingFooterParts())
                } else {
                    let wasOpen = sectionsOpen && sectionsInList
                    horizontalPartsOpen = false
                    sectionsInList = true
                    sectionsOpen = !wasOpen
                }
            })
    }
    private func horizontalPartsDock(defaultHeight: CGFloat) -> some View {
        HorizontalPartsDock(heightScale: $horizontalPartsHeightScale, defaultHeight: defaultHeight) {
            remoteSections(placement: .left, horizontal: true)
        }
    }
    private func remoteSections(placement: SMK37Navigation.Panel = .setlist, horizontal: Bool = false) -> some View {
        let playback = state.sectionPlayback
        let current = state.timelineRegions.first { $0.id == playback?.currentRegion }
        let queued = state.timelineRegions.first { $0.id == playback?.secondaryRegion }
        return VStack(spacing: 4) {
            cancelSectionButton.padding([.top, .leading, .trailing], 4)
            if horizontal {
                HStack(spacing: 5) {
                    remoteSectionBank(secondary: false, placement: placement, horizontal: true)
                    Rectangle().fill(JarasTheme.line).frame(width: 1)
                    remoteSectionBank(secondary: true, placement: placement, horizontal: true)
                }.padding(.horizontal, 5)
            } else {
                SectionListTabs(current: current?.name, queued: queued?.name, subPlaying: state.subPlaying,
                    playing: state.playing, selectionRequests: (localShow?.partsTabSelection ?? partsTabSelection)
                        .compactMap { $0 }.filter { $0.panel == nil || $0.panel == placement }.eraseToAnyPublisher()) { secondary in
                    remoteSectionBank(secondary: secondary, placement: placement)
                }
            }
        }.background(RemoteSurface.panel)
    }
    private func remoteSectionBank(secondary: Bool, placement: SMK37Navigation.Panel, horizontal: Bool = false) -> some View {
        let playback = state.sectionPlayback
        let id = secondary ? playback?.secondaryRegion : playback?.currentRegion
        let region = state.timelineRegions.first { $0.id == id }
        let markers: [TimelineMarker] = (state.markers ?? []).filter { marker in
            marker.section == true && region.map { marker.position >= $0.start && marker.position <= $0.end } == true
        }.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
            .map { TimelineMarker(id: $0.id, name: $0.name.uppercased(), position: $0.position, color: $0.color,
                                  section: true, loopSection: $0.loopSection) }
        let end = secondary ? region?.end ?? 0 : playback?.currentEnd ?? region?.end ?? 0
        return SmoothSeekBankView(title: secondary ? "Queued" : (state.playing ? "Now playing" : "Selected song"),
            name: region?.name ?? "—", markers: markers, end: end,
            position: secondary ? playback?.secondaryPosition ?? 0 : playback?.position ?? state.position,
            showsPosition: !secondary || state.subPlaying, positionRunning: secondary ? state.subPlaying : state.playing, queued: playback?.queuedMarker,
            trigger: playback?.nextTrigger, queueStartedAt: playback?.queueStartedAt, playbackPosition: state.position, playbackRunning: state.playing,
            select: { id in
                smkNavigation.selectPart(id, panel: placement, queued: secondary)
                localShow?.smkNavigation = smkNavigation
                action(.queueSection, target: id)
            }, verticalList: true,
            regionID: region?.id, regionStart: region?.start ?? 0,
            navigationSelection: {
                if case let .parts(panel, queued, id) = smkNavigation.focus, panel == placement, queued == secondary { return id }
                return nil
            }(),
            editAutomatic: local ? { automaticSectionSource = $0 } : nil, horizontal: horizontal)
    }
    private var footer: some View {
        let displays = state.songDisplays
        let total = displays?.playlistSeconds ?? state.regions.filter { $0.parentRegion == nil }.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let seconds = Int(min(Double(Int.max / 2), max(0, total)))
        return HStack(spacing: 10) {
            if sidebarHidden { restoreSidebarButton() }
            ResourceUsageView(memoryScope: .application, showsTotalMemory: local)
                .font(.jarasSystem(size: 9, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
            FooterSongDisplays(next: displays?.next, nextBPM: displays?.nextBPM,
                queued: displays?.queued, queuedBPM: displays?.queuedBPM, subPlaying: state.subPlaying,
                duration: String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60),
                noticeShow: local && nativeProMode ? localShow : nil)
        }.padding(.horizontal, 8).padding(.vertical, 3).frame(height: 31).background(RemoteSurface.panel)
    }
    private func resizeHandle(label: String, showsRail: Bool = true, changed: @escaping (Double) -> Void, ended: @escaping () -> Void) -> some View {
        ZStack {
            if showsRail {
                JarasTheme.panel
                RoundedRectangle(cornerRadius: 2).fill(JarasTheme.secondary).frame(width: 3, height: 36)
            } else {
                Color.clear
            }
        }.frame(width: 10).contentShape(Rectangle())
            // The divider moves as the panel grows. Local coordinates would
            // change the translation again during layout, feeding the width
            // update back into the gesture even with a stationary finger.
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { changed(Double($0.translation.width)) }.onEnded { _ in ended() })
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                changed(direction == .increment ? 36 : -36); ended()
            }
    }
    @ViewBuilder private var tabletToolbarBackground: some View {
        if local { nativeInterfaceTheme.titlebar }
        else { RemoteSurface.panel }
    }

    private var masterStrip: some View {
        VStack(spacing: 1) {
            HStack(spacing: local ? 3 : 4) {
                Button { confirmingMainMono = true } label: {
                    ZStack {
                        Text("Stereo").lineLimit(1).opacity(state.masterMono ? 0 : 1)
                        if state.masterMono {
                            Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: -3.5)
                            Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: 3.5)
                        }
                    }.font(.jarasSystem(size: 10, weight: .semibold)).frame(width: local ? 48 : 58, height: 28)
                        .foregroundStyle(state.masterMono ? JarasTheme.green : JarasTheme.text)
                        .modifier(RemoteControlSurface(radius: 3))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Main Stereo/Mono")
                    .accessibilityValue(state.masterMono ? "Mono" : "Stereo")
                    .mainMonoConfirmation(isPresented: $confirmingMainMono, mono: state.masterMono) {
                        guard remote.remoteState?.project == state.project,
                              remote.remoteState?.masterMono == state.masterMono else { return }
                        action(.masterMono)
                    }
                    .onChange(of: state.project) { _ in confirmingMainMono = false }
                if local, let openPatch {
                    Button("Patch") { openPatch(nil) }
                        .buttonStyle(RemoteNativeTrackButtonStyle(width: 37, touchPadding: 0, height: 28, usesTrackFace: true))
                        .accessibilityLabel("Main Patch")
                } else if !local {
                    Button("Patch") { showRemotePatch(nil) }
                        .buttonStyle(RemoteNativeTrackButtonStyle(width: 44, touchPadding: 0, height: 28))
                        .accessibilityLabel("Main Patch")
                }
                if local {
                    Button("FX") { openNativeFX(nil, "Chain") }.buttonStyle(RemoteNativeTrackButtonStyle(width: 28, touchPadding: 0, height: 28))
                }
                Group {
                    IpadMixerKnob(value: state.masterPan ?? 0, pan: true, usesMixerPanFace: local) { action(.pan, value: $0) }
                        .frame(width: 28, height: 28).accessibilityLabel("Main pan")
                        .disabled(!local && state.masterPan == nil)
                }
                Button { action(.mute) } label: { Text(verbatim: "M") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterMute ? .red : nil, width: 28, touchPadding: 0, height: 28))
                Button { action(.solo) } label: { Text(verbatim: "S") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterSolo ? JarasTheme.yellow : nil, width: 28, touchPadding: 0, height: 28))
            }.frame(maxWidth: .infinity, alignment: local ? .leading : .trailing).frame(height: 28)
            HStack {
                Text(verbatim: "Main").font(.jarasSystem(size: 11, weight: .semibold))
                    .foregroundStyle(MixerTrackStyle.surfaceText).frame(maxWidth: .infinity)
                RemotePeakReadout(decibels: state.masterPeakDB, name: "Main", project: state.project, song: state.song, target: nil, nameColor: MixerTrackStyle.surfaceTextHex, reset: { action(.resetMeterPeak) }).equatable()
            }.frame(height: 14)
            HStack(spacing: 3) {
                if !local {
                    Text(remoteDecibelText(state.masterVolume)).font(.jarasSystem(size: 10, weight: .semibold, design: .monospaced)).frame(width: 36, alignment: .leading)
                }
                RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(state.masterVolume), range: -60...12, height: 20,
                    locksScrolling: local, meter: local ? StemAudioPlayback.shared.masterMeter : nil, mixerFader: true,
                    selectionScope: state.song, showsValueTooltip: local,
                    preview: localShow.map { show in
                        { show.sendMixerControl(.volume, target: nil, value: DAWRemoteFaderScale.gain($0), preview: true) }
                    }) { position in
                        let gain = DAWRemoteFaderScale.gain(position)
                        if let localShow { localShow.sendMixerControl(.volume, target: nil, value: gain) }
                        else { action(.volume, value: gain) }
                    }
                    .accessibilityLabel("Main volume")
            }
        }.padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity).frame(height: 70, alignment: .top)
            .background {
                if local {
                    MixerTrackSurface()
                } else {
                    let theme: JarasInterfaceTheme = state.masterColor == MixerTrackStyle.darkSurfaceHex ? .dark : .lightDark
                    Color(hex: MixerTrackStyle.surfaceHex(for: theme))
                }
            }.cornerRadius(6)
            .modifier(MasterMuteIndicator(muted: state.masterMute))
            .contextMenu {
                if local, let openPatch { Button("Patch") { openPatch(nil) } }
            }
    }
    private func transportReadouts(informationFraction: CGFloat) -> some View {
        HStack(spacing: local ? 4 : 6) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - 1)
                HStack(spacing: 0) {
                    Group {
                        if UIDevice.current.userInterfaceIdiom == .pad && !local {
                            Text(verbatim: state.currentSongName)
                                .foregroundStyle(state.playing ? JarasTheme.green : JarasTheme.text)
                                .lineLimit(1).truncationMode(.tail).padding(.horizontal, 8)
                        } else {
                            SongNameDisplay(title: state.playing ? "Now playing" : "Selected song",
                                name: state.currentSongName, bpm: state.songDisplays?.currentBPM,
                                color: state.playing ? JarasTheme.green : JarasTheme.text)
                        }
                    }.frame(width: width * (1 - informationFraction)).accessibilityLabel("Current song")
                    Rectangle().fill(JarasTheme.line).frame(width: 1)
                    TransportInformationMessage(message: footerInformationText,
                        beatPhase: transientFooterNotice.isEmpty && state.loop ? state.footerLoopBeatPhase : nil,
                        steady: !transientFooterNotice.isEmpty || !state.loop)
                        .font(.jarasSystem(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: width * informationFraction, height: 25).clipped()
                        .accessibilityLabel("Information")
                }
            }.frame(height: 25).background(RemoteSurface.display).cornerRadius(5)
        }.font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
    }

    private var transportSaveButton: some View {
        Button { action(.save) } label: {
            Label {
                Text(verbatim: "Save")
            } icon: {
                ControlIcon(name: state.pendingSave ? "save" : "check", active: state.pendingSave, size: 17)
            }
                .labelStyle(.iconOnly)
                .frame(width: 34, height: local && nativeProMode ? TransportControlMetrics.proHeight : 28)
                .foregroundStyle(state.pendingSave ? Color.black : JarasTheme.secondary)
                .modifier(RemoteControlSurface(color: state.pendingSave ? JarasTheme.green : nil))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.pendingSave ? JarasTheme.green : JarasTheme.line))
        }.disabled(state.saving || (!local && !state.pendingSave))
            .accessibilityValue(state.saving ? Text("Salvando…") : Text(""))
            .modifier(NativeProjectShareHold(share: shareProject))
    }

    private var transportSetlistButton: some View {
        Button {
            if prompterPanel == nil { toggleMainSetlist() } else { togglePrompterSetlist() }
        } label: {
            TransportControlIcon(name: "setlist", size: 17)
        }
        .accessibilityLabel("Setlist")
        .buttonStyle(TransportButtonStyle(color: mainSetlistVisible ? JarasTheme.green : Color(hex: 0xc44545),
            active: true, fontSize: 11, width: 34, height: local && nativeProMode ? TransportControlMetrics.proHeight : 28))
        .accessibilityValue(mainSetlistVisible ? "Shown" : "Hidden")
    }

    private var transportActions: some View {
        HStack(spacing: 4) {
            if local {
                Button {
                    nativeProMode.toggle()
                    if !nativeProMode {
                        nativeProDock = nil; nativeClockPositionOpen = false
                    }
                } label: { Text(verbatim: nativeProMode ? "Simple Mode" : "Pro Mode") }
                .buttonStyle(TransportButtonStyle(color: nativeProMode ? JarasTheme.green : Color(hex: 0x454545),
                    active: nativeProMode, inactiveOpacity: 1, width: 68,
                    height: nativeProMode ? TransportControlMetrics.proHeight : 28, bordered: false))
            }
            transportSaveButton
            transportSetlistButton
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var transportBar: some View {
        HStack(alignment: .top, spacing: local ? 5 : 8) {
            if !local { masterStrip.frame(width: 220) }
            Group {
                if local && nativeProMode, let localShow { nativeProTransport(show: localShow) }
                else { VStack(spacing: 0) {
                Group {
                    if local { nativeTransportReadout }
                    else { tabletRemoteTransportReadout }
                }.frame(height: 30)
                transportProgress.padding(.vertical, 1)
                HStack(spacing: 6) {
                    GeometryReader { geometry in
                        if local { nativeTransportControls(width: geometry.size.width) }
                        else { remoteTransportControls(width: geometry.size.width) }
                    }
                    transportActions
                }.frame(height: 32)
                } }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: local && !nativeProMode ? JarasTheme.desktopTransportGradient : JarasTheme.workspaceTransportGradient,
                        startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7).strokeBorder(JarasInterfaceTheme.lightDark.transportBorder)
                    .allowsHitTesting(false)
            }
        }.padding(6).frame(height: local && nativeProMode ? 114 : 82, alignment: .top).background(RemoteSurface.panel)
    }
    private func nativeProTransport(show: ShowController) -> some View {
        let playback = ProTransportButtons(show: show, configureFadeout: { fadeoutSettingsOpen = true })
        let editing = TransportEditingButtons(show: show, key: TimelineEditPreferences.native)
        let controls = IpadTransportControl.visible(hidden: hiddenTransport)
        let details = nativeTempoControls(controls, bpmWidth: 88, tunerWidth: 96)
        let tools = HStack(spacing: 4) {
            ProGridToolPicker(selection: $nativeProTool)
            nativeProButton("Clock", icon: "timer", active: nativeClockPositionOpen) { nativeClockPositionOpen.toggle() }
            nativeProButton("Notes", icon: "note.text", active: nativeProDock == true) {
                nativeProDock = nativeProDock == true ? nil : true
            }
            nativeProButton("Samplers", icon: "library.samplers", active: nativeProDock == false) {
                nativeProDock = nativeProDock == false ? nil : false
            }
        }.fixedSize()
        let selected = state.focusedRegion.map(show.playlistRegionSourceID)
        let name = state.nativeTransportSongName(selectedRegionID: selected)
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                ProTimelinePosition(show: show)
                Spacer(minLength: 0)
                editing
            }.frame(height: TransportControlMetrics.proHeight)
            .overlay {
                Text(verbatim: name)
                    .font(.jarasSystem(size: 15, weight: .semibold))
                    .foregroundStyle(state.playing ? JarasTheme.green : JarasTheme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 252)
                    .accessibilityLabel("Current song").accessibilityValue(name)
                    .allowsHitTesting(false)
            }
            details.frame(maxWidth: .infinity, maxHeight: 32)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    playback
                    Spacer(minLength: 4)
                    tools
                    transportActions
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { playback; tools; transportActions }
                }
            }.frame(height: TransportControlMetrics.proHeight)
        }.frame(height: 96)
    }
    private func nativeProButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { TransportControlIcon(name: icon, size: 15) }
            .buttonStyle(TransportButtonStyle(color: active ? JarasTheme.green : Color(hex: 0x454545), active: active,
                inactiveOpacity: 1, width: 28, height: TransportControlMetrics.proHeight, bordered: false))
            .accessibilityLabel(title)
    }
    private var tabletRemoteTransportReadout: some View {
        GeometryReader { geometry in
            let side = min(175, geometry.size.width * 0.27)
            Text(verbatim: state.currentSongName)
                .font(.jarasSystem(size: 14, weight: .semibold))
                .foregroundStyle(state.playing ? JarasTheme.green : JarasTheme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, side)
                .accessibilityLabel("Current song")
                .overlay(alignment: .leading) {
                    phoneInformationDisplay.frame(width: side)
                }
        }.frame(height: 24)
    }
    private var nativeTransportReadout: some View {
        GeometryReader { geometry in
            let side = min(200, geometry.size.width * 0.43)
            ZStack(alignment: .leading) {
                let selected = state.focusedRegion.map { localShow?.playlistRegionSourceID($0) ?? $0 }
                Text(verbatim: state.nativeTransportSongName(selectedRegionID: selected))
                    .foregroundStyle(JarasTheme.text).lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity).padding(.horizontal, side)
                    .accessibilityLabel("Current song")
                HStack(spacing: 6) {
                    if let localShow { TimelineNavigationControls(show: localShow, width: 27) }
                    Text(verbatim: timeText).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(JarasTheme.licenseTitleGreen)
                        .accessibilityLabel("Tempo da agulha")
                }.frame(width: side, alignment: .leading)
            }.frame(height: 24)
                .overlay(alignment: .trailing) {
                    if !footerInformationText.isEmpty {
                        Text(verbatim: footerInformationText).font(.jarasSystem(size: 11, weight: .bold))
                            .foregroundStyle(JarasTheme.yellow).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(width: side, alignment: .trailing).accessibilityLabel("Information")
                    }
                }
        }.font(.jarasSystem(size: 15, weight: .semibold)).frame(height: 24)
    }
    private func remoteTransportControls(width: CGFloat) -> some View {
        let buttonWidth = max(30, (width - 288) / 4)
        let controls = HStack(spacing: 4) {
            Button { action(state.playing || state.paused ? .stop : .play) } label: {
                Label { Text(verbatim: state.playing || state.paused ? "Stop" : "Play") }
                    icon: { TransportControlIcon(name: state.playing || state.paused ? "stopall" : "play", size: 14) }
            }.buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: state.playing, fontSize: 12, width: buttonWidth, height: 28))
            fadeoutButton(width: buttonWidth, height: 28)
            Button { action(state.paused ? .play : .pause) } label: {
                TransportControlIcon(name: state.paused ? "play" : "pause", size: 14)
            }.buttonStyle(TransportButtonStyle(color: JarasTheme.pauseBackground(state.paused), active: state.paused, inactiveOpacity: 1,
                fontSize: 12, width: buttonWidth, height: 28)).disabled(!state.playing && !state.paused)
                .accessibilityLabel(state.paused ? "Play" : "Pause")
            Button { action(.toggleLoop) } label: { TransportControlIcon(name: "loop", size: 14).accessibilityLabel("Repeat") }
                .buttonStyle(TransportButtonStyle(color: state.loop ? JarasTheme.yellow : Color(hex: 0x454545), active: state.loop, inactiveOpacity: 1, fontSize: 12, width: buttonWidth, height: 28))
            bpmControl
            tunerControl
        }.fixedSize(horizontal: true, vertical: false)
        return ViewThatFits(in: .horizontal) {
            controls
            ScrollView(.horizontal, showsIndicators: false) { controls }
        }.frame(width: width, height: 32, alignment: .leading)
    }
    private func nativeTransportControls(width: CGFloat) -> some View {
        let visible = IpadTransportControl.visible(hidden: hiddenTransport)
        let playback = visible.filter { [.play, .fadeout, .pause, .repeatPlayback, .record].contains($0) }
        let hasFadeout = playback.contains(.fadeout)
        let hasBPM = visible.contains(.bpm)
        let hasMetronome = visible.contains(.metronome)
        let hasTuner = visible.contains(.tuner)
        let showsTempo = hasBPM || hasMetronome
        let buttonCount = CGFloat(playback.count - (hasFadeout ? 1 : 0))
        let playbackSpacing = CGFloat(playback.count) * 4 + 3
        let fixedWidth = playbackSpacing + TransportEditingButtons.span + (hasFadeout ? 50 : 0)
        let detailSpacing: CGFloat = (showsTempo || hasTuner ? 8 : 0) + (showsTempo && hasTuner ? 8 : 0)
        let tempoInsets: CGFloat = (showsTempo ? 12 : 0) + (hasMetronome ? 68 : 0)
            + (hasMetronome && hasBPM ? 10 : 0) + (hasBPM ? 56 : 0)
        let minBPM: CGFloat = hasBPM ? 88 : 0
        let minTuner: CGFloat = hasTuner ? 96 : 0
        let buttonWidth = min(48, max(28, (width - fixedWidth - detailSpacing - tempoInsets - minBPM - minTuner) / max(1, buttonCount)))
        let extra = max(0, width - fixedWidth - buttonCount * buttonWidth - detailSpacing - tempoInsets - minBPM - minTuner)
        let tunerExtra = hasTuner ? extra * (hasBPM ? 0.4 : 1) : 0
        let bpmWidth = minBPM + (hasBPM ? min(12, extra - tunerExtra) : 0)
        let tunerWidth = minTuner + min(12, tunerExtra)
        let controls = HStack(spacing: 8) {
            nativePlaybackButtons(playback, width: buttonWidth)
            if showsTempo || hasTuner {
                nativeTempoControls(visible, bpmWidth: bpmWidth, tunerWidth: tunerWidth)
            }
        }.fixedSize(horizontal: true, vertical: false)
        return ViewThatFits(in: .horizontal) {
            controls
            ScrollView(.horizontal, showsIndicators: false) { controls }
        }.frame(width: width, height: 32, alignment: .leading)
    }
    private func nativePlaybackButtons(_ controls: [IpadTransportControl], width: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(controls) { control in
                switch control {
                case .play:
                    let running = state.playing
                    Button { action(running ? .stop : .play) } label: {
                        Label {
                            if width >= 44 { Text(verbatim: running ? "Stop" : "Play") }
                        } icon: { TransportControlIcon(name: running ? "stopall" : "play", size: 14) }
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.transportPlay, active: running, fontSize: 10, width: width, height: 28))
                        .accessibilityLabel(Text(verbatim: running ? "Stop" : "Play"))
                case .fadeout:
                    fadeoutButton(width: 50, height: 28)
                case .pause:
                    Button { action(.pause) } label: { TransportControlIcon(name: "pause", size: 14) }
                        .buttonStyle(TransportButtonStyle(color: JarasTheme.pauseBackground(state.paused),
                            active: state.paused, inactiveOpacity: 1, fontSize: 11, width: width, height: 28))
                        .disabled(!state.playing).accessibilityLabel("Pause")
                case .repeatPlayback:
                    Button { action(.toggleLoop) } label: { TransportControlIcon(name: "loop", size: 14) }
                        .buttonStyle(TransportButtonStyle(color: state.loop ? JarasTheme.yellow : Color(hex: 0x454545), active: state.loop, inactiveOpacity: 1,
                            activeForeground: .black, inactiveForeground: .white, fontSize: 12, width: width, height: 28))
                        .accessibilityLabel("Repeat")
                case .record:
                    if let localShow { IpadAudioTransportButtons(show: localShow, only: control, controlWidth: width) }
                default:
                    EmptyView()
                }
            }
            if let localShow {
                TransportEditingButtons(show: localShow, key: TimelineEditPreferences.native)
                    .padding(.leading, 3)
            }
        }.fixedSize()
    }
    private func nativeTempoControls(_ visible: [IpadTransportControl], bpmWidth: CGFloat, tunerWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            if visible.contains(.bpm) || visible.contains(.metronome) {
                HStack(spacing: 10) {
                    if visible.contains(.metronome), let localShow {
                        HStack(spacing: 8) {
                            MetronomeModeButton(width: 30)
                            IpadAudioTransportButtons(show: localShow, configureMetronome: openMetronome, only: .metronome, controlWidth: 30)
                        }
                    }
                    if visible.contains(.bpm) {
                        HStack(spacing: 8) {
                            if let localShow {
                                NativeTransportMeterField(show: localShow)
                                    .id(localShow.projectSessionID)
                            }
                            nativeTransportStepper(width: bpmWidth, pitch: false)
                        }
                    }
                }.padding(.horizontal, 6).background(nativeTransportControlBackground)
            }
            if visible.contains(.tuner) {
                nativeTransportStepper(width: tunerWidth, pitch: true).background(nativeTransportControlBackground)
            }
        }.fixedSize()
    }
    private var nativeTransportControlBackground: some View {
        RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0x1b1b1b))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(JarasTheme.line))
    }
    private func nativeTransportStepper(width: Double, pitch: Bool) -> some View {
        let buttonWidth = min(28, max(18, width * 0.24))
        let bpm = localShow?.tempoControlBPM ?? state.bpm
        return HStack(spacing: 0) {
            Button { if pitch { stepPitch(-1) } else { stepTempo(-1) } } label: {
                Image(systemName: "minus").frame(width: buttonWidth, height: 32).contentShape(Rectangle())
            }.disabled(pitch ? state.pitchRegion == nil || (state.pitchSemitones ?? 0) <= -12 : bpm <= 60)
                .accessibilityLabel(pitch ? "Diminuir afinação" : "Diminuir BPM")
            VStack(spacing: 0) {
                Text(verbatim: pitch ? "Tuner" : "BPM")
                    .font(.jarasSystem(size: 9))
                Text(verbatim: pitch ? String(format: "%+dst", state.pitchSemitones ?? 0) : String(format: "%.0f", bpm))
                    .monospacedDigit().font(.jarasSystem(size: 13, weight: .semibold))
                    .foregroundStyle(pitch ? JarasTheme.green : state.tempoNeedsRender == true ? JarasTheme.yellow : JarasTheme.text)
            }.lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
                .modifier(NativeTunerTargets(show: pitch ? localShow : nil))
            Button { if pitch { stepPitch(1) } else { stepTempo(1) } } label: {
                Image(systemName: "plus").frame(width: buttonWidth, height: 32).contentShape(Rectangle())
            }.disabled(pitch ? state.pitchRegion == nil || (state.pitchSemitones ?? 0) >= 12 : bpm >= 300)
                .accessibilityLabel(pitch ? "Aumentar afinação" : "Aumentar BPM")
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green)
            .frame(width: width, height: 32)
            .disabled(pitch ? pitchStepPending : tempoStepPending)
    }
    private func topPrompterButton(_ panel: PrompterPanel, title: String, minimumHeight: CGFloat = 25) -> some View {
        Button { showPrompter(prompterPanel == panel ? nil : panel) } label: {
            Text(verbatim: title).font(.jarasSystem(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: minimumHeight)
                .modifier(RemoteControlSurface(radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.toolbarTint(active: prompterPanel == panel))
            .accessibilityLabel("Teleprompter \(panel.rawValue), controles superiores")
            .accessibilityValue(prompterPanel == panel ? "On" : "Off")
    }
    private func tabletPadsButton(width: CGFloat) -> some View {
        Button {
            if local {
                nativeVinhetasOpen.toggle()
                if nativeVinhetasOpen { nativeMIDIPreviewOpen = false; nativePianoOpen = false }
            } else { remoteVinhetasOpen.toggle() }
        } label: {
            ControlIcon(name: "square.grid.3x2.fill", active: local ? nativeVinhetasOpen : remoteVinhetasOpen).font(.jarasSystem(size: 17, weight: .semibold))
                .frame(width: width, height: 32).contentShape(Rectangle())
        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
            .foregroundStyle(JarasTheme.toolbarTint(active: local ? nativeVinhetasOpen : remoteVinhetasOpen))
            .accessibilityLabel("Pads")
            .contextMenu {
                Button((local ? nativeVinhetasDetached : remoteVinhetasDetached) ? "Indexar" : "Desindexar") {
                    if local {
                        nativeVinhetasDetached.toggle()
                        nativeVinhetasOpen = true
                        nativeMIDIPreviewOpen = false
                        nativePianoOpen = false
                    }
                    else { remoteVinhetasDetached.toggle(); remoteVinhetasOpen = true }
                }
            }
    }
    private func tabletPrompterButton(_ panel: PrompterPanel, width: CGFloat) -> some View {
        Button { showPrompter(prompterPanel == panel ? nil : panel) } label: {
            ControlIcon(name: "teleprompter\(panel.rawValue)", active: prompterPanel == panel).font(.jarasSystem(size: 10, weight: .bold))
                .frame(width: width, height: 32)
        }.foregroundStyle(JarasTheme.toolbarTint(active: prompterPanel == panel))
            .accessibilityLabel("Teleprompter \(panel.rawValue)")
            .accessibilityValue(prompterPanel == panel ? "On" : "Off")
            .modifier(IpadTeleprompterRemoteHold(
                open: openTeleprompterRemote.map { callback in { callback(panel.rawValue) } }, surface: true))
    }
    private var tunerControl: some View {
                HStack(spacing: local ? 4 : 6) {
                    Button { stepPitch(-1) } label: { Image(systemName: "minus").frame(width: 28, height: 32) }
                        .disabled(state.pitchRegion == nil || (state.pitchSemitones ?? 0) <= -12)
                        .accessibilityLabel("Diminuir afinação")
                    VStack(spacing: 0) {
                        Text(verbatim: "Tuner").font(.jarasSystem(size: 10))
                        Text(String(format: "%+dst", state.pitchSemitones ?? 0)).monospacedDigit()
                    }.frame(minWidth: local ? 48 : 70, maxWidth: .infinity)
                        .modifier(NativeTunerTargets(show: localShow))
                    Button { stepPitch(1) } label: { Image(systemName: "plus").frame(width: 28, height: 32) }
                        .disabled(state.pitchRegion == nil || (state.pitchSemitones ?? 0) >= 12)
                        .accessibilityLabel("Aumentar afinação")
                }.disabled(pitchStepPending)
                .font(.jarasSystem(size: local ? 12 : 14, weight: .semibold)).buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green)
                .padding(.horizontal, 4).frame(minWidth: local ? 0 : 134, maxWidth: local ? .infinity : UIDevice.current.userInterfaceIdiom == .pad ? 134 : .infinity, minHeight: 32).background(RemoteSurface.display).cornerRadius(5)
    }
    private var bpmControl: some View {
        HStack(spacing: 2) {
            Button { stepTempo(-1) } label: {
                Image(systemName: "minus").frame(width: 28, height: 32)
            }.accessibilityLabel("Diminuir BPM")
            Text(String(format: "%.0f BPM", state.bpm)).monospacedDigit()
                .foregroundStyle(state.tempoNeedsRender == true ? JarasTheme.yellow : JarasTheme.text)
                .frame(minWidth: local ? 48 : 70, maxWidth: .infinity)
            Button { stepTempo(1) } label: {
                Image(systemName: "plus").frame(width: 28, height: 32)
            }.accessibilityLabel("Aumentar BPM")
        }.disabled(tempoStepPending)
            .font(.jarasSystem(size: local ? 12 : 14, weight: .semibold)).buttonStyle(RemoteFullAreaButtonStyle())
            .frame(minWidth: local ? 0 : 134, maxWidth: local ? .infinity : UIDevice.current.userInterfaceIdiom == .pad ? 134 : .infinity, minHeight: 32)
            .foregroundStyle(JarasTheme.green).background(RemoteSurface.display).cornerRadius(5)
    }
    private var timeText: String {
        let seconds = max(0, Int(displayedPosition))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func stepTempo(_ delta: Double) {
        if let localShow {
            localShow.adjustTempo(delta)
            return
        }
        guard !tempoStepPending else { return }
        let next = min(300, max(60, state.bpm + delta))
        guard next != state.bpm else { return }
        guard tempoStepGate.accept(running: state.playing || state.subPlaying, at: ProcessInfo.processInfo.systemUptime) else { return }
        tempoStepPending = true
        let request = UUID(); tempoStepRequest = request
        action(.tempo, value: next)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if tempoStepRequest == request { tempoStepPending = false }
        }
    }
    private var fadeoutActive: Bool {
        if let pendingFadeout, Date().timeIntervalSince(pendingFadeout.sent) < 2 { return pendingFadeout.active }
        return state.fadeout?.active == true
    }
    private func toggleFadeout() {
        guard state.fadeout != nil, fadeoutActive || state.playing else { return }
        let command = DAWRemoteCommand(project: state.project, song: state.song, action: .transportFadeout, enabled: !fadeoutActive)
        pendingFadeout = (command.id, !fadeoutActive, Date())
        send(command)
    }
    private func fadeoutButton(width: CGFloat?, height: CGFloat) -> some View {
        Button(action: toggleFadeout) {
            let layout = height == 44 ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 2))
            layout {
                TransportControlIcon(name: "fadeout", size: height == 44 ? 16 : 13)
                Text(verbatim: "Fadeout").font(.jarasSystem(size: height == 44 ? 9 : 10, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.72)
            }
                .frame(maxWidth: width ?? .infinity)
                .frame(width: width, height: height)
                .foregroundStyle(Color.black)
                .background(Color(hex: 0xffff00), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle())
            .overlay { if local { IpadTapHoldTouchSurface(tap: toggleFadeout, hold: { fadeoutSettingsOpen = true }) } }
            .disabled(!local && (state.fadeout == nil || (!fadeoutActive && !state.playing)))
            .accessibilityLabel("Fadeout")
            .accessibilityAction(named: Text("Fadeout settings")) { if local { fadeoutSettingsOpen = true } }
    }
    @ViewBuilder private var fadeoutPresentation: some View {
        if fadeoutSettingsOpen, let localShow {
            IpadCompactModal(preferredSize: CGSize(width: 440, height: 620), onDismiss: { fadeoutSettingsOpen = false }) {
                TransportFadeoutSettings(show: localShow, close: { fadeoutSettingsOpen = false })
            }
        } else if fadeoutActive, let fadeout = state.fadeout, fadeout.active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let remaining = max(0, fadeout.remaining - max(0, context.date.timeIntervalSince(fadeoutReceivedAt)))
                TransportFadeoutProgress(duration: fadeout.duration, remaining: remaining)
            }.allowsHitTesting(false)
        }
    }
    private func stepPitch(_ delta: Int) {
        guard !pitchStepPending, let region = state.pitchRegion else { return }
        let current = state.pitchSemitones ?? 0, next = min(12, max(-12, current + delta))
        guard next != current else { return }
        pitchStepPending = true
        action(.pitch, target: region, value: Double(next))
    }
    private func smallButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }
            .buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: active, fontSize: local ? 10 : 12, width: local ? 60 : 72, height: 28))
    }
    private var nativeHeaderBands: TimelineHeaderBands {
        let rows = localShow?.current.map { song in
            let preview = regionMovePreview.map { song.previewMovingRegion($0.id, to: $0.start) } ?? song
            return RegionLanes(parts: preview.parts).count
        } ?? 1
        return TimelineHeaderBands(regionRows: rows, showRegions: showNativeRegionLanes, showTempo: showNativeTempoLane)
    }
    private func nativeBandTitle(_ title: String, height: CGFloat) -> some View {
        Text(verbatim: title).font(.jarasSystem(size: 12, weight: .semibold))
            .foregroundStyle(JarasTheme.secondary)
            .padding(.leading, 5).frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
            .overlay(alignment: .bottom) {
                Rectangle().fill(JarasTheme.timelineHeaderLine).frame(height: 1).allowsHitTesting(false)
            }
    }
    private var trackMixer: NativeTrackMixerPane {
        NativeTrackMixerPane(spacing: local ? 0 : 1,
            header: { AnyView(trackMixerHeader) },
            viewport: { AnyView(trackMixerViewport) })
    }

    @ViewBuilder private var trackMixerHeader: some View {
        // Match the grid's region, marker, tempo and time lanes so both lists
        // start at the same screen Y and have identical scroll limits.
        if local {
            if let localShow {
                let bands = nativeHeaderBands
                VStack(spacing: 0) {
                    if bands.showRegions { nativeBandTitle("Regions - Markers", height: bands.regionHeight) }
                    if bands.showTempo { nativeBandTitle("Tempo", height: bands.numberTop - bands.tempoTop) }
                    HStack(spacing: 4) {
                        Text(verbatim: "Track Mixer").font(.jarasSystem(size: 12, weight: .semibold))
                            .foregroundStyle(JarasTheme.secondary).lineLimit(1).padding(.leading, 5)
                        Spacer(minLength: 0)
                        IpadTimelineToolbar(show: localShow, addTrack: { addTrack?() }, editing: Binding(
                            get: { editingTracks }, set: { editingTracks = $0; if !$0 { trackReordering.cancel(); draggingSetlistEntries = [] } }),
                            showRegions: $showNativeRegionLanes, showTempo: $showNativeTempoLane)
                            .layoutPriority(1)
                    }.frame(height: bands.rulerHeight)
                }.background(RemoteSurface.panel)
                    .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.timelineHeaderLine).frame(height: 1).allowsHitTesting(false) }
            }
        } else if UIDevice.current.userInterfaceIdiom == .pad && !phoneLayout {
            RemoteSurface.panel.frame(height: RemoteNativeGridMetrics.rulerAreaHeight)
        } else {
            masterStrip.background(RemoteSurface.panel)
        }
    }

    private var trackMixerViewport: some View {
        let rows = visibleTracks
        let minimum = RemoteNativeGridMetrics.minimumTrackHeight(local: local)
        let heights = rows.map { CGFloat(DAWRemoteItemLayout.rowHeight($0, scale: trackScrolling.heightScale, minimum: minimum)) }
        let rowsHeight = max(0, heights.reduce(0, +) + CGFloat(rows.count - 1))
        let sourceTracks = Dictionary(uniqueKeysWithValues: (localShow?.current?.tracks ?? []).map { ($0.id, $0) })
        let hierarchy = DAWRemoteTrackHierarchy(state.tracks)
        let ancestors = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, hierarchy.ancestors(of: $0.id)) })
        let folders = hierarchy.folders
        let groupColors = Dictionary(state.tracks.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
        return GeometryReader { viewport in
            ScrollView(.vertical) {
                trackMixerRows(rows, heights: heights, sourceTracks: sourceTracks, ancestors: ancestors,
                               folders: folders, groupColors: groupColors, width: viewport.size.width, rowsHeight: rowsHeight)
                #if os(iOS)
                .background(RemoteTrackScrollProbe(controller: trackScrolling, tracks: rows,
                    selectedTrack: localShow?.selectedTrackForActions.flatMap { selectedTracks.contains($0) ? $0 : nil }
                        ?? rows.first(where: { selectedTracks.contains($0.id) })?.id, usesNativeTrackHeight: local))
                #endif
                .frame(height: max(local ? viewport.size.height : 0, CGFloat(rowsHeight)), alignment: .top)
                .overlay(alignment: .bottom) {
                    if local {
                        // The hit target starts after the final visible row;
                        // taps on row backgrounds and controls keep selecting
                        // or editing that row instead of clearing selection.
                        Color.clear.frame(height: max(0, viewport.size.height - CGFloat(rowsHeight)))
                            .contentShape(Rectangle())
                            .gesture(
                                TapGesture(count: 2).onEnded {
                                    guard nativeInputEnabled, let show = localShow else { return }
                                    clearTrackSelection()
                                    if let id = show.addDefaultMixerTrack() { selectedTracks = [id] }
                                }.exclusively(before: TapGesture().onEnded { clearTrackSelection() })
                            )
                            .accessibilityIdentifier("trackMixer.emptyArea")
                    }
                }
            }.background(RemoteSurface.background)
        }
    }

    // Keep the recycled and scrolling row types out of the surrounding
    // SwiftUI layout metadata. Resolving the combined type exceeded the
    // main thread stack on iPadOS 16 during project opening.
    private func trackMixerRows(_ rows: [DAWRemoteState.Track], heights: [CGFloat], sourceTracks: [UUID: Track],
                                ancestors: [UUID: [UUID]], folders: Set<UUID>, groupColors: [UUID: UInt32],
                                width: CGFloat, rowsHeight: CGFloat) -> AnyView {
        if local {
            return AnyView(IpadRecycledTrackRows(ids: rows.map(\.id), heights: heights,
                retained: { trackReordering.retainedTrack }) { index in
                mixerRow(rows, index: index, height: heights[index],
                         sourceTracks: sourceTracks, ancestors: ancestors, folders: folders, groupColors: groupColors)
                    .overlay(alignment: .bottom) {
                        if editingTracks, let song = state.song, let source = sourceTracks[rows[index].id] {
                            nativeTrackHeightHandle(rows[index], savedScale: source.heightScale,
                                                    project: state.project, song: song)
                        }
                    }
            }.frame(width: width, height: rowsHeight))
        }
        return AnyView(LazyVStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, _ in
                mixerRow(rows, index: index, height: heights[index],
                         sourceTracks: sourceTracks, ancestors: ancestors, folders: folders, groupColors: groupColors)
            }
        })
    }

    private func nativeTrackHeightHandle(_ row: DAWRemoteState.Track, savedScale: Double?,
                                         project: UUID, song: UUID) -> some View {
        var track = row
        track.heightScale = savedScale
        let baseScale = trackScrolling.heightScale
        let minimum = RemoteNativeGridMetrics.minimumTrackHeight(local: true)
        let scaleForDrag: (CGFloat) -> Double? = { distance in
            DAWRemoteItemLayout.resizedTrackHeightScale(track, scale: baseScale,
                                                       minimum: minimum, translation: Double(distance))
        }
        let apply: (CGFloat) -> Void = { distance in
            guard nativeInputEnabled, let scale = scaleForDrag(distance) else { return }
            localShow?.setTrackHeightScale(row.id, scale: scale, project: project, song: song)
        }
        return Capsule()
            .fill(trackHeightPreview?.track == row.id ? JarasTheme.green : JarasTheme.secondary.opacity(0.6))
            .frame(width: 30, height: 2)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($trackHeightPreview) { drag, preview, transaction in
                    guard nativeInputEnabled else { return }
                    transaction.disablesAnimations = true
                    preview = scaleForDrag(drag.translation.height).map {
                        TrackHeightPreview(project: project, song: song, track: row.id, scale: $0)
                    }
                }
                .onEnded { apply($0.translation.height) })
            .accessibilityLabel("Adjust track height")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: apply(12)
                case .decrement: apply(-12)
                @unknown default: break
                }
            }
    }

    private func mixerRow(_ rows: [DAWRemoteState.Track], index number: Int, height: CGFloat,
        sourceTracks: [UUID: Track], ancestors: [UUID: [UUID]], folders: Set<UUID>, groupColors: [UUID: UInt32]) -> AnyView {
        let track = rows[number]
        let nextAncestors = number + 1 < rows.count ? ancestors[rows[number + 1].id] ?? [] : []
        let guides = (ancestors[track.id] ?? []).map { nextAncestors.contains($0) }
        if local, !editingTracks, let show = localShow, let source = sourceTracks[track.id], source.kind == .programChange {
            return AnyView(ProgramChangeTrackRow(show: show, track: source, number: number + 1,
                selected: selectedTracks.contains(track.id), select: { toggleTrackSelection(track.id) },
                deleteTrack: { requestNativeTrackDeletion([track.id]) })
                .id(track.id)
                .frame(height: height))
        } else {
            return AnyView(RemoteNativeMixerRow(track: track, project: state.project, song: state.song, number: number + 1,
                nativeTrackSnapshot: sourceTracks[track.id],
                local: local, localShow: localShow, nativeContextMenu: local, nativePhaseInverted: sourceTracks[track.id]?.phaseInverted == true,
                mixFeedback: trackMixFeedback,
                editing: local && editingTracks, selected: selectedTracks.contains(track.id),
                selection: selectedTracks, groupGuides: guides, groupColor: track.parentTrack.flatMap { groupColors[$0] }, isGroup: folders.contains(track.id),
                select: { toggleTrackSelection(track.id) }, selectionMenu: {
                    trackScrolling.selectionScope = .tracks
                    if !selectedTracks.contains(track.id) { selectedTracks = [track.id]; localShow?.setMixerTrackSelection(selectedTracks, anchor: track.id) }
                    trackActionsOpen = true
                }, openPatch: local ? openPatch.map { callback in {
                    if editingTracks && sourceTracks[track.id]?.kind.isTeleprompter != true {
                        openSelectedPatch?(selectionTargets(track.id))
                    } else { callback(track.id) }
                } } : { showRemotePatch(track.id) }, openFX: local ? { openNativeFX(track.id, "Chain") } : nil,
                openAutomation: openTrackAutomation.map { callback in { callback(track.id) } }, addText: addTrackText.map { callback in { callback(track.id) } },
                addLyrics: addTrackLyrics.map { callback in { callback(track.id) } }) { command, value in
                action(command, target: track.id, value: value)
            }.equatable().frame(height: height)
                .modifier(LibraryTrackEffectDrop(show: localShow, track: sourceTracks[track.id]?.kind == .standard ? track.id : nil))
                .modifier(IpadTrackReorderModifier(show: localShow, track: track.id,
                    enabled: local && editingTracks, controller: trackReordering))
                .modifier(nativeTrackMenu(track.id, track: sourceTracks[track.id], folder: folders.contains(track.id))))
        }
    }
    private func openNativeFX(_ track: UUID?, _ effect: String) {
        guard local else { return }
        if effect == "Chain" {
            if let track {
                selectedTracks = [track]
                localShow?.setMixerTrackSelection(selectedTracks, anchor: track)
            }
            nativeFocusOpen = true
            if !horizontalPartsOpen { nativeLeftPartsOpen = false }
        } else if effect == "Library" {
            nativeLibraryOpen = true
        } else {
            openPlugin?(track, effect)
        }
    }
    private func nativeTrackMenu(_ id: UUID, track: Track?, folder: Bool) -> IpadTrackAudioContextMenu {
        let project = state.project, songID = state.song
        let song = localShow?.current
        let ids = selectedTracks.contains(id) ? selectedTracks : [id]
        let standard = track?.kind == .standard
        let patchable = track.map { $0.kind.isTeleprompter || [.standard, .timecode, .video, .click].contains($0.kind) } ?? false
        let canGroup = ids.count > 1 && localShow?.canCreateTrackGroup(id, selection: ids) == true
        func guarded(_ action: (() -> Void)?) -> (() -> Void)? {
            guard let action else { return nil }
            return {
                guard localShow?.snapshot.project.id == project, localShow?.current?.id == songID else { return }
                trackScrolling.selectionScope = .tracks
                selectedTracks = ids; localShow?.setMixerTrackSelection(ids, anchor: id)
                action()
            }
        }
        return IpadTrackAudioContextMenu(enabled: local,
            openPatch: guarded(patchable ? {
                if standard { openSelectedPatch?(selectionTargets(id)) } else { openPatch?(id) }
            } : nil),
            addAudio: guarded(standard && ids.count == 1 ? addTrackAudio.map { callback in { callback(id) } } : nil),
            fx: guarded(standard ? { openNativeFX(id, "Chain") } : nil),
            soundDesigner: guarded(track?.kind == .click ? openClickSound.map { callback in { callback(id) } } : nil),
            group: guarded(canGroup ? { localShow?.createTrackGroup(id) } : nil),
            ungroup: guarded((ids.count == 1 ? folder : song?.groupsForTrackSelection(ids).isEmpty == false) ? {
                localShow?.ungroupTracks(ids)
            } : nil),
            removeFromGroup: guarded(song?.tracks.contains(where: { ids.contains($0.id) && $0.parentTrackID != nil }) == true ? {
                for target in ids { localShow?.removeTrackFromGroup(target) }
            } : nil),
            link: guarded(song?.linkableTracks(ids) != nil ? { linkSelectedTracks(ids) } : nil),
            unlink: guarded(track?.stereoLink != nil ? { localShow?.unlinkTracks(id) } : nil),
            edit: guarded(openTrackDetails.map { callback in { callback(ids) } }),
            icon: guarded(openTrackIcon.map { callback in { callback(ids) } }),
            addMedia: guarded(track?.kind.isTeleprompter == true ? addTrackMedia.map { callback in { callback(id) } } : nil),
            duplicate: guarded(standard && track?.role.rawValue != "vinhetas" ? { localShow?.duplicateTracks(ids) } : nil),
            remove: guarded({ requestNativeTrackDeletion(ids) }), count: ids.count,
            createMIDI: guarded(standard && ids.count == 1 && track?.role.rawValue != "vinhetas" ? { _ = localShow?.addMIDIItem(track: id) } : nil),
            componentMask: track?.supportsMixerComponents == true ? localShow?.hiddenTrackMixerComponents(ids) : nil,
            toggleComponent: { component in
                guard localShow?.snapshot.project.id == project, localShow?.current?.id == songID else { return }
                localShow?.toggleTrackMixerComponents(ids, mask: component.rawValue, showWhenMixed: true)
            })
    }
    private func linkSelectedTracks(_ ids: Set<UUID>) {
        guard let show = localShow, let song = show.current, let indices = song.linkableTracks(ids) else { return }
        let top = song.tracks[indices[0]]
        show.linkTracks(ids, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel,
                        color: top.color ?? JarasTheme.roleHex(top.role))
    }
    private func clearTrackSelection() {
        trackScrolling.selectionScope = .tracks
        selectedTracks.removeAll()
        localShow?.setMixerTrackSelection([], anchor: nil)
    }
    private func toggleTrackSelection(_ id: UUID) {
        defer { localShow?.revealSelectedMixerTrack(id) }
        trackScrolling.selectionScope = .tracks
        if hardwareModifiers.contains(.shift), let anchor = localShow?.selectedTrackForActions,
           let first = visibleTracks.firstIndex(where: { $0.id == anchor }), let last = visibleTracks.firstIndex(where: { $0.id == id }) {
            selectedTracks = Set(visibleTracks[min(first, last)...max(first, last)].map(\.id))
            localShow?.setMixerTrackSelection(selectedTracks, anchor: anchor)
            return
        } else if editingTracks || !hardwareModifiers.intersection([.command, .control]).isEmpty {
            if !selectedTracks.insert(id).inserted { selectedTracks.remove(id) }
        } else { selectedTracks = [id] }
        localShow?.setMixerTrackSelection(selectedTracks, anchor: id)
    }
    private func showMappedParts() {
        if phoneLayout {
            if phonePanel != .sections { choosePhonePanel(.sections) }
        } else {
            if (nativeLeftPartsOpen || horizontalPartsOpen) && prompterPanel == nil { return }
            horizontalPartsOpen = false
            prompterFullscreen = false
            sectionsInList = true
            sectionsOpen = true
            if !mainSetlistVisible {
                if prompterPanel != nil { togglePrompterSetlist() }
                else { toggleMainSetlist() }
            }
        }
    }
    private func remoteSMKEvent(_ event: SMK37Session.Event) {
        if case let .padUp(token) = event { action(.vinhetasUp, target: token); return }
        guard !local, !observer, controlsEnabled, !RemoteMIDIActions.shared.isLearning else { return }
        switch event {
        case .connected: break
        case .preset(let index): action(.vinhetasPreset, value: Double(index))
        case .padDown(let token, let preset, let pad):
            SMK37Link.shared.padSelected(pad)
            send(.init(project: state.project, song: state.song, action: .vinhetasDown, target: token, pad: pad, preset: preset))
        case .padUp: break
        case .action(let control):
            switch control {
            case .padBusVolume(let value):
                guard let track = state.tracks.first(where: { $0.role == "vinhetas" }) else { return }
                pendingSMKAction = control; smkExpectedState = nil
                action(.volume, target: track.id, value: SMK37Protocol.padBusGain(value))
            case .record: smkExpectedState = !(state.recording == true); pendingSMKAction = control; action(.toggleRecord)
            case .preview: smkExpectedState = !(state.previewActive == true); pendingSMKAction = control; action(.togglePreview)
            case .auto: smkExpectedState = !(state.regionAuto == true); pendingSMKAction = control; action(.toggleRegionAuto)
            case .playStop: smkExpectedState = !(state.playing || state.paused); pendingSMKAction = control; action(state.playing || state.paused ? .stop : .play)
            case .pause: smkExpectedState = !(state.paused); pendingSMKAction = control; action(.pause)
            case .repeatLoop: smkExpectedState = !(state.loop); pendingSMKAction = control; action(.toggleLoop)
            case .playlist(let delta):
                let lists = state.playlists ?? []
                guard !lists.isEmpty, delta != 0 else { return }
                let anchor = lists.firstIndex { $0.id == (remoteMIDIPlaylistID ?? state.selectedPlaylist) }
                let index = anchor.map { (($0 + delta) % lists.count + lists.count) % lists.count } ?? (delta > 0 ? 0 : lists.count - 1)
                remoteMIDIPlaylistID = lists[index].id; remoteMIDISetlistID = nil
                smkExpectedState = nil; pendingSMKAction = control
                action(.selectPlaylist, target: lists[index].id)
            case .fadeout(let active):
                guard state.playing, let fade = state.fadeout, active ? !fade.active : fade.active else { return }
                smkExpectedState = active; pendingSMKAction = control
                send(.init(project: state.project, song: state.song, action: .transportFadeout, enabled: active))
            case .previewPage(let delta):
                let page = min(5, max(0, (smkRequestedPage ?? state.previewPage ?? 0) + delta))
                smkRequestedPage = page; pendingSMKAction = control; action(.selectPreviewPage, value: Double(page))
            case .scrollTracks(let direction):
                trackScrolling.step(direction)
                SMK37Link.shared.feedback(direction < 0 ? "TRACK MIXER ACIMA" : "TRACK MIXER ABAIXO")
            case .songs(let direction):
                performRemoteMIDI(direction < 0 ? .setlistUp : .setlistDown)
                let rows = setlistRowsCache.entries(in: state, expanded: [], query: "", order: local && state.selectedPlaylist == nil ? allRegionsOrder : nil).compactMap { entry -> DAWRemoteState.Region? in
                    if case .region(let row) = entry, !row.child { return row.region }; return nil
                }
                if let index = rows.firstIndex(where: { $0.id == remoteMIDISetlistID }) {
                    SMK37Link.shared.navigation(kind: 1, rows: SMK37Protocol.window(rows.map(\.name), selected: index))
                }
            case .currentParts(let direction): remoteSMKParts(queued: false, direction: direction)
            case .queuedParts(let direction): remoteSMKParts(queued: true, direction: direction)
            case .confirm:
                if case let .parts(_, _, marker) = smkNavigation.focus { action(.queueSection, target: marker) }
                else if let id = remoteMIDISetlistID ?? selectedSetlistEntries.first ?? state.focusedRegion { action(.selectRegion, target: id) }
            }
        }
    }
    private func remoteSMKParts(queued: Bool, direction: Int) {
        let id = queued ? state.sectionPlayback?.secondaryRegion : state.sectionPlayback?.currentRegion
        guard let region = state.timelineRegions.first(where: { $0.id == id }) else { return }
        let markers = (state.markers ?? []).filter { $0.section == true && $0.position >= region.start && $0.position <= region.end }.sorted { $0.position < $1.position }
        guard let chosen = smkNavigation.move(queued: queued, direction: direction, leftOpen: false,
            setlistOpen: phoneLayout ? phonePanel == .sections : sectionsOpen, markers: [region.id] + markers.map(\.id)),
            case let .parts(panel, _, _) = smkNavigation.focus else { return }
        partsTabSelection.send(.init(secondary: queued, panel: panel))
        let ids = [region.id] + markers.map(\.id)
        if let index = ids.firstIndex(of: chosen) {
            SMK37Link.shared.navigation(kind: queued ? 3 : 2, rows: SMK37Protocol.window(["INÍCIO"] + markers.map(\.name), selected: index))
        }
    }
    private func remoteSMKFeedback() {
        let link = SMK37Link.shared
        link.playlist(state.playlists?.first { $0.id == state.selectedPlaylist }?.name ?? "All regions")
        if let pads = state.vinhetas { link.remoteLibrary(pads) }
        link.fadeout(active: state.fadeout?.active == true, remaining: state.fadeout?.remaining ?? 0, duration: state.fadeout?.duration ?? 0)
        let region = state.timelineRegions.first { $0.id == state.currentRegion }
        link.songTitles(playing: region?.name ?? "", queued: state.timelineRegions.first { $0.id == state.queuedRegion }?.name ?? "")
        link.playback(position: state.position, start: region?.start ?? 0, end: region?.end ?? state.duration)
        let marker = state.loopStart.flatMap { start in
            (state.markers ?? []).filter { $0.section == true && $0.position <= start + 0.000001 && $0.position >= (region?.start ?? 0) }.max { $0.position < $1.position }
        }
        link.transport(paused: state.paused, recording: state.recording == true, looping: state.loop,
            auto: state.regionAuto == true, preview: state.previewActive == true, playing: state.playing, queued: state.queuedRegion != nil,
            loopName: state.smkLoopName ?? marker?.name ?? region?.name ?? "", loopColor: state.smkLoopColor ?? marker?.color ?? region?.color ?? 0xffb347)
    }
    private func finishRemoteSMKAction() {
        guard let control = pendingSMKAction else { return }
        let actual: Bool?
        switch control {
        case .record: actual = state.recording == true
        case .preview: actual = state.previewActive == true
        case .auto: actual = state.regionAuto == true
        case .playStop: actual = state.playing || state.paused
        case .pause: actual = state.paused
        case .repeatLoop: actual = state.loop
        case .fadeout: actual = state.fadeout?.active == true
        default: actual = nil
        }
        if let expected = smkExpectedState, let actual, expected != actual { return }
        // State packets are authoritative: feedback describes the actual host.
        let label: String?
        switch control {
        case .record: label = state.recording == true ? nil : "REC DESATIVADO"
        case .preview: label = state.previewActive == true ? "PREVIEW ATIVADO" : "PREVIEW DESATIVADO"
        case .auto: label = state.regionAuto == true ? "AUTO ATIVO" : "AUTO DESATIVADO"
        case .playStop: label = state.playing ? "PLAY" : "STOP"
        case .pause: label = state.paused ? nil : state.playing ? "PLAY" : "STOP"
        case .repeatLoop: label = state.loop ? nil : "LOOP DESATIVADO"
        case .fadeout: label = state.fadeout?.active == true ? nil : "FADE OUT CANCELADO"
        case .padBusVolume(let value):
            guard let track = state.tracks.first(where: { $0.role == "vinhetas" }), abs(track.volume - SMK37Protocol.padBusGain(value)) < 0.0001 else { return }
            label = SMK37Protocol.padBusLabel(gain: track.volume)
        case .playlist:
            guard state.selectedPlaylist == remoteMIDIPlaylistID else { return }
            label = state.playlists?.first { $0.id == state.selectedPlaylist }?.name
        case .previewPage:
            guard state.previewPage == smkRequestedPage else { return }
            let first = (state.previewPage ?? 0) * 4 + 1; label = "BLOCO \(first)-\(first+3)"; smkRequestedPage = nil
        default: label = nil
        }
        pendingSMKAction = nil; smkExpectedState = nil
        if let label { SMK37Link.shared.feedback(label) }
    }
    private func performRemoteMIDI(_ command: RemoteMIDIAction) {
        guard !local, !observer, !RemoteMIDIActions.shared.isLearning else { return }
        switch command {
        case .playStop: action(state.playing || state.paused ? .stop : .play)
        case .subPlayStop: if state.playing { action(state.subPlaying ? .subStop : .subPlay) }
        case .repeatPlayback: action(.toggleLoop)
        case .togglePreview: if state.previewActive != nil { action(.togglePreview) }
        case .bypass: action(.toggleMultiLoopBypass)
        case .cancelSection: action(.cancelSection)
        case .parts1, .parts2:
            partsTabSelection.send(.init(secondary: command == .parts2))
            showMappedParts()
        case .toggleParts:
            if phoneLayout { choosePhonePanel(phonePanel.togglingFooterParts()) }
            else { horizontalPartsOpen = false; sectionsInList = true; sectionsOpen.toggle() }
        case .playlistUp, .playlistDown:
            let ids = (state.playlists ?? []).map(\.id)
            guard !ids.isEmpty else { return }
            let direction = command == .playlistDown ? 1 : -1
            let index = (remoteMIDIPlaylistID ?? state.selectedPlaylist).flatMap { ids.firstIndex(of: $0) }
            let next = index.map { ($0 + direction + ids.count) % ids.count } ?? (direction > 0 ? 0 : ids.count - 1)
            remoteMIDIPlaylistID = ids[next]; remoteMIDISetlistID = nil
            action(.selectPlaylist, target: ids[next])
        case .setlistUp, .setlistDown:
            smkNavigation.selectSongs()
            let ids = setlistRowsCache.entries(in: state, expanded: [], query: "", order: local && state.selectedPlaylist == nil ? allRegionsOrder : nil).compactMap { entry -> UUID? in
                if case .region(let row) = entry, !row.child { return row.region.id }; return nil
            }
            guard !ids.isEmpty else { return }
            let direction = command == .setlistDown ? 1 : -1
            let current = remoteMIDISetlistID ?? selectedSetlistEntries.first ?? state.focusedRegion
            let next = current.flatMap { ids.firstIndex(of: $0) }.map { min(ids.count - 1, max(0, $0 + direction)) } ?? (direction > 0 ? 0 : ids.count - 1)
            remoteMIDISetlistID = ids[next]; selectedSetlistEntries = [ids[next]]
            action(.browseRegion, target: ids[next])
        case .partsUp, .partsDown:
            guard let region = state.timelineRegions.first(where: { $0.id == state.sectionPlayback?.currentRegion }) else { return }
            let markers = (state.markers ?? []).filter { $0.section == true && $0.position >= region.start && $0.position <= region.end }.sorted { $0.position < $1.position }
            guard !markers.isEmpty else { return }
            let ids = markers.map(\.id), direction = command == .partsDown ? 1 : -1
            let anchor = remoteMIDIPartID ?? state.sectionPlayback?.queuedMarker ?? markers.last(where: { $0.position <= (state.sectionPlayback?.position ?? state.position) })?.id
            let next = anchor.flatMap { ids.firstIndex(of: $0) }.map { min(ids.count - 1, max(0, $0 + direction)) } ?? (direction > 0 ? 0 : ids.count - 1)
            remoteMIDIPartID = ids[next]; action(.queueSection, target: ids[next])
        }
    }
    private func remoteSetlistBlockNumber(_ id: UUID) -> Int? {
        guard state.selectedPlaylist != nil else { return nil }
        let entries = setlistRowsCache.entries(in: state, expanded: [], query: "")
        var number = 0
        for entry in entries {
            if case .block(let block) = entry {
                number += 1
                if block.id == id { return number }
            }
        }
        return nil
    }
    private func performRemoteBlockMIDI(_ number: Int) {
        guard !local, !observer, controlsEnabled, !RemoteMIDIActions.shared.isLearning,
              state.selectedPlaylist != nil, number > 0 else { return }
        // Search and expanded drawers must not renumber the playlist's blocks.
        // Resolve against the latest host snapshot, never a learned UUID.
        let entries = setlistRowsCache.entries(in: state, expanded: [], query: "")
        var ordinal = 0
        for entry in entries {
            switch entry {
            case .block: ordinal += 1
            case .region(let row):
                if ordinal >= number {
                    remoteMIDISetlistID = row.region.id
                    selectSetlistEntry(row.region.id)
                    return
                }
            }
        }
    }
    private func selectionTargets(_ clicked: UUID) -> [UUID] {
        let ids = selectedTracks.contains(clicked) ? selectedTracks : [clicked]
        return state.tracks.filter { ids.contains($0.id) }.map(\.id)
    }
    private func selectSetlistEntry(_ id: UUID) {
        smkNavigation.selectSongs(); localShow?.smkNavigation.selectSongs()
        nativeKeyboardBrowsing = false
        trackScrolling.selectionScope = .setlist
        let isBlock = local && (state.setlistBlocks?.contains { $0.id == id } == true)
        if local, hardwareModifiers.contains(.shift), let anchor = setlistSelectionAnchor {
            let ids = setlistRowsCache.entries(in: state, expanded: expandedRegions, query: search, order: local && state.selectedPlaylist == nil ? allRegionsOrder : nil).map { entry -> UUID in
                switch entry { case .region(let row): return row.region.id; case .block(let block): return block.id }
            }
            if let first = ids.firstIndex(of: anchor), let last = ids.firstIndex(of: id) {
                selectedSetlistEntries = Set(ids[min(first, last)...max(first, last)])
            }
        } else if local, !hardwareModifiers.intersection([.command, .control]).isEmpty {
            if !selectedSetlistEntries.insert(id).inserted { selectedSetlistEntries.remove(id) }
            setlistSelectionAnchor = id
        } else {
            selectedSetlistEntries = state.showsSetlistSelection ? [id] : []
            setlistSelectionAnchor = state.showsSetlistSelection ? id : nil
            if !isBlock { action(.selectRegion, target: id) }
        }
        if local { localShow?.selectSetlistBlock(selectedSetlistEntries.count == 1 ? selectedSetlistEntries.first : nil) }
    }
    private func prepareNativeSetlistDrag(_ id: UUID) -> Bool {
        draggingSetlistEntries = []
        guard local, editingTracks, let show = localShow, let playlist = state.selectedPlaylist,
              show.snapshot.project.id == state.project, show.current?.id == state.song,
              show.selectedRegionPlaylist?.id == playlist else { return false }
        let available = Set(show.setlistEntries.map(\.id))
        guard available.contains(id) else { return false }
        trackScrolling.selectionScope = .setlist
        // A selected row keeps the complete batch when the drag begins. A block
        // is one playlist entry; the songs below it are not implicitly selected.
        if selectedSetlistEntries.contains(id) { selectedSetlistEntries.formIntersection(available) }
        else { selectedSetlistEntries = [id]; setlistSelectionAnchor = id }
        draggingSetlistEntries = selectedSetlistEntries
        show.selectSetlistBlock(selectedSetlistEntries.count == 1 ? selectedSetlistEntries.first : nil)
        return true
    }
    private var setlist: some View {
        let played = Set(state.playedLiveRegionIDs ?? [])
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
            Button { searchFocused = false; playlistPickerOpen = true } label: {
                HStack(spacing: 8) {
                    if let playlist = state.playlists?.first(where: { $0.id == state.selectedPlaylist }) {
                        Text(verbatim: playlist.name).lineLimit(1)
                    } else { Text("All regions").lineLimit(1) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.jarasSystem(size: 10, weight: .bold))
                }.font(.jarasSystem(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.text)
                    .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 30)
                    .background(RemoteSurface.panel)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.45)))
                    .contentShape(Rectangle())
            }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Selecionar playlist")
                .contextMenu { playlistMenu(state.selectedPlaylist) }
                .popover(isPresented: $playlistPickerOpen, arrowEdge: .top) {
                    RemoteNativePlaylistPicker(playlists: state.playlists ?? [], selected: state.selectedPlaylist,
                        choose: { id in action(.selectPlaylist, target: id); playlistPickerOpen = false },
                        close: { playlistPickerOpen = false }, edit: { id in editPlaylist(id) },
                        duplicate: { action(.duplicatePlaylist, target: $0) },
                        remove: { requestRemoval(.deletePlaylist, id: $0) },
                        copy: copyPlaylist, add: local ? { id in beginAddingToPlaylist(id) } : nil).equatable()
                }
            if createPlaylist != nil {
                Button { addingToPlaylist = nil; creatingPlaylist = true } label: {
                    Image(systemName: "plus").frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.green)
                    .accessibilityLabel("Create playlist")
            }
            }
            HStack(spacing: 6) {
                TextField("Pesquisar músicas", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                Button { action(.toggleRegionAuto) } label: {
                    Text(verbatim: "AUTO").font(.jarasSystem(size: 9, weight: .bold)).frame(width: local ? 40 : 34, height: local ? 30 : 26)
                        .foregroundStyle(state.regionAuto == true ? Color.black : JarasTheme.secondary)
                        .modifier(RemoteControlSurface(color: state.regionAuto == true ? JarasTheme.yellow : nil, radius: 4))
                        .modifier(JarasBlink(active: state.regionAuto == true))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("AUTO").accessibilityValue(state.regionAuto == true ? "On" : "Off")
                    .contextMenu { if local { Button("Settings") { autoSettings = true } } }
                if let addBlock {
                    Button {
                        if state.selectedPlaylist == nil { allRegionsOrder = (allRegionsOrder + 1) % 3 }
                        else { addBlock() }
                    } label: {
                        Text(verbatim: state.selectedPlaylist == nil ? ["Timeline", "A-Z", "Z-A"][min(2,max(0,allRegionsOrder))] : JarasLocalization.string("Blocks").uppercased()).font(.jarasSystem(size: 9, weight: .bold))
                            .foregroundStyle(JarasTheme.text).frame(width: state.selectedPlaylist == nil ? 52 : 40, height: 30)
                            .modifier(RemoteControlSurface(color: nil, radius: 4))
                            .contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle())

                }
                if let toggleRegionStop {
                    Button(action: toggleRegionStop) {
                        Text(verbatim: "STOP").font(.jarasSystem(size: 9, weight: .bold))
                            .foregroundStyle(stopsAtRegionEnd ? JarasTheme.green : Color.red)
                            .frame(width: local ? 40 : 38, height: local ? 30 : 26)
                            .background(JarasTheme.panel).clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(stopsAtRegionEnd ? JarasTheme.green : Color.red))
                    }.buttonStyle(RemoteFullAreaButtonStyle())
                        .modifier(JarasBlink(active: stopsAtRegionEnd, interval: 0.55))
                        .accessibilityLabel("Region stop").accessibilityValue(stopsAtRegionEnd ? "On" : "Off")
                        .jarasHelp("Stop automatically at the end of each region")
                }
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if !local && state.regions.isEmpty && (state.setlistBlocks?.isEmpty ?? true) {
                            ForEach(state.songs.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { song in
                                Button { action(.selectSong, target: song.id) } label: {
                                    setlistLabel(song.name, selected: song.id == state.song, active: state.playing && song.id == state.song, queued: false, color: JarasTheme.panel)
                                }.buttonStyle(RemoteFullAreaButtonStyle())
                            }
                        } else {
                            ForEach(setlistRowsCache.entries(in: state, expanded: expandedRegions, query: search, order: local && state.selectedPlaylist == nil ? allRegionsOrder : nil)) { entry in
                                switch entry {
                                case .block(let block): setlistBlockRow(block)
                                case .region(let row):
                                let region = row.region
                                Button { selectSetlistEntry(region.id) } label: {
                                    setlistLabel(region.name, number: row.number, played: played.contains(region.sourceRegionId ?? region.id), selected: smkNavigation.focus == .songs && (state.showsSetlistSelection || (local && nativeKeyboardBrowsing)) && (selectedSetlistEntries.contains(region.id) || (selectedSetlistEntries.isEmpty && region.id == state.focusedRegion)),
                                        active: state.playing && region.id == state.setlistCurrentEntryId, queued: state.playing && region.id == (state.setlistQueuedEntryId),
                                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? (row.child ? 0xffeb3b : 0xffffff)),
                                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.setlistCurrentEntryId ? state.position : region.start)))),
                                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                                }.buttonStyle(RemoteFullAreaButtonStyle())
                                    .modifier(NativeRegionDrawerGesture(enabled: (local || !phoneLayout) && row.hasDrawer,
                                        expanded: expandedRegions.contains(region.id),
                                        change: { setDrawer(region.id, expanded: $0) }))
                                    .modifier(NativeSetlistDragHandle(enabled: local && editingTracks && state.selectedPlaylist != nil && region.parentRegion == nil) {
                                        guard prepareNativeSetlistDrag(region.id) else { return NSItemProvider() }
                                        return NSItemProvider(object: ("catlive-setlist:" + region.id.uuidString) as NSString)
                                    })
                                    .modifier(IpadSetlistDropTarget(show: localShow, target: region.id, project: state.project,
                                        playlist: state.selectedPlaylist, moving: $draggingSetlistEntries, enabled: local && editingTracks))
                                    .contextMenu {
                                        Button("Editar região") {
                                            if local, let openRegionActions { openRegionActions(region.sourceRegionId ?? region.id) }
                                            else { editingEntry = .init(id: region.id, playlist: false, name: region.name, color: region.color) }
                                        }
                                        if let detectRegionBPM { Button("Detect BPM…") { detectRegionBPM(region.sourceRegionId ?? region.id) } }
                                        if !state.timelineRegions.contains(where: { $0.parentRegion == (region.sourceRegionId ?? region.id) }), let openRegionLoops { Button("Multiloops") { openRegionLoops(region.sourceRegionId ?? region.id) } }
                                        if let playlist = state.selectedPlaylist, region.parentRegion == nil, !selectedSetlistEntries.contains(region.id) || selectedSetlistEntries.count == 1 {
                                            Button("Duplicate region") { action(.duplicateRegion, target: region.id, playlist: playlist) }
                                        }
                                        if local { Button("Config Init") { configInitRegion = region.sourceRegionId ?? region.id } }
                                        if local, state.selectedPlaylist == nil, let song = localShow?.current,
                                           let source = song.parts.first(where: { $0.id == (region.sourceRegionId ?? region.id) }),
                                           song.isOrdinaryRegion(source) {
                                            let targets = selectedSetlistEntries.contains(region.id) ? selectedSetlistEntries : [region.id]
                                            Button("Set region end to longest item") { localShow?.fitRegionEndsToItems(targets) }
                                                .disabled(localShow?.timelineRegionsLocked == true)
                                            Button("Space regions by 30 s") { localShow?.spaceRegionsAfter(targets) }
                                                .disabled(localShow?.timelineRegionsLocked == true)
                                        }
                                        let sourceID = region.sourceRegionId ?? region.id
                                        if local, let multitrackAction, let show = localShow, let song = show.current,
                                           let part = song.parts.first(where: { $0.id == sourceID }), part.parentRegionID == nil {
                                            Button("Export Multitrack") { multitrackAction(sourceID, Set(selectedSetlistEntries.map(show.playlistRegionSourceID))) }
                                        }
                                        if !local && phoneLayout && row.hasDrawer {
                                            Button(expandedRegions.contains(region.id) ? "Close drawer" : "Open drawer") { toggleDrawer(region.id) }
                                        }
                                        if region.parentRegion == nil {
                                            Button(state.selectedPlaylist == nil ? "Delete region" : "Remove from playlist", role: .destructive) {
                                                requestRemoval(.deleteRegion, id: region.id, playlist: state.selectedPlaylist)
                                            }
                                        }
                                    }
                                    .padding(.leading, row.child ? 20 : 0).id(row.id)
                                }
                            }
                        }
                    }
                }.onChange(of: state.focusedRegion) { id in
                    if let id { scroll.scrollTo(id, anchor: .center) }
                }
            }
            if UIDevice.current.userInterfaceIdiom != .phone { setlistControls }
        }.padding([.top, .leading, .trailing], 10).background(RemoteSurface.background)
    }
    @ViewBuilder private func setlistBlockRow(_ block: DAWRemoteState.SetlistBlock) -> some View {
        if local {
            Button { selectSetlistEntry(block.id) } label: {
                RemoteSetlistBlockLabel(block: block, fontStyle: state.setlistFontStyle ?? 0,
                    selected: state.showsSetlistSelection && selectedSetlistEntries.contains(block.id)).equatable()
            }.buttonStyle(RemoteFullAreaButtonStyle())
                .modifier(NativeSetlistDragHandle(enabled: editingTracks && state.selectedPlaylist != nil) {
                    guard prepareNativeSetlistDrag(block.id) else { return NSItemProvider() }
                    return NSItemProvider(object: ("catlive-setlist:" + block.id.uuidString) as NSString)
                })
                .modifier(IpadSetlistDropTarget(show: localShow, target: block.id, project: state.project,
                    playlist: state.selectedPlaylist, moving: $draggingSetlistEntries, enabled: editingTracks))
                .contextMenu {
                    let targets = selectedSetlistEntries.contains(block.id)
                        ? selectedSetlistEntries.intersection(Set(state.setlistBlocks?.map(\.id) ?? [])) : [block.id]
                    Button("Edit block") {
                        editingBlockSymbol = block.symbol
                        editingEntry = .init(id: block.id, playlist: false, name: block.name, color: block.color, block: true)
                    }.onAppear {
                        trackScrolling.selectionScope = .setlist
                        if !selectedSetlistEntries.contains(block.id) { selectSetlistEntry(block.id) }
                    }
                    if let number = localShow?.setlistBlockNumber(block.id) {
                        Button("Learn MIDI") { ControlMappings.shared.beginSetlistBlock(number) }
                    }
                    Button(targets.count > 1 ? "Delete blocks" : "Delete block", role: .destructive) {
                        requestNativeSetlistRemoval(targets)
                    }
                }.id(block.id)
        } else if !observer {
            RemoteSetlistBlockLabel(block: block, fontStyle: state.setlistFontStyle ?? 0).equatable()
                .contextMenu {
                    if let number = remoteSetlistBlockNumber(block.id) {
                        Button("Learn MIDI") { RemoteMIDIActions.shared.beginBlock(number) }
                    }
                }
        } else {
            RemoteSetlistBlockLabel(block: block, fontStyle: state.setlistFontStyle ?? 0).equatable()
        }
    }
    private func editPlaylist(_ id: UUID) {
        guard let entry = state.playlists?.first(where: { $0.id == id }) else { return }
        playlistPickerOpen = false
        editingEntry = .init(id: id, playlist: true, name: entry.name, color: 0)
    }
    private func requestRemoval(_ type: DAWRemoteCommand.Action, id: UUID, playlist: UUID? = nil) {
        if local, type == .deleteRegion { requestNativeSetlistRemoval([id]); return }
        playlistPickerOpen = false
        nativeSetlistRemoval = nil
        removal = .init(project: state.project, song: state.song, action: type, target: id, playlist: playlist)
        confirmingRemoval = true
    }
    private func copyPlaylist(_ id: UUID?) {
        guard let show = localShow, let song = show.current else { return }
        UIPasteboard.general.string = SetlistShareText.make(song: song, setlist: show.regionSetlist, playlistID: id,
            allRegionsTitle: JarasLocalization.string("All regions"), totalDurationTitle: JarasLocalization.string("Total duration"))
    }
    private func beginAddingToPlaylist(_ id: UUID) {
        playlistPickerOpen = false; addingToPlaylist = id; creatingPlaylist = true
    }
    @ViewBuilder private func playlistMenu(_ id: UUID?) -> some View {
        Button("Copy to share") { copyPlaylist(id) }.disabled(!local)
        if let id {
            Divider()
            if local { Button("Add regions") { beginAddingToPlaylist(id) } }
            Button("Edit") { editPlaylist(id) }
            Button("Clone playlist") { action(.duplicatePlaylist, target: id) }
            Button("Delete playlist", role: .destructive) { requestRemoval(.deletePlaylist, id: id) }
        }
    }
    private func setlistLabel(_ title: String, number: Int? = nil, played: Bool = false, selected: Bool = false, active: Bool, queued: Bool, color: Color, nameColor: Color = JarasTheme.text, duration: Int? = nil, progress: Double = 0, queueProgress: Double = 0) -> some View {
        RemoteSetlistRowLabel(title: title, number: number, played: played, selected: selected,
            active: active, queued: queued, color: color, nameColor: nameColor, duration: duration,
            progress: active ? progress : 0, queueProgress: queued ? queueProgress : 0,
            fontStyle: state.setlistFontStyle ?? 0, prepareOnly: state.prepareOnly == true,
            scale: observer ? min(2.5, max(1, observerSetlistScale)) : 1).equatable()
    }

}

/// Only the visible Edit grip starts a native Setlist reorder. Song presses
/// and long presses keep their normal selection and context-menu behavior.
private struct NativeSetlistDragHandle: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal").font(.jarasSystem(size: 14, weight: .semibold))
                    .foregroundStyle(JarasTheme.secondary).frame(width: 28, height: 36)
                    .contentShape(Rectangle()).onDrag(provider)
                content
            }
        } else { content }
    }
}

/// Observe the learner independently: incoming MIDI must not redraw the grid.
private struct NativeSetlistControlMappingOverlay: View {
    @ObservedObject private var mappings = ControlMappings.shared
    var body: some View {
        if mappings.editing != nil {
            ZStack {
                Color.black.opacity(0.58).ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { mappings.editing = nil }
                ControlMappingEditor()
                    .buttonStyle(IpadDialogButtonStyle())
                    .foregroundStyle(JarasTheme.text).tint(JarasTheme.green)
                    .preferredColorScheme(.dark)
            }.accessibilityAddTraits(.isModal)
        }
    }
}

/// Playlist block headers keep their saved color, symbol and order; Observer
/// uses the same display without acquiring any playback controls.
private struct RemoteSetlistBlockLabel: View, Equatable {
    let block: DAWRemoteState.SetlistBlock
    let fontStyle: Int
    var scale = 1.0
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            if block.symbol {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 6)); path.addLine(to: CGPoint(x: 45, y: 6))
                    path.move(to: CGPoint(x: 39, y: 0)); path.addLine(to: CGPoint(x: 45, y: 6)); path.addLine(to: CGPoint(x: 39, y: 12))
                }.stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 45, height: 12).accessibilityHidden(true)
            }
            Text(verbatim: block.name)
                .font(SetlistTypeface.font(fontStyle, size: 13 * scale))
                .foregroundStyle(remoteColor(block.nameColor ?? 0x69ed91)).lineLimit(2)
        }.padding(.horizontal, 10).padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? JarasTheme.green.opacity(0.22) : remoteColor(block.color).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? JarasTheme.green : remoteColor(block.color).opacity(0.5), lineWidth: selected ? 2 : 1))
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

/// Static songs do not rebuild text/layout when the transport advances. Only
/// the playing/queued label receives a moving progress value.
private struct RemoteSetlistRowLabel: View, Equatable {
    let title: String
    let number: Int?
    let played: Bool
    let selected: Bool
    let active: Bool
    let queued: Bool
    let color: Color
    let nameColor: Color
    let duration: Int?
    let progress: Double
    let queueProgress: Double
    let fontStyle: Int
    let prepareOnly: Bool
    var scale = 1.0
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(active ? Color.red : queued ? (prepareOnly ? JarasTheme.green : JarasTheme.yellow) : color).frame(width: 3)
            if let number { Text(String(format: "%02d", number)).font(.jarasSystem(size: 10 * scale, design: .monospaced)).foregroundStyle(JarasTheme.secondary) }
            Text(verbatim: title)
                .font(SetlistTypeface.font(fontStyle, size: 13 * scale))
                .foregroundStyle(nameColor).strikethrough(played, color: nameColor).lineLimit(2)
            Spacer(minLength: 0)
            if let duration { Text(String(format: "%dm %02ds", duration / 60, duration % 60)).font(.jarasSystem(size: 10 * scale, weight: .medium, design: .monospaced)).foregroundStyle(JarasTheme.text) }
            if active { Image(systemName: "play.fill").foregroundStyle(JarasTheme.green) }
            if queued { Image(systemName: "arrow.right").foregroundStyle(JarasTheme.yellow) }
        }.padding(.horizontal, 8).padding(.vertical, 7 * scale).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 38 * scale)
            .background {
                if active {
                    JarasTheme.liveOffRed
                } else if queued {
                    LinearGradient(colors: prepareOnly ? [Color(hex: 0x19633a), Color(hex: 0x123b27)] : JarasTheme.setlistQueuedGradient,
                                   startPoint: .top, endPoint: .bottom)
                } else if selected {
                    LinearGradient(colors: [Color(hex: 0x2457a9), Color(hex: 0x152b58)], startPoint: .top, endPoint: .bottom)
                } else if played { RemoteSurface.fill(Color(hex: 0x451010)) }
                else { RemoteSurface.panel }
            }.cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(RemoteSurface.edge, lineWidth: 0.5).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected && !active && !queued ? JarasTheme.green : .clear, lineWidth: 1.5))
            .overlay(alignment: .bottomLeading) {
                if active || queued {
                    GeometryReader { geometry in
                        Rectangle().fill(active ? JarasTheme.green : JarasTheme.yellow)
                            .frame(width: geometry.size.width * (active ? progress : queueProgress), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }.allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}
private enum RemoteMIDIAction: String, CaseIterable, Identifiable, Codable {
    case setlistUp, setlistDown, partsUp, partsDown, parts1, parts2, toggleParts, cancelSection, playStop, subPlayStop, togglePreview, repeatPlayback, bypass, playlistUp, playlistDown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setlistUp: return "Setlist Up"
        case .setlistDown: return "Setlist Down"
        case .partsUp: return "Parts Up"
        case .partsDown: return "Parts Down"
        case .parts1: return "Parts 1"
        case .parts2: return "Parts 2"
        case .toggleParts: return "Parts"
        case .cancelSection: return "Cancel queued section"
        case .playStop: return "Play / Stop"
        case .subPlayStop: return "SubPlay/Stop"
        case .togglePreview: return "Preview on/off"
        case .repeatPlayback: return "Repeat"
        case .bypass: return "Bypass Multiloops"
        case .playlistUp: return "Previous playlist"
        case .playlistDown: return "Next playlist"
        }
    }
}
private struct RemoteMIDIBinding: Codable, Equatable {
    var device: Int32
    var channel: UInt8
    var status: UInt8
    var number: UInt8
    var label: String
    func matches(_ other: Self) -> Bool { device == other.device && channel == other.channel && status == other.status && number == other.number }
}
@MainActor private final class RemoteMIDIActions: ObservableObject {
    static let shared = RemoteMIDIActions()
    struct Event { let id = UUID(); var action: RemoteMIDIAction? = nil; var blockNumber: Int? = nil }
    struct Transfer: Identifiable {
        let id = UUID()
        let target: String
        let input: RemoteMIDIBinding
        let message: String
    }
    @Published private(set) var bindings: [String: RemoteMIDIBinding] = [:]
    @Published var learning: RemoteMIDIAction?
    @Published private(set) var learningBlock: Int?
    @Published private(set) var candidate: RemoteMIDIBinding?
    @Published private(set) var transfer: Transfer?
    @Published private(set) var event: Event?
    @Published private(set) var error = ""
    @Published private(set) var deviceNames: [String] = []
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var sources: [MIDIEndpointRef: (Int32, String)] = [:]
    private var pressed = Set<String>()
    var smkSourceIDs: Set<Int32> { Set(sources.values.filter { SMK37Protocol.isDeviceName($0.1) }.map { $0.0 }) }
    private init() {
        if let data = UserDefaults.standard.data(forKey: "catlive.remote.midiActions"),
           let value = try? JSONDecoder().decode([String: RemoteMIDIBinding].self, from: data) { bindings = value }
        if bindings["playStop"] == nil { bindings["playStop"] = bindings["play"] ?? bindings["stop"] }
        if bindings["subPlayStop"] == nil { bindings["subPlayStop"] = bindings["subPlay"] }
        let legacy = ["play", "stop", "subPlay"]
        if legacy.contains(where: { bindings[$0] != nil }) {
            legacy.forEach { bindings.removeValue(forKey: $0) }; persist()
        }
    }
    func clear(_ action: RemoteMIDIAction) { bindings.removeValue(forKey: action.rawValue); persist() }
    var isLearning: Bool { learning != nil || learningBlock != nil || transfer != nil }
    private func blockKey(_ number: Int) -> String { "setlistBlock:\(number)" }
    private func blockNumber(_ key: String) -> Int? {
        let prefix = "setlistBlock:"
        guard key.hasPrefix(prefix), let number = Int(key.dropFirst(prefix.count)), number > 0,
              key == blockKey(number) else { return nil }
        return number
    }
    func title(_ key: String) -> String {
        if let number = blockNumber(key) { return String(format: JarasLocalization.string("Block ID %02d"), number) }
        return JarasLocalization.string(RemoteMIDIAction(rawValue: key)?.title ?? key)
    }
    func beginAction(_ action: RemoteMIDIAction) {
        cancelLearning(); learning = action
    }
    func beginBlock(_ number: Int) {
        guard number > 0 else { return }
        cancelLearning(); learningBlock = number; candidate = bindings[blockKey(number)]
    }
    func cancelLearning() {
        learning = nil; learningBlock = nil; candidate = nil; transfer = nil; error = ""
    }
    func cancelTransfer() { transfer = nil; error = "" }
    var hasBlockMapping: Bool { learningBlock.map { bindings[blockKey($0)] != nil } ?? false }
    func removeBlockMapping() {
        guard let number = learningBlock else { return }
        bindings.removeValue(forKey: blockKey(number)); persist(); cancelLearning()
    }
    func saveBlock() {
        guard let number = learningBlock, let candidate, [0x90, 0xb0].contains(candidate.status) else { return }
        save(candidate, to: blockKey(number))
    }
    private func save(_ input: RemoteMIDIBinding, to key: String, replacing: Bool = false) {
        let conflicts = bindings.filter { $0.key != key && $0.value.matches(input) }.map(\.key).sorted()
        if !conflicts.isEmpty && !replacing {
            let names = conflicts.map(title).joined(separator: ", ")
            transfer = Transfer(target: key, input: input,
                message: String(format: JarasLocalization.string("%@ is already mapped to %@. Remove it from that function and use it for %@?"), input.label, names, title(key)))
            return
        }
        bindings = bindings.filter { $0.key == key || !$0.value.matches(input) }
        bindings[key] = input; persist(); cancelLearning()
    }
    func confirmTransfer(_ selected: Transfer? = nil) {
        guard let pending = transfer, let request = selected ?? transfer, request.id == pending.id,
              request.target == learning?.rawValue || request.target == learningBlock.map(blockKey),
              learningBlock == nil || candidate?.matches(request.input) == true else { return }
        save(request.input, to: request.target, replacing: true)
    }
    private func persist() { if let data = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(data, forKey: "catlive.remote.midiActions") } }
    func start() {
        guard client == 0 else { return }
        let status = MIDIClientCreateWithBlock("CatLive Remote Actions" as CFString, &client) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        guard status == noErr else { error = "MIDI initialization failed (\(status))"; return }
        let result = MIDIInputPortCreateWithProtocol(client, "Remote Actions" as CFString, ._1_0, &port) { [weak self] list, context in
            let endpoint = MIDIEndpointRef(UInt(bitPattern: context))
            var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIEventPacket.self)
            var messages: [(UInt8, UInt8, UInt8)] = []
            for _ in 0..<list.pointee.numPackets {
                let words = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
                var index = 0
                while index < Int(packet.pointee.wordCount) {
                    let word = words[index], type = word >> 28
                    if type == 2 { messages.append((UInt8((word >> 16) & 255), UInt8((word >> 8) & 127), UInt8(word & 127))) }
                    index += type == 3 || type == 4 ? 2 : type == 5 || type == 0xd || type == 0xf ? 4 : 1
                }
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
            let received = messages
            Task { @MainActor in for message in received { self?.receive(endpoint, message.0, message.1, message.2) } }
        }
        guard result == noErr else { error = "MIDI input failed (\(result))"; stop(); return }
        error = ""; refresh()
    }
    func stop() {
        for source in sources.keys { MIDIPortDisconnectSource(port, source) }
        sources.removeAll(); deviceNames = []; pressed.removeAll(); cancelLearning(); event = nil
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }
    func refresh() {
        guard port != 0 else { return }
        let available = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
        for source in sources.keys.filter({ !available.contains($0) }) { MIDIPortDisconnectSource(port, source); sources.removeValue(forKey: source); pressed.removeAll() }
        for source in available where sources[source] == nil {
            var id: Int32 = 0; var name: Unmanaged<CFString>?
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            if MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: Int(source))) == noErr {
                sources[source] = (id, name?.takeRetainedValue() as String? ?? "MIDI")
            }
        }
        let names = sources.values.map { $0.1 }.sorted()
        if deviceNames != names { deviceNames = names }
        SMK37Link.shared.remoteInputs(smkSourceIDs)
    }
    private func receive(_ endpoint: MIDIEndpointRef, _ status: UInt8, _ number: UInt8, _ value: UInt8) {
        guard let source = sources[endpoint] else { return }
        if SMK37Link.shared.claims(device: source.0, status: status, number: number) { return }
        let kind = status & 0xf0
        guard [0x80, 0x90, 0xb0, 0xc0].contains(kind) else { return }
        let channel = status & 15, normalized: UInt8 = kind == 0x80 ? 0x90 : kind
        let key = "\(source.0):\(channel):\(normalized):\(number)"
        if kind == 0x80 || (kind != 0xc0 && value == 0) { pressed.remove(key); return }
        guard transfer == nil else { return }
        if learningBlock != nil && kind == 0xc0 { return }
        guard kind == 0xc0 || pressed.insert(key).inserted else { return }
        let input = RemoteMIDIBinding(device: source.0, channel: channel, status: normalized, number: number,
            label: "\(source.1) · CH \(channel + 1) · \(kind == 0xb0 ? "CC" : kind == 0xc0 ? "PC" : "Note") \(number)")
        if learningBlock != nil { candidate = input; error = ""; return }
        if let learning { save(input, to: learning.rawValue); return }
        if let entry = bindings.first(where: { blockNumber($0.key) != nil && $0.value.matches(input) }), let number = blockNumber(entry.key) {
            event = Event(blockNumber: number); return
        }
        if let action = RemoteMIDIAction.allCases.first(where: { bindings[$0.rawValue]?.matches(input) == true }) { event = Event(action: action) }
    }
}
private struct RemoteMIDIActionsView: View {
    @ObservedObject var midi = RemoteMIDIActions.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("MIDI").font(.jarasHeadline)
                BluetoothMIDIConnectionButton { midi.refresh() }
                if midi.deviceNames.isEmpty { Text("No MIDI inputs").foregroundStyle(JarasTheme.secondary) }
                ForEach(Array(midi.deviceNames.enumerated()), id: \.offset) { entry in
                    Label(entry.element, systemImage: "pianokeys").font(.jarasCaption)
                }
                if !midi.error.isEmpty { Text(verbatim: midi.error).foregroundStyle(.red) }
                ForEach(RemoteMIDIAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(LocalizedStringKey(action.title)).font(.jarasSubheadline)
                        Text(verbatim: midi.bindings[action.rawValue]?.label ?? "—").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        HStack {
                            Button(midi.learning == action ? "Cancel" : "Learn MIDI") {
                                if midi.learning == action { midi.cancelLearning() } else { midi.beginAction(action) }
                            }
                            Spacer()
                            Button("Clear") { midi.clear(action) }.disabled(midi.bindings[action.rawValue] == nil)
                        }.buttonStyle(.bordered)
                    }.padding(10).background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(.vertical, 8)
        }.onDisappear { if midi.learning != nil { midi.cancelLearning() } }
            .alert("This control is already mapped.", isPresented: Binding(get: { midi.transfer != nil }, set: { _ in }), presenting: midi.transfer) { request in
                Button("Cancel", role: .cancel) { midi.cancelTransfer() }
                Button("Transfer mapping") { midi.confirmTransfer(request) }
            } message: { request in Text(verbatim: request.message) }
    }
}

private struct RemoteSetlistBlockMappingOverlay: View {
    @ObservedObject private var midi = RemoteMIDIActions.shared
    var body: some View {
        if let number = midi.learningBlock {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.58).ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { midi.cancelLearning() }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Map control").font(.jarasHeadline)
                        Text(verbatim: midi.title("setlistBlock:\(number)"))
                        Text("Press a MIDI note or controller button.").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        Text(verbatim: midi.candidate?.label ?? "—")
                            .font(.jarasSystem(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 6))
                        if midi.hasBlockMapping {
                            Button("Remove mapping", role: .destructive) { midi.removeBlockMapping() }
                        }
                        HStack {
                            Button("Cancel") { midi.cancelLearning() }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("Save") { midi.saveBlock() }.disabled(midi.candidate == nil).keyboardShortcut(.defaultAction)
                        }
                    }.padding(22).frame(width: min(360, max(1, geometry.size.width - 32)))
                        .background { RemoteSurface.panel.clipShape(RoundedRectangle(cornerRadius: 12)) }
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.24)))
                        .buttonStyle(IpadDialogButtonStyle()).foregroundStyle(JarasTheme.text)
                        .tint(JarasTheme.green).shadow(radius: 16)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }.accessibilityAddTraits(.isModal)
                .alert("This control is already mapped.", isPresented: Binding(get: { midi.transfer != nil }, set: { _ in }), presenting: midi.transfer) { request in
                    Button("Cancel", role: .cancel) { midi.cancelTransfer() }
                    Button("Transfer mapping") { midi.confirmTransfer(request) }
                } message: { request in Text(verbatim: request.message) }
        }
    }
}

private struct NativeRemoteSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jaras.language") private var language = "en"
    @State private var tab = "general"
    var observer = false
    @AppStorage("jaras.remote.observer.setlistScale") private var observerScale = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Configurações", systemImage: "gearshape").font(.jarasHeadline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Close")
            }
            if !observer {
            Picker("Settings", selection: $tab) {
                Text("General").tag("general")
                Text("Actions").tag("actions")
            }.pickerStyle(.segmented)
            }
            if !observer && tab == "actions" { RemoteMIDIActionsView().frame(height: 430) }
            else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Language").font(.jarasSubheadline.weight(.semibold))
                Picker("Language", selection: $language) {
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Português").tag("pt-BR")
                }.pickerStyle(.segmented).labelsHidden()
                if observer {
                    HStack {
                        Text(verbatim: language.hasPrefix("pt") ? "Escala do Setlist" : "Setlist scale")
                        Spacer()
                        Text(verbatim: "\(Int(observerScale * 100))%").monospacedDigit()
                    }.padding(.top, 10)
                    Slider(value: $observerScale, in: 1...2.5, step: 0.1).tint(JarasTheme.green)
                }

            }
            }
        }.padding(20).frame(width: 320).background(RemoteSurface.panel).foregroundStyle(JarasTheme.text)
            .environment(\.locale, Locale(identifier: language))
    }
}

private struct IpadNativeItemMix: Equatable {
    let project: UUID
    let song: UUID
    let items: Set<UUID>
    let parameter: IpadItemMixParameter
    let value: Double
    func applying(to source: Song) -> Song {
        guard source.id == song else { return source }
        var song = source
        for t in song.tracks.indices {
            for c in song.tracks[t].clips.indices where items.contains(song.tracks[t].clips[c].id) {
                if parameter == .gain { song.tracks[t].clips[c].gain = value }
                else { song.tracks[t].clips[c].pan = value }
            }
        }
        return song
    }
}

private struct IpadNativeItemMove: Equatable {
    let items: Set<UUID>
    let anchor: UUID
    let start: Double
    let track: UUID
}

// The document geometry is independent of the zoom and playback viewport.
// Retain one snapshot, including live edit previews, instead of sorting every
// region and overlap component again in each SwiftUI/Canvas evaluation.
private final class IpadTimelineContentCache {
    struct Key: Equatable {
        let project: UUID; let song: UUID?; let revision: UInt64
        let region: IpadRegionMovePreview?
        let markerID: UUID?; let markerPosition: Double?
        let move: IpadNativeItemMove?; let mix: IpadNativeItemMix?
    }
    private var key: Key?
    private var retained: IpadTimelineContent?
    func value(_ key: Key, build: () -> Song?) -> IpadTimelineContent? {
        if self.key == key { return retained }
        retained = build().map(IpadTimelineContent.init)
        self.key = key
        return retained
    }
}
private final class IpadTimelineContent {
    let song: Song
    let lanes: RegionLanes
    let roots: [Part]
    let regionIndex: TimelineVisibleClipIndex
    private lazy var tempoSections = song.tempoSections(until: song.duration)
    lazy var rulerSections = song.tempoSections(until: song.timelineScrollEnd)
    let markerEnds: [UUID: Double]
    let tracks: [UUID: Track]
    private var layouts: [UUID: IpadTimelineTrackContent] = [:]
    init(_ song: Song) {
        self.song = song; lanes = RegionLanes(parts: song.parts)
        roots = song.parts.filter { $0.parentRegionID == nil }
        regionIndex = TimelineVisibleClipIndex(intervals: roots.map { ($0.startTime, $0.endTime) })
        markerEnds = song.markerRegionEnds
        tracks = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, $0) })
    }
    func regions(from start: Double, through end: Double) -> [Part] {
        regionIndex.indices(from: start, through: end).map { roots[$0] }
    }
    func track(_ id: UUID) -> IpadTimelineTrackContent? {
        if let cached = layouts[id] { return cached }
        guard let track = tracks[id] else { return nil }
        let result = IpadTimelineTrackContent(track, tempoSections: tempoSections)
        layouts[id] = result
        return result
    }
}
private final class IpadTimelineTrackContent {
    let track: Track
    let lanes: TrackLanes
    let clips: [UUID: AudioClip]
    let tempoSections: [TimelineTempoSection]
    private let index: TimelineVisibleClipIndex
    private var fragments: [UUID: [AudioClip]] = [:]
    private let media = TimelineMediaURLCache()

    init(_ track: Track, tempoSections: [TimelineTempoSection]) {
        self.track = track
        self.tempoSections = tempoSections
        lanes = TrackLanes(track: track)
        clips = Dictionary(uniqueKeysWithValues: track.clips.map { ($0.id, $0) })
        index = TimelineVisibleClipIndex(intervals: track.clips.map { ($0.startTime, $0.startTime + $0.duration) })
    }
    func visibleClips(from start: Double, to end: Double) -> [AudioClip] {
        index.indices(from: start, through: end).compactMap {
            let clip = track.clips[$0]
            return clip.startTime < end && clip.startTime + clip.duration > start ? clip : nil
        }
    }
    func segments(_ clip: AudioClip, song: Song) -> [AudioClip] {
        if let cached = fragments[clip.id] { return cached }
        let covered = (tempoSections.last?.end ?? 0) >= clip.startTime + clip.duration
        let result = song.tempoAudioSegments(clip, sections: covered ? tempoSections : nil)
        fragments[clip.id] = result
        return result
    }
    func source(_ clip: AudioClip, directory: URL) -> TimelineMediaURLCache.Source? {
        guard !clip.isImage, let file = clip.audioFile ?? track.audioFile else { return nil }
        return media.resolveSource(file.path, directory: directory)
    }
}

/// The center grid renders native clip geometry from the Mac state.
private enum RemoteNativeGridMetrics {
    static let regionHeight: CGFloat = 24
    static let markerHeight: CGFloat = 20
    static let timeHeight = TimelineHeaderBands(regionRows: 0, showRegions: false, showTempo: false).rulerHeight
    static let rulerAreaHeight = regionHeight + markerHeight + timeHeight + 2
    static func regionHeight(local: Bool) -> CGFloat { local ? 16 : regionHeight }
    static func markerHeight(local: Bool) -> CGFloat { local ? 16 : markerHeight }
    static func minimumTrackHeight(local: Bool) -> Double { local ? TrackHeightGeometry.minimumLaneHeight : 70 }
}
private struct RemoteOutputPatchRequest: Identifiable {
    let id = UUID()
    let project: UUID
    let song: UUID?
    let track: UUID?
    let name: String
    let channels: Int?
    let hasGroup: Bool
    let routes: [OutputPatch]?
}

private struct RemoteOutputPatchSheet: View {
    let request: RemoteOutputPatchRequest
    let apply: ([OutputPatch]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var routes: [OutputPatch]

    init(request: RemoteOutputPatchRequest, apply: @escaping ([OutputPatch]) -> Void) {
        self.request = request; self.apply = apply
        _routes = State(initialValue: request.routes ?? [])
    }

    var body: some View {
        let choices = OutputPatch.choices(channels: max(0, min(1024, request.channels ?? 0)),
            includeMaster: request.track != nil, includeGroup: request.hasGroup, includeNone: true)
        return NavigationStack {
            Form {
                if request.channels != nil && request.routes != nil {
                    ForEach(routes.indices, id: \.self) { index in
                        HStack {
                            Picker("Output", selection: $routes[index]) {
                                if !choices.contains(routes[index]) { Text(routes[index].title).tag(routes[index]) }
                                ForEach(choices, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                            }
                            Button(role: .destructive) { routes.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove output")
                        }
                    }
                    Button("Add output") { routes.append(.none) }.disabled(routes.count >= 64)
                } else {
                    Text("Update CatLive on the connected computer to edit outputs.")
                }
            }.navigationTitle(Text(verbatim: request.name.isEmpty ? "Patch" : "Patch · " + request.name))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    if request.routes != nil && request.channels != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Apply") { apply(routes); dismiss() }
                        }
                    }
                }
        }
    }
}

private struct RemoteNativeTimeline: View {
    @TimelineColor(.background) private var localBackgroundColor
    @TimelineColor(.verticalGrid) private var localVerticalColor
    @TimelineColor(.horizontalGrid) private var localHorizontalColor
    @AppStorage("jaras.timeline.invertWaveformColors") private var invertWaveformColors = false
    @AppStorage("jaras.ipad.transport.proMode") private var nativeProMode = false
    @AppStorage("jaras.timeline.proTool") private var proTool = ProGridTool.select
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var controlsEnabled
    @State private var volumeItem: UUID?
    @State private var volumePreview: Double?
    @ObservedObject private var trackVisibility = TrackVisibilityPreferences.shared
    let state: DAWRemoteState
    let tracks: [DAWRemoteState.Track]
    @ObservedObject var scrolling: RemoteTrackScrollController
    let region: DAWRemoteState.Region?
    let position: Double
    var local = false
    var localShow: ShowController? = nil
    var timelineFocus: IpadTimelineFocus? = nil
    var editorEnabled = true
    var touchItemEditing = false
    var showRegionLanes = true
    var showTempoLane = true
    @Binding var regionDrag: IpadRegionMovePreview?
    var openRegionActions: ((UUID) -> Void)? = nil
    @State private var selectedRegionID: UUID?
    var openItemMenu: ((UUID) -> Void)? = nil
    var openSelectedItemMenu: ((UUID, Set<UUID>) -> Void)? = nil
    var openItemFX: ((UUID) -> Void)? = nil
    @State private var contentCache = IpadTimelineContentCache()
    @State private var snapTiming = TimelineScrollEndCache()
    @State private var viewport = IpadTimelineViewport()
    @State private var retainedWindow: IpadTimelineRenderWindow?
    @State private var playbackControl = IpadTimelinePlaybackControl()
    @State private var itemHeadersHidden = false
    @AppStorage("jaras.timeline.continuousScroll") private var continuousScroll = true
    @State private var rulerDrag = IpadTimelineRulerDrag()
    @ObservedObject private var timeSelection = TimelineAreaSelection.shared
    @State private var rulerPointerViewport: IpadTimelineViewport?
    @State private var rulerVisibleViewport: IpadTimelineViewport?
    @State private var rulerSelectionAnchor: Double?
    @GestureState private var markerPreview: (id: UUID, position: Double)?
    @State private var rulerSelectionEnd: Double?
    @State private var selectionResizeFixedEdge: Double?
    @State private var gestureControl = IpadTimelineGestureControl()
    // Use the desktop controller's navigation pause, not an independent UI flag.
    private var followsPlayback: Bool { localShow?.timelineFollowPaused != true }
    @State private var pointerStart: (project: UUID, song: Song, item: UUID?, time: Double, point: CGPoint, selection: TimelinePointerSelection)?
    @State private var pointerDragged = false
    @State private var drawingMIDI = false
    @State private var selectionRectangle: CGRect?
    var openMarkerEditor: ((TimelineMarker) -> Void)? = nil
    @Environment(\.nativeGridFileDrop) private var nativeGridFileDrop
    var regionCommand: ((UUID, String) -> Void)? = nil
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    let preview: (Double) -> Void
    let seek: (Double) -> Void
    var rulerSeek: ((Double) -> Void)? = nil
    private var renderWindow: IpadTimelineRenderWindow {
        if let retainedWindow, retainedWindow.span == viewport.span * 2 { return retainedWindow }
        return IpadTimelineRenderWindow(viewport)
    }
    private var start: Double { local ? renderWindow.start : region?.start ?? 0 }
    private var end: Double { local ? renderWindow.start + renderWindow.span : region?.end ?? start }
    private var span: Double { local ? renderWindow.span : max(0.001, end - start) }
    private var zoomCursor: Double {
        if let show = localShow { return show.timelineZoomPosition }
        if state.subPlaying { return state.subPlayPosition ?? position }
        if state.playing { return position }
        return state.editPosition ?? position
    }
    private var nativeContent: IpadTimelineContent? {
        guard local, let show = localShow else { return nil }
        return contentCache.value(.init(project: state.project, song: show.current?.id,
            revision: show.projectRevision, region: regionDrag, markerID: markerPreview?.id,
            markerPosition: markerPreview?.position, move: scrolling.itemMove, mix: scrolling.itemMix)) { makePresentationSong() }
    }
    private var presentationSong: Song? { nativeContent?.song }
    private var snapRulerSections: [TimelineTempoSection]? {
        guard local, let show = localShow, let song = show.current else { return nil }
        return snapTiming.sections(for: song, project: show.snapshot.project.id, revision: show.projectRevision)
    }
    private func makePresentationSong() -> Song? {
        guard let song = localShow?.current else { return nil }
        var preview = regionDrag.map { song.previewMovingRegion($0.id, to: $0.start) } ?? song
        if let markerPreview, let index = preview.markers?.firstIndex(where: { $0.id == markerPreview.id }) {
            preview.markers?[index].position = markerPreview.position
        }
        if let move = scrolling.itemMove {
            preview = preview.movingItems(move.items, anchor: move.anchor, start: move.start, track: move.track) ?? preview
        }
        return scrolling.itemMix?.applying(to: preview) ?? preview
    }
    private var regionLaneCount: Int { nativeContent?.lanes.count ?? 1 }
    private var nativeBands: TimelineHeaderBands {
        TimelineHeaderBands(regionRows: regionLaneCount, showRegions: showRegionLanes, showTempo: showTempoLane)
    }
    private var regionAreaHeight: CGFloat {
        local ? CGFloat(regionLaneCount) * RemoteNativeGridMetrics.regionHeight(local: true) : RemoteNativeGridMetrics.regionHeight
    }
    private var rulerHeight: CGFloat { local ? nativeBands.height : RemoteNativeGridMetrics.rulerAreaHeight }
    private var timeRulerHeight: CGFloat { local ? nativeBands.rulerHeight : RemoteNativeGridMetrics.timeHeight }
    private var showsVerticalGrid: Bool { state.gridLines != false && (!local || gridDivisions != 0) }
    private var gridDivisions: Int { localShow?.current?.projectTime.divisions ?? state.gridDivisions ?? 4 }
    private var gridTop: CGFloat { rulerHeight + (local ? 0 : 1) }
    private func visibleMarkers(song: Song?) -> [TimelineMarker] {
        let markers = song?.markers ?? (state.markers ?? []).map {
            TimelineMarker(id: $0.id, name: $0.name, position: $0.position, color: $0.color,
                unifiedRegionID: $0.unifiedRegionID, sourceRegionID: $0.sourceRegionID, section: $0.section, loopSection: $0.loopSection)
        }
        return markers.filter { !$0.isTempo && $0.position >= start && $0.position <= end }.sorted { $0.position < $1.position }
    }
    private var highlightedTimeRange: ClosedRange<Double>? {
        if let anchor = rulerSelectionAnchor {
            guard let end = rulerSelectionEnd, end != anchor else { return nil }
            return min(anchor, end)...max(anchor, end)
        }
        if local, let range = timeSelection.range, range.song == state.song { return range.start...range.end }
        if state.loop, let start = state.loopStart, let end = state.loopEnd, end > start { return start...end }
        return nil
    }
    private func adoptVisibleViewport() {
        if let visible = playbackControl.visibleStart { viewport.start = visible }
    }
    private func visibleWidth(_ width: Double) -> Double { local ? width * viewport.span / span : width }
    private func visibleLeft(_ width: Double) -> Double {
        ((playbackControl.visibleStart ?? viewport.start) - start) / span * width
    }
    private func pauseFollowing() {
        adoptVisibleViewport(); itemHeadersHidden = false; gestureControl.cancelMotion(); localShow?.pauseTimelineFollow()
    }
    private func pauseScrollFollowing() {
        if localShow?.timelineFollowPaused != true { adoptVisibleViewport() }
        if itemHeadersHidden { itemHeadersHidden = false }
        localShow?.pauseTimelineFollow(resumingAfter: 5)
    }
    private var volumeClip: DAWRemoteState.Clip? {
        guard !local, controlsEnabled, let volumeItem else { return nil }
        return tracks.lazy.flatMap(\.clips).first { $0.id == volumeItem }
    }
    private func closeVolume() { volumeItem = nil; volumePreview = nil }
    private func trackWithVolumePreview(_ source: DAWRemoteState.Track) -> DAWRemoteState.Track {
        guard !local, let volumeItem, let volumePreview,
              let index = source.clips.firstIndex(where: { $0.id == volumeItem }) else { return source }
        var track = source
        track.clips[index].gain = volumePreview
        return track
    }
    var body: some View {
        GeometryReader { geometry in
            let gutter = local ? TimelineVerticalBar.width : 0
            let size = CGSize(width: max(1, geometry.size.width - gutter), height: max(0, geometry.size.height))
            HStack(spacing: 0) {
                Group {
                    if local, let localShow {
                        IpadTimelinePlaybackSurface(control: playbackControl, show: localShow,
                            viewport: viewport, window: renderWindow, size: size,
                            gridTop: gridTop, timeHeight: nativeBands.tickHeight,
                            follow: continuousScroll,
                            colors: [state.playCursorColor ?? UInt32(TimelineAppearanceDefaults.playCursor),
                                     state.editCursorColor ?? UInt32(TimelineAppearanceDefaults.editCursor),
                                     UInt32(TimelineAppearanceDefaults.subPlayCursor)],
                            rebase: { retainedWindow = IpadTimelineRenderWindow($0) },
                            scrollingChanged: { itemHeadersHidden = $0 }) {
                                timelineContent(width: size.width * span / viewport.span, height: size.height)
                            }
                    } else { timelineContent(width: size.width, height: size.height) }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .onDrop(of: [UTType.fileURL, .catLiveLyrics, LibrarySamplerTransfer.type], isTargeted: nil) { providers, location in
                    guard local, let nativeGridFileDrop, location.y >= gridTop else { return false }
                    let left = playbackControl.visibleStart ?? viewport.start
                    let time = max(0, left + Double(location.x / size.width) * viewport.span)
                    let sample = providers.allSatisfy { $0.hasItemConformingToTypeIdentifier(LibrarySamplerTransfer.type.identifier) }
                    let documentY = location.y - gridTop + (scrolling.gridScrollView?.contentOffset.y ?? 0)
                    return nativeGridFileDrop(providers, time, sample ? pointerTrack(at: documentY) : nil)
                }
                .background {
                    if local {
                        IpadTimelineGestureProbe(control: gestureControl, verticalScroll: { scrolling.gridScrollView },
                            pan: { translation, width in
                                pauseScrollFollowing(); viewport.pan(pixels: translation, width: width)
                            }, zoom: { scale, _ in
                                pauseScrollFollowing(); viewport.zoom(factor: scale, centeredOn: zoomCursor)
                            })
                    }
                }
                if local {
                    TimelineTouchScrollBar(connection: scrolling.timelineBar, move: scrolling.setGridOffset)
                        .frame(width: gutter, height: max(0, size.height - gridTop))
                        .padding(.top, gridTop)
                }
            }
            .onAppear {
                if local { viewport.resizeLeadingSpace(TimelineAppearanceDefaults.leadingSpace, width: size.width) }
            }
            .onChange(of: size.width) { width in
                if local {
                    viewport.resizeLeadingSpace(TimelineAppearanceDefaults.leadingSpace, width: width)
                    retainedWindow = IpadTimelineRenderWindow(viewport)
                }
            }
        }.clipped().background(remoteColor(local ? UInt32(localBackgroundColor) :
            state.gridBackgroundColor ?? UInt32(TimelineThemeColor.background.defaultColor(for: .current))))
            // Keep the presenter outside the cached/lazy item rows. Receiving
            // a new gain, mute or transport state must not recreate its owner.
            .background {
                if !local {
                    RemoteItemEditorPresentation(clip: volumeClip,
                        color: tracks.first(where: { $0.clips.contains(where: { $0.id == volumeItem }) })?.color ?? 0,
                        setGain: { gain in
                            guard let volumeItem else { return }
                            volumePreview = gain
                            control(.clipGain, volumeItem, gain)
                        }, mute: {
                            if let volumeItem { control(.clipMute, volumeItem, 0) }
                        }, close: closeVolume).frame(width: 0, height: 0)
                }
            }
            .onChange(of: volumeClip?.id) { if $0 == nil { closeVolume() } }
            .onChange(of: volumeClip?.gain) { gain in
                if gain == volumePreview { volumePreview = nil }
            }
            .onChange(of: controlsEnabled) { if !$0 { closeVolume() } }
            .task(id: volumePreview) {
                guard volumePreview != nil else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                volumePreview = nil
            }
            .onAppear {
                scrolling.pointerEditing = local
                scrolling.manualGridScroll = local ? { pauseScrollFollowing() } : nil
                if local { viewport.reset(duration: state.duration); viewport.center(on: zoomCursor); retainedWindow = IpadTimelineRenderWindow(viewport) }
            }
            .onDisappear { scrolling.manualGridScroll = nil; scrolling.pointerEditing = false; cancelPointer(); cancelItemMix() }
            .onChange(of: scrolling.pointerReset) { _ in cancelPointer(); cancelItemMix() }
            .onChange(of: state.project) { _ in cancelPointer(); cancelItemMix(); closeVolume() }
            .onChange(of: localShow?.timelineActiveLockOptions) { options in if options != 0 { cancelPointer() } }
            .onChange(of: timelineFocus) { request in
                if local, let request { gestureControl.cancelMotion(); viewport.center(on: request.position); playbackControl.controller?.navigate(to: viewport) }
            }
            .onChange(of: state.song) { _ in
                cancelPointer(); cancelItemMix(); closeVolume(); scrolling.pointerReset = UUID()
                if local { gestureControl.cancelMotion(); viewport.reset(duration: state.duration); viewport.center(on: timelineFocus?.position ?? zoomCursor); retainedWindow = IpadTimelineRenderWindow(viewport) }
            }
            .onChange(of: viewport) { next in
                if retainedWindow?.needsRebase(next) != false { retainedWindow = IpadTimelineRenderWindow(next) }
            }
            .onChange(of: continuousScroll) { enabled in if !enabled { itemHeadersHidden = false } }
            .onChange(of: state.playing) { playing in if !playing { itemHeadersHidden = false } }
            .accessibilityAction(named: Text("Zoom in")) { if local { viewport.zoom(factor: 1.5, centeredOn: zoomCursor) } }
            .accessibilityAction(named: Text("Zoom out")) { if local { viewport.zoom(factor: 1 / 1.5, centeredOn: zoomCursor) } }
    }
    private var minimumTrackRowHeight: Double { RemoteNativeGridMetrics.minimumTrackHeight(local: local) }
    private func timelineContent(width: Double, height: Double) -> some View {
            let song = presentationSong
            let markers = visibleMarkers(song: song)
            let marks = gridMarks(width: width)
            let heights = tracks.map { CGFloat(DAWRemoteItemLayout.rowHeight($0, scale: scrolling.heightScale, minimum: minimumTrackRowHeight)) }
            let rowsHeight = max(0, heights.reduce(0, +) + CGFloat(tracks.count - 1))
            let pinnedTrack = scrolling.selectedItem.flatMap { item in
                tracks.first(where: { $0.clips.contains { $0.id == item } })?.id
            }
            return VStack(spacing: local ? 0 : 1) {
                if !local || showRegionLanes {
                    regionLane(width: width, song: song)
                    markerLane(width: width, markers: markers, song: song)
                }
                if local && showTempoLane { tempoLane(width: width, song: song) }
                ruler(width: width, marks: marks, song: song)
                ScrollView(.vertical, showsIndicators: !local) {
                    Group {
                        if local {
                            IpadRecycledTrackRows(ids: tracks.map(\.id), heights: heights, retained: { pinnedTrack }) { index in
                                timelineRow(tracks[index], width: width, nativeSong: song)
                            }.frame(width: width, height: rowsHeight)
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(tracks) { track in
                                    timelineRow(track, width: width, nativeSong: song)
                                        .frame(height: DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale, minimum: minimumTrackRowHeight))
                                }
                            }
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1 / displayScale).allowsHitTesting(false)
                    }
                    .frame(height: max(max(0, height - gridTop), rowsHeight), alignment: .top)
                    .overlay(alignment: .topLeading) {
                        if let rectangle = selectionRectangle {
                            Rectangle().fill(JarasTheme.green.opacity(0.16))
                                .overlay(Rectangle().stroke(JarasTheme.green, lineWidth: 1))
                                .frame(width: rectangle.width, height: rectangle.height)
                                .offset(x: rectangle.minX, y: rectangle.minY).allowsHitTesting(false)
                        }
                    }
                    .background {
                        if local {
                            IpadTimelinePointerProbe(enabled: editorEnabled && localShow?.canControl() == true,
                                acceptsTouch: touchItemEditing && localShow?.timelineItemsLocked == false ? { point in
                                    guard !scrolling.itemSelection.items.isEmpty,
                                          let item = pointerItems(width: width).first(where: { $0.rect.contains(point) }) else { return false }
                                    return scrolling.itemSelection.items.contains(item.id)
                                } : nil, touchTap: nativeProMode && proTool != .select ? { point in
                                    guard let item = pointerItems(width: width).first(where: { $0.rect.contains(point) }) else { return false }
                                    applyProTool(item.id, time: start + Double(point.x / max(1, width)) * span, width: width)
                                    return true
                                } : nil, reset: scrolling.pointerReset, accepts: { point in
                                    return true
                                }, wantsAutoScroll: { point in
                                    guard pointerDragged else { return false }
                                    let left = visibleLeft(width)
                                    if point.x < left + 20 || point.x > left + visibleWidth(width) - 20 { return true }
                                    guard let scroll = scrolling.gridScrollView else { return false }
                                    let y = point.y - scroll.contentOffset.y
                                    return y < 24 || y > scroll.bounds.height - 24
                                }, event: { handlePointer($0, width: width) }, wheel: { delta, modifiers in
                                    handleWheel(delta, modifiers: modifiers, width: width)
                                })
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: scrolling, tracks: tracks,
                        selectedTrack: localShow?.selectedTrackForActions ?? scrolling.heightSelectedTrack, isGrid: true, twoFingerScroll: local, gridTap: { fraction in
                        guard local || (!state.playing && region != nil) else { return }
                        if local { localShow?.selectProgramChange(nil) }
                        let time = start + fraction * span
                        if local, let song {
                            seek(TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
                                enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
                                includeItemEdges: true, rulerSections: snapRulerSections))
                        } else { seek(time) }
                    }))
                    #endif
                }.background {
                    if showsVerticalGrid {
                        GeometryReader { grid in
                            TimelineRetainedGrid(
                                primary: marks.filter(\.drawsInGrid).map { gridX($0.time, width: grid.size.width) },
                                secondary: [],
                                primaryColor: remoteColor(local ? UInt32(localVerticalColor) :
                                    state.gridPrimaryColor ?? UInt32(TimelineThemeColor.verticalGrid.defaultColor(for: .current))),
                                secondaryColor: remoteColor(state.gridSecondaryColor ?? UInt32(TimelineAppearanceDefaults.secondaryGrid)),
                                displayScale: displayScale, strokeWidth: TimelineVerticalInk.pixels, dashed: false)
                        }.allowsHitTesting(false)
                    }
                }
            }.overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let selectionTop = rulerHeight - timeRulerHeight
                        if let anchor = rulerSelectionAnchor, anchor >= start, anchor <= end {
                            let x = (anchor - start) / span * size.width
                            var line = Path(); line.move(to: CGPoint(x: x, y: selectionTop)); line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line, with: .color(JarasTheme.yellow), lineWidth: 1 / displayScale)
                        }
                        if let range = highlightedTimeRange {
                            let left = (range.lowerBound - start) / span * size.width
                            let right = (range.upperBound - start) / span * size.width
                            if right > left {
                                let rect = CGRect(x: left, y: selectionTop, width: right - left, height: max(0, size.height - selectionTop))
                                context.fill(Path(rect), with: .color(.white.opacity(0.12)))
                                let head = min(12.0, (right - left) / 2)
                                var borders = Path()
                                for x in [left, right] {
                                    borders.move(to: CGPoint(x: x, y: selectionTop)); borders.addLine(to: CGPoint(x: x, y: size.height))
                                }
                                borders.move(to: CGPoint(x: left, y: selectionTop + 10)); borders.addLine(to: CGPoint(x: right, y: selectionTop + 10))
                                borders.move(to: CGPoint(x: left, y: selectionTop))
                                borders.addLine(to: CGPoint(x: left + head, y: selectionTop))
                                borders.addLine(to: CGPoint(x: left, y: selectionTop + 12)); borders.closeSubpath()
                                borders.move(to: CGPoint(x: right, y: selectionTop))
                                borders.addLine(to: CGPoint(x: right - head, y: selectionTop))
                                borders.addLine(to: CGPoint(x: right, y: selectionTop + 12)); borders.closeSubpath()
                                context.stroke(borders, with: .color(JarasTheme.yellow), lineWidth: 1 / displayScale)
                            }
                        }
                        if local && showRegionLanes {
                            let content = nativeContent
                            for region in content?.regions(from: start, through: end) ?? [] {
                                var borders = Path()
                                let headerBottom = CGFloat((content?.lanes.lanes[region.id] ?? 0) + 1) * RemoteNativeGridMetrics.regionHeight(local: local)
                                for time in [region.startTime, region.endTime] where time >= start && time <= end {
                                    let x = gridX(time, width: size.width)
                                    borders.move(to: CGPoint(x: x, y: headerBottom))
                                    borders.addLine(to: CGPoint(x: x, y: size.height))
                                }
                                context.stroke(borders, with: .color(remoteColor(region.color ?? 0x705264)), lineWidth: TimelineVerticalInk.width(at: displayScale))
                            }
                        }
                        if local, showTempoLane, let song {
                            var tempoStems = Path()
                            for marker in song.markers ?? [] where marker.isTempo && marker.position >= start && marker.position <= end {
                                let x = gridX(marker.position, width: size.width)
                                tempoStems.move(to: CGPoint(x: x, y: nativeBands.numberTop))
                                tempoStems.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            context.stroke(tempoStems, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: TimelineVerticalInk.width(at: displayScale), dash: [2, 3]))
                        }
                        if !local || showRegionLanes {
                            let markerBottom = local ? nativeBands.tempoTop : regionAreaHeight + RemoteNativeGridMetrics.markerHeight + 1
                            for marker in markers {
                                let x = gridX(marker.position, width: size.width)
                                var stem = Path()
                                stem.move(to: CGPoint(x: x, y: markerBottom))
                                stem.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(stem, with: .color(remoteColor(marker.color).opacity(marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)), lineWidth: TimelineVerticalInk.width(at: displayScale))
                            }
                        }
                    }
                    if local {
                        Canvas { context, size in
                            var boundaries = Path()
                            for y in nativeBands.separators {
                                boundaries.move(to: CGPoint(x: 0, y: y))
                                boundaries.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(boundaries, with: .color(JarasTheme.timelineHeaderLine), lineWidth: 1)
                        }.frame(height: rulerHeight)
                    }
                    // Needles stay above coincident marker stems, as on the Mac.
                    if !local { cursor(width: width)
                        .frame(width: width, height: max(0, height - gridTop), alignment: .topLeading)
                        .offset(y: gridTop)
                    }
                }.clipped().allowsHitTesting(false)
            }
            .frame(width: width, height: max(0, height), alignment: .topLeading)
            .clipped()
    }
    private func pointerItems(width: CGFloat) -> [(id: UUID, track: UUID, rect: CGRect)] {
        var rows: [(UUID, UUID, CGRect)] = []
        var y: CGFloat = 0
        let song = presentationSong
        for track in tracks {
            let geometry = IpadNativeItemGeometry(track: local ? song?.tracks.first(where: { $0.id == track.id }) : nil,
                remoteTrack: track, scale: scrolling.heightScale, minimumRowHeight: minimumTrackRowHeight)
            for clip in track.clips where clip.start < end && clip.start + clip.duration > start {
                let left = max(start, clip.start), right = min(end, clip.start + clip.duration)
                rows.append((clip.id, track.id, CGRect(x: (left - start) / span * width,
                    y: y + geometry.offset(clip.id, fallbackLane: clip.lane ?? 0), width: (right - left) / span * width, height: geometry.height(clip.id))))
            }
            y += DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale, minimum: minimumTrackRowHeight) + 1
        }
        return rows
    }
    private func pointerTrack(at y: CGFloat) -> UUID? {
        var top: CGFloat = 0
        for track in tracks {
            let height = DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale, minimum: minimumTrackRowHeight)
            if y >= top && y <= top + height { return track.id }
            top += height + 1
        }
        return nil
    }
    private func cancelPointer() {
        pointerStart = nil; pointerDragged = false; drawingMIDI = false; selectionRectangle = nil; scrolling.itemMove = nil
    }
    private func handlePointer(_ event: IpadTimelinePointerEvent, width: CGFloat) {
        guard local, let show = localShow, let song = show.current else { return }
        scrolling.modifiers = event.modifiers
        let time = max(0, start + Double(event.position.x / max(1, width)) * span)
        if event.phase == .began {
            show.selectProgramChange(nil)
            pauseFollowing(); scrolling.selectionScope = .grid
            let item = pointerItems(width: width).first { $0.rect.contains(event.position) }?.id
            if event.direct {
                guard touchItemEditing, let item, scrolling.itemSelection.items.contains(item) else { return }
            }
            pointerStart = (show.snapshot.project.id, song, item, time, event.position, scrolling.itemSelection)
            pointerDragged = false
            drawingMIDI = item == nil && !event.secondary && !event.modifiers.intersection([.command, .control]).isEmpty
            if !event.secondary {
                scrolling.itemSelection.begin(item, additive: !event.modifiers.intersection([.command, .control]).isEmpty)
            }
            return
        }
        guard let initial = pointerStart, initial.project == show.snapshot.project.id, initial.song.id == song.id else {
            cancelPointer(); return
        }
        if event.phase == .cancelled { scrolling.itemSelection = initial.selection; cancelPointer(); return }
        if event.distance >= 3 { pointerDragged = true }
        if nativeProMode && !event.secondary && proTool != .select {
            if event.phase == .ended {
                if !pointerDragged, let id = initial.item { applyProTool(id, time: initial.time, width: width) }
                cancelPointer()
            }
            return
        }
        if pointerDragged, nativeProMode, event.secondary {
            if !TrackRecording.shared.recording && !TrackRecording.shared.countingIn {
                let enabled = TimelineSnapPreference.enabled && !event.modifiers.contains(.shift)
                let from = TimelineTempo.snap(initial.time, song: song, pixelsPerSecond: width / span,
                    enabled: enabled, includeItemEdges: true, rulerSections: snapRulerSections)
                let to = TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
                    enabled: enabled, includeItemEdges: true, rulerSections: snapRulerSections)
                TimelineAreaSelection.shared.update(song: song.id, from: from, to: to)
                show.updateActiveLoopArea()
            }
        } else if pointerDragged, !drawingMIDI && (event.secondary || (nativeProMode && initial.item == nil)) {
            let firstX = (initial.time - start) / span * width
            let rectangle = CGRect(x: min(firstX, event.position.x), y: min(initial.point.y, event.position.y),
                width: abs(firstX - event.position.x), height: abs(initial.point.y - event.position.y))
            selectionRectangle = rectangle
            var ids = Set(pointerItems(width: width).filter { $0.rect.intersects(rectangle) }.map(\.id))
            if !event.modifiers.intersection([.command, .control, .shift]).isEmpty { ids.formUnion(initial.selection.items) }
            if scrolling.itemSelection.items != ids { scrolling.itemSelection.replace(ids) }
        } else if pointerDragged, drawingMIDI, !show.timelineItemsLocked {
            selectionRectangle = CGRect(x: min((initial.time - start) / span * width, event.position.x), y: initial.point.y - 10,
                width: abs((initial.time - time) / span * width), height: 20)
        } else if pointerDragged, let anchor = initial.item, !show.timelineItemsLocked,
                  let original = initial.song.tracks.flatMap(\.clips).first(where: { $0.id == anchor }),
                  let target = pointerTrack(at: event.position.y) {
            if !pointerDragged || scrolling.itemSelection.anchor != anchor || !scrolling.itemSelection.items.contains(anchor) { scrolling.itemSelection.beginDrag() }
            let ids = scrolling.itemSelection.items
            let transport = show.snapshot.transport
            let proposed = original.startTime + time - initial.time
            let snapped = TimelineTempo.snap(proposed, song: initial.song, pixelsPerSecond: width / span,
                cursor: transport.editPosition ?? transport.position,
                enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift),
                otherCursors: [transport.position] + (transport.subPlay.playing ? [transport.subPlay.position] : []),
                includeItemEdges: true, excludingItems: ids, maximumDistancePixels: 8, rulerSections: snapRulerSections)
            let move = IpadNativeItemMove(items: ids, anchor: anchor, start: snapped, track: target)
            if scrolling.itemMove != move {
                scrolling.itemMove = initial.song.movingItems(ids, anchor: anchor, start: snapped, track: target) != nil ? move : nil
            }
        } else if pointerDragged { scrolling.itemMove = nil }
        if event.phase == .ended {
            if event.secondary {
                if !pointerDragged, let item = initial.item {
                    if !scrolling.itemSelection.items.contains(item) { scrolling.itemSelection.replace([item]) }
                    if let openSelectedItemMenu { openSelectedItemMenu(item, scrolling.itemSelection.items) }
                    else { openItemMenu?(item) }
                }
            } else {
                if let move = scrolling.itemMove, pointerDragged {
                    show.moveItems(move.items, anchor: move.anchor, start: move.start, track: move.track)
                }
                scrolling.itemSelection.end(dragged: pointerDragged)
                if drawingMIDI, pointerDragged, !show.timelineItemsLocked, let track = pointerTrack(at: initial.point.y) {
                    let enabled = TimelineSnapPreference.enabled && !event.modifiers.contains(.shift)
                    let from = TimelineTempo.snap(min(initial.time, time), song: song, pixelsPerSecond: width / span,
                        enabled: enabled, includeItemEdges: true, rulerSections: snapRulerSections)
                    let to = TimelineTempo.snap(max(initial.time, time), song: song, pixelsPerSecond: width / span,
                        enabled: enabled, includeItemEdges: true, rulerSections: snapRulerSections)
                    if to > from, let created = show.addMIDIItem(track: track, start: from, duration: to - from) {
                        scrolling.itemSelection.replace([created])
                    }
                }
                if !pointerDragged && !event.direct {
                    if let track = pointerTrack(at: initial.point.y) {
                        show.setMixerTrackSelection([track], anchor: track)
                    }
                    let snapped = TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
                        enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift),
                        includeItemEdges: true, rulerSections: snapRulerSections)
                    seek(snapped)
                }
            }
            cancelPointer()
        } else if pointerDragged {
            let left = visibleLeft(width)
            if event.position.x < left + 20 { viewport.pan(pixels: 8, width: visibleWidth(width)) }
            else if event.position.x > left + visibleWidth(width) - 20 { viewport.pan(pixels: -8, width: visibleWidth(width)) }
            if let scroll = scrolling.gridScrollView {
                let visibleY = event.position.y - scroll.contentOffset.y
                if visibleY < 24 { scrolling.pointerScroll(-8) }
                else if visibleY > scroll.bounds.height - 24 { scrolling.pointerScroll(8) }
            }
        }
    }
    private func applyProTool(_ id: UUID, time: Double, width: CGFloat) {
        guard let show = localShow, let song = show.current else { return }
        scrolling.itemSelection.replace([id])
        switch proTool {
        case .select: break
        case .cut:
            guard !show.timelineItemsLocked else { return }
            let snapped = TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
                enabled: TimelineSnapPreference.enabled, includeItemEdges: true, excludingItems: [id], rulerSections: snapRulerSections)
            let right = show.splitItems([id], at: snapped)
            if !right.isEmpty { scrolling.itemSelection.replace(right) }
        case .mute: show.send(.clipMute, target: id)
        case .solo:
            if let track = song.tracks.first(where: { $0.clips.contains { $0.id == id } }) {
                show.send(.solo, target: track.id)
            }
        }
    }
    private func gridMarks(width: CGFloat) -> [TimelineTimeRuler.Tick] {
        var sections: [TimelineTempoSection]
        if local, let nativeContent {
            sections = nativeContent.rulerSections
            if let last = sections.last, end > last.end {
                sections[sections.count - 1] = TimelineTempoSection(start: last.start, end: end, bpm: last.bpm,
                    beats: last.beats, unit: last.unit, timebase: last.timebase)
            }
        } else {
            sections = (state.gridTempo ?? []).map {
                TimelineTempoSection(start: $0.start, end: $0.end, bpm: $0.bpm, beats: $0.beats, unit: $0.unit, timebase: .free)
            }
            if sections.isEmpty {
                sections = [TimelineTempoSection(start: 0, end: max(end, state.duration), bpm: max(1, state.bpm),
                    beats: 4, unit: 4, timebase: .free)]
            }
        }
        let musical = TimelineTimeRuler.MusicalLabels(sections: sections)
        return TimelineTimeRuler.ticks(in: sections, from: start, to: end,
                                       pixelsPerSecond: width / span, divisions: gridDivisions, musical: musical)
    }
    private func gridX(_ time: Double, width: CGFloat) -> CGFloat {
        TimelineVerticalInk.center((time - start) / span * width, at: displayScale)
    }
    private func handleWheel(_ delta: CGPoint, modifiers: HardwareKeyboardModifiers, width: CGFloat) {
        pauseScrollFollowing()
        if modifiers.contains(.command) || modifiers.contains(.control) {
            scrolling.resizeTracks(exp(Double(delta.y) * 0.006)); scrolling.finishResizingTracks()
        } else if modifiers.contains(.option) {
            scrolling.pointerScroll(-delta.y)
        } else if modifiers.contains(.shift) || abs(delta.x) > abs(delta.y) {
            viewport.pan(pixels: Double(delta.x == 0 ? delta.y : delta.x), width: visibleWidth(width))
        } else { viewport.zoom(factor: exp(Double(delta.y) * 0.009), centeredOn: zoomCursor) }
    }
    private func ruler(width: CGFloat, marks: [TimelineTimeRuler.Tick], song: Song?) -> some View {
        ZStack(alignment: .leading) {
            (local ? JarasTheme.panel : JarasTheme.display)
            Canvas { context, size in
                let pixel = 1 / displayScale
                var grid = Path()
                var ticks = Path()
                ticks.move(to: CGPoint(x: 0, y: nativeBands.numberHeight))
                ticks.addLine(to: CGPoint(x: size.width, y: nativeBands.numberHeight))
                context.stroke(ticks, with: .color(JarasTheme.timelineHeaderLine), lineWidth: pixel)
                ticks = Path()
                for mark in marks {
                    let x = gridX(mark.time, width: size.width)
                    if showsVerticalGrid && mark.drawsInGrid {
                        grid.move(to: CGPoint(x: x, y: mark.label.isEmpty ? nativeBands.numberHeight : 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    } else {
                        ticks.move(to: CGPoint(x: x, y: nativeBands.numberHeight))
                        ticks.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }
                let gridColor = local ? UInt32(localVerticalColor) :
                    state.gridPrimaryColor ?? UInt32(TimelineThemeColor.verticalGrid.defaultColor(for: .current))
                context.stroke(grid, with: .color(Color(hex: gridColor)), lineWidth: TimelineVerticalInk.width(at: displayScale))
                context.stroke(ticks, with: .color(Color(hex: gridColor)), lineWidth: TimelineVerticalInk.width(at: displayScale))
                for mark in marks where !mark.label.isEmpty {
                    let x = gridX(mark.time, width: size.width)
                    if let label = TimelineStaticText.label(mark.label, style: .timelineNumber, displayScale: displayScale) {
                        label.draw(at: CGPoint(x: x + 2, y: (nativeBands.numberHeight - label.size.height) / 2),
                                   context: &context)
                    }
                }
            }
        }.frame(height: timeRulerHeight).contentShape(Rectangle())
            .overlay(IpadRulerTouchInput(enabled: local ? editorEnabled : !state.playing && region != nil,
                drag: { translation, location, ended, cancelled in
                    if cancelled { rulerDrag.reset(); selectionResizeFixedEdge = nil; return }
                    if local {
                        if resizeRulerSelection(origin: location - translation, x: location, width: width, ended: ended) { return }
                        pauseScrollFollowing(); rulerDrag.update(translation: translation, width: visibleWidth(width), viewport: &viewport)
                        if ended { rulerDrag.reset() }
                    } else {
                        let time = start + min(1, max(0, location / width)) * span
                        if ended { seek(time) } else { preview(time) }
                    }
                }, selection: { origin, x, ended, cancelled in
                    guard local else { return }
                    let point = CGPoint(x: x, y: 0), first = CGPoint(x: origin, y: 0)
                    if rulerPointerViewport == nil && !cancelled {
                        rulerPointer(.init(phase: .began, position: first, origin: first, secondary: true, modifiers: []), width: width)
                    }
                    rulerPointer(.init(phase: cancelled ? .cancelled : ended ? .ended : .moved,
                        position: point, origin: first, secondary: true, modifiers: []), width: width)
                }, tap: { seekOnRuler($0, width: width, modifiers: scrolling.modifiers) }))
            .background {
                if local {
                    IpadTimelinePointerProbe(enabled: editorEnabled, capturesPointer: true,
                        reset: scrolling.pointerReset, accepts: { _ in true }, wantsAutoScroll: { _ in false },
                        event: { rulerPointer($0, width: width) }, wheel: { handleWheel($0, modifiers: $1, width: width) })
                }
            }
            .onChange(of: scrolling.pointerReset) { _ in rulerDrag.reset() }
            .accessibilityLabel(local ? "Time ruler: drag to scroll" : "Régua de compassos: arraste com o transporte parado")
    }
    private func resizeRulerSelection(origin: CGFloat, x: CGFloat, width: Double, ended: Bool) -> Bool {
        guard local, let show = localShow, let song = show.current else { return false }
        if selectionResizeFixedEdge == nil {
            guard let range = highlightedTimeRange else { return false }
            let left = (range.lowerBound - start) / span * width
            let right = (range.upperBound - start) / span * width
            if abs(origin - left) <= 18 && abs(origin - left) <= abs(origin - right) { selectionResizeFixedEdge = range.upperBound }
            else if abs(origin - right) <= 18 { selectionResizeFixedEdge = range.lowerBound }
            else { return false }
            pauseFollowing()
        }
        guard let fixed = selectionResizeFixedEdge else { return false }
        let time = TimelineTempo.snap(max(0, start + Double(x / max(1, width)) * span), song: song,
            pixelsPerSecond: width / span, enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
            includeItemEdges: true, rulerSections: snapRulerSections)
        timeSelection.update(song: song.id, from: fixed, to: time)
        show.updateActiveLoopArea()
        if ended { selectionResizeFixedEdge = nil }
        return true
    }
    private func seekOnRuler(_ x: CGFloat, width: Double, modifiers: HardwareKeyboardModifiers) {
        let time = max(0, start + min(1, max(0, x / max(1, width))) * span)
        guard local, let song = localShow?.current else { seek(time); return }
        pauseFollowing()
        (rulerSeek ?? seek)(TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
            enabled: TimelineSnapPreference.enabled && !modifiers.contains(.shift), includeItemEdges: true,
            rulerSections: snapRulerSections))
    }
    private func rulerPointer(_ event: IpadTimelinePointerEvent, width: CGFloat) {
        guard local, editorEnabled, let show = localShow, let song = show.current else { return }
        switch event.phase {
        case .began:
            pauseFollowing(); rulerVisibleViewport = viewport
            rulerPointerViewport = IpadTimelineViewport(start: start, span: span)
            if event.secondary {
                rulerSelectionAnchor = TimelineTempo.snap(max(0, start + Double(event.origin.x / max(1, width)) * span), song: song,
                    pixelsPerSecond: width / span, enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift),
                    includeItemEdges: true, rulerSections: snapRulerSections)
                rulerSelectionEnd = nil
            }
        case .moved, .ended:
            guard rulerPointerViewport != nil else { return }
            if event.secondary {
                func time(_ x: CGFloat) -> Double {
                    TimelineTempo.snap(max(0, start + Double(x / max(1, width)) * span), song: song,
                        pixelsPerSecond: width / span,
                        enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift),
                        includeItemEdges: true, rulerSections: snapRulerSections)
                }
                if event.distance >= 3 || rulerSelectionEnd != nil {
                    let end = time(event.position.x)
                    rulerSelectionEnd = end
                    timeSelection.update(song: song.id, from: rulerSelectionAnchor ?? time(event.origin.x), to: end)
                    show.updateActiveLoopArea()
                }
            } else if resizeRulerSelection(origin: event.origin.x, x: event.position.x, width: width, ended: event.phase == .ended) {
                if event.phase == .ended { rulerPointerViewport = nil }
                return
            } else if event.distance >= 3 {
                var moved = rulerVisibleViewport ?? viewport
                moved.pan(pixels: Double(event.position.x - event.origin.x), width: visibleWidth(width))
                viewport = moved
            } else if event.phase == .ended {
                seekOnRuler(event.position.x, width: width, modifiers: event.modifiers)
            }
            if event.phase == .ended { rulerPointerViewport = nil; rulerSelectionAnchor = nil; rulerSelectionEnd = nil }
        case .cancelled: rulerPointerViewport = nil; rulerSelectionAnchor = nil; rulerSelectionEnd = nil; selectionResizeFixedEdge = nil
        }
    }
    private func tempoLane(width: CGFloat, song: Song?) -> some View {
        ZStack(alignment: .topLeading) {
            JarasTheme.panel
            Canvas { context, size in
                guard let song else { return }
                for marker in song.markers ?? [] where marker.isTempo && marker.position >= start && marker.position <= end {
                    let x = gridX(marker.position, width: size.width)
                    let text = TimelineStaticText.label(song.markerLabel(marker), style: .tempoMarker, displayScale: displayScale)
                    let rect = CGRect(x: x, y: 1, width: (text?.width ?? 0) + 6, height: 14)
                    let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
                    context.fill(shape, with: .color(JarasTheme.display))
                    context.stroke(shape, with: .color(JarasTheme.line), lineWidth: 1)
                    var labelContext = context
                    labelContext.clip(to: Path(rect))
                    text?.draw(at: CGPoint(x: rect.minX + 3, y: rect.minY + 2), context: &labelContext)
                }
            }
            if local, let song {
                ForEach((song.markers ?? []).filter { $0.isTempo && $0.position >= start && $0.position <= end }) { marker in
                    markerTarget(marker, width: (TimelineStaticText.label(song.markerLabel(marker), style: .tempoMarker, displayScale: displayScale)?.width ?? 24) + 6, height: 16, pixelsPerSecond: width / span)
                        .offset(x: gridX(marker.position, width: width))
                }
            }
        }.frame(height: 16).clipped().contentShape(Rectangle())
            .contextMenu {
                if local {
                    Button("Create marker") { createMarker() }
                    Button("Tempo marker") { createMarker(tempo: true) }
                }
            }
            .onTapGesture { pauseFollowing(); selectedRegionID = nil }.accessibilityLabel("BPM / Compasso")
    }
    private func regionDestination(_ id: UUID, original: Double, translation: Double, width: Double) -> Double {
        guard let song = localShow?.current else { return original }
        return TimelineTempo.snap(original + translation / max(1, width) * span, song: song,
            pixelsPerSecond: width / span, cursor: localShow?.snapshot.transport.editPosition ?? position,
            enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
            excludingRegion: id, includeItemEdges: true, rulerSections: snapRulerSections)
    }
    @ViewBuilder private func nativeRegionMenu(_ part: Part, song: Song) -> some View {

                            Button("Editar região") { pauseFollowing(); openRegionActions?(part.id) }
                            Button("Detect BPM…") { regionCommand?(part.id, "bpm") }
                            if part.parentRegionID == nil {
                                Button("Export Multitrack") { regionCommand?(part.id, "multitrack") }
                            }
                            if song.parts.contains(where: { $0.parentRegionID == part.id }) {
                                Button("Disunify regions") { localShow?.disunifyRegion(part.id) }
                            } else { Button("Multiloops") { regionCommand?(part.id, "loops") } }
                            if song.parts.contains(where: { $0.id != part.id && $0.parentRegionID == nil && $0.startTime < part.endTime && $0.endTime > part.startTime }) {
                                Button("Unify regions") { regionCommand?(part.id, "unify") }
                            }
                            Button("Config Init") { regionCommand?(part.id, "init") }
                            Button("Delete region", role: .destructive) { localShow?.deleteRegion(part.id, playlist: nil) }

    }
    private func nativeRegionHeader(_ part: Part, song: Song, width: Double, lane: Int) -> some View {
        let left = max(start, part.startTime), right = min(end, part.endTime)
        return
                    Text(verbatim: part.displayName).font(.jarasSystem(size: 9, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(Color.black).padding(.horizontal, 4)
                        .frame(width: max(0, (right - left) / span * width), height: RemoteNativeGridMetrics.regionHeight(local: local), alignment: .leading)
                        .background(remoteColor(part.color ?? 0x705264))
                        .clipShape(RoundedRectangle(cornerRadius: 2.5))
                        .overlay(IpadRegionHeaderGesture(singleTap: { pauseFollowing(); selectedRegionID = part.id }, doubleTap: {
                            pauseFollowing(); openRegionActions?(part.id)
                        }, moved: { translation in
                            // Use original document coordinates throughout the gesture.
                            guard localShow?.timelineRegionsLocked == false,
                                  let original = localShow?.current?.parts.first(where: { $0.id == part.id }) else { return }
                            pauseFollowing()
                            regionDrag = IpadRegionMovePreview(id: part.id, start: regionDestination(part.id, original: original.startTime, translation: translation, width: width))
                        }, ended: { cancelled in
                            let move = regionDrag; regionDrag = nil
                            if !cancelled, let move, let show = localShow, show.snapshot.project.id == state.project {
                                show.moveRegion(move.id, start: move.start)
                            }
                        }))
                        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(selectedRegionID == part.id ? JarasTheme.green : .clear, lineWidth: 2).allowsHitTesting(false))
                        .contextMenu { nativeRegionMenu(part, song: song) }
                        .offset(x: (left - start) / span * width, y: CGFloat(lane) * RemoteNativeGridMetrics.regionHeight(local: local))
    }
    private func regionLane(width: CGFloat, song: Song?) -> some View {
        ZStack(alignment: .topLeading) {
            (local ? JarasTheme.panel : JarasTheme.display).contentShape(Rectangle()).onTapGesture { if local { pauseFollowing(); selectedRegionID = nil } }
            if local, let song {
                let content = nativeContent
                ForEach((content?.regions(from: start, through: end) ?? []).filter { $0.startTime < end && $0.endTime > start }) { part in
                    nativeRegionHeader(part, song: song, width: width, lane: content?.lanes.lanes[part.id] ?? 0)

                }
            } else if let region {
                Text(verbatim: region.name).font(.jarasSystem(size: 10, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(Color.black).padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(remoteColor(region.color).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
            }
        }.frame(height: regionAreaHeight).clipped().accessibilityLabel("Faixa da região " + (region?.name ?? ""))
    }
    private func markerLane(width: CGFloat, markers: [TimelineMarker], song: Song?) -> some View {
        let regionEnds = nativeContent?.markerEnds ?? [:]
        return ZStack(alignment: .leading) {
            (local ? JarasTheme.panel : JarasTheme.display)
            Canvas { context, size in
                let widths = Dictionary(uniqueKeysWithValues: markers.map { marker in
                    (marker.id, Double(context.resolve(Text(verbatim: marker.name).font(.jarasSystem(size: 9, weight: .semibold)))
                        .measure(in: CGSize(width: .infinity, height: size.height)).width))
                })
                let ends = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, min(end, regionEnds[$0.id] ?? end)) })
                let flags = TimelineMarker.flagWidths(markers, scale: size.width / span, widths: widths, regionEnds: ends)
                for marker in markers {
                    guard let flagWidth = flags[marker.id] else { continue }
                    let x = (marker.position - start) / span * size.width
                    let rect = CGRect(x: x, y: 1, width: flagWidth, height: size.height - 2)
                    var flagContext = context
                    flagContext.clip(to: Path(rect))
                    drawMarkerFlag(marker, rect: rect, context: &flagContext)
                    flagContext.draw(Text(verbatim: marker.name).font(.jarasSystem(size: 9, weight: .semibold)).foregroundColor(.black),
                        in: rect.insetBy(dx: marker.isSection ? 7 : 3, dy: 2))
                }
            }
            if local {
                let widths = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, Double(($0.name as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .semibold)]).width)) })
                let ends = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, min(end, regionEnds[$0.id] ?? end)) })
                let flags = TimelineMarker.flagWidths(markers, scale: width / span, widths: widths, regionEnds: ends)
                ForEach(markers) { marker in
                    markerTarget(marker, width: flags[marker.id] ?? 12, height: RemoteNativeGridMetrics.markerHeight(local: local), pixelsPerSecond: width / span)
                        .offset(x: gridX(marker.position, width: width))
                }
            }
        }.frame(height: RemoteNativeGridMetrics.markerHeight(local: local)).clipped().contentShape(Rectangle())
            .contextMenu {
                if local {
                    Button("Create marker") { createMarker() }
                    Button("Tempo marker") { createMarker(tempo: true) }
                }
            }
            .onTapGesture { if local { pauseFollowing() } }.accessibilityLabel("Marcadores da música")
    }
    private func markerTarget(_ marker: TimelineMarker, width: CGFloat, height: CGFloat, pixelsPerSecond: Double) -> some View {
        Color.clear.frame(width: max(1, width), height: height).contentShape(Rectangle())
            .onTapGesture(count: 2) { pauseFollowing(); openMarkerEditor?(marker) }
            .contextMenu {
                Button("Editar marcador") { pauseFollowing(); openMarkerEditor?(marker) }
                Button("Delete", role: .destructive) { localShow?.deleteManualMarker(marker.id) }
            }.accessibilityLabel(marker.name)
            .gesture(DragGesture(minimumDistance: 3)
                .updating($markerPreview) { value, preview, _ in
                    guard let moved = draggedMarker(marker.id, translation: value.translation.width, pixelsPerSecond: pixelsPerSecond) else { return }
                    preview = (moved.id, moved.position)
                }
                .onChanged { _ in if local { pauseFollowing() } }
                .onEnded { value in
                    guard let moved = draggedMarker(marker.id, translation: value.translation.width, pixelsPerSecond: pixelsPerSecond) else { return }
                    localShow?.setMarker(moved)
                })
    }
    private func draggedMarker(_ id: UUID, translation: Double, pixelsPerSecond: Double) -> TimelineMarker? {
        guard local, editorEnabled, let show = localShow, !show.timelineRegionsLocked,
              let song = show.current, var marker = song.markers?.first(where: { $0.id == id }),
              song.canDragMarker(marker), pixelsPerSecond > 0 else { return nil }
        marker.position = song.markerDragPosition(marker, to: marker.position + translation / pixelsPerSecond,
            pixelsPerSecond: pixelsPerSecond, free: !TimelineSnapPreference.enabled || scrolling.modifiers.contains(.shift),
            cursor: show.snapshot.transport.editPosition ?? show.snapshot.transport.position, rulerSections: snapRulerSections)
        return marker
    }
    private func createMarker(tempo: Bool = false) {
        guard let show = localShow, let song = show.current else { return }
        let time = show.snapshot.transport.editPosition ?? position
        guard show.canCreateMarker(at: time, tempo: tempo) else { return }
        let settings = song.tempoSection(at: time)
        openMarkerEditor?(TimelineMarker(id: UUID(), name: tempo ? "TEMPO" : "", position: time, color: 0x51ef93,
            tempoBPM: tempo ? settings.bpm : nil, tempoBeats: tempo ? settings.beats : nil,
            tempoUnit: tempo ? settings.unit : nil, tempoTimebase: tempo ? .global : nil))
    }
    private func cursor(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            needle(state.playing ? state.editPosition : position,
                   color: state.editCursorColor ?? UInt32(TimelineAppearanceDefaults.editCursor), width: width)
            if state.playing {
                needle(localShow?.snapshot.transport.position ?? position, color: state.playCursorColor ?? UInt32(TimelineAppearanceDefaults.playCursor), width: width, glowing: true)
            }
            if let queued = state.queuedRegion {
                let start = state.timelineRegions.first { $0.id == queued }?.start ?? state.regions.first { $0.id == queued }?.start
                let position = localShow?.snapshot.transport.subPlay.position ?? state.subPlayPosition ?? state.sectionPlayback?.secondaryPosition
                needle(state.subPlaying ? position : start ?? position, color: UInt32(TimelineAppearanceDefaults.subPlayCursor), width: width, glowing: state.subPlaying)
            }
        }.frame(width: width, alignment: .leading).frame(maxHeight: .infinity)
            .allowsHitTesting(false)
    }
    @ViewBuilder private func needle(_ time: Double?, color: UInt32, width: CGFloat, glowing: Bool = false) -> some View {
        if let time, time >= start, time <= end {
            let x = min(width - (glowing ? 3 : 2), max(0, (time - start) / span * width))
            let displayColor = remoteColor(color)
            ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { pauseFollowing(); selectedRegionID = nil }
                if glowing {
                    let trailWidth = min(x, 38)
                    Rectangle().fill(LinearGradient(colors: [.clear, displayColor.opacity(0.16), displayColor.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: trailWidth).offset(x: x - trailWidth)
                }
                Rectangle().fill(displayColor).frame(width: glowing ? 3 : 2)
                    .shadow(color: displayColor.opacity(glowing ? 1 : 0.55), radius: glowing ? 4 : 3)
                    .offset(x: x)
                if glowing {
                    Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1)
                        .shadow(color: displayColor, radius: 7).offset(x: x + 1)
                }
                let headHeight = nativeBands.tickHeight
                Path(TimelineNeedleHead.path(centerX: 7, top: 0, tip: headHeight))
                    .fill(displayColor).frame(width: 14, height: headHeight)
                    .shadow(color: displayColor.opacity(glowing ? 0.9 : 0.4), radius: glowing ? 4 : 2)
                    .offset(x: x + (glowing ? 1.5 : 1) - 7, y: -headHeight)
            }
        }
    }
    private func cancelItemMix() {
        guard let preview = scrolling.itemMix else { return }
        if let show = localShow, show.snapshot.project.id == preview.project, let song = show.current, song.id == preview.song {
            for clip in song.tracks.flatMap(\.clips) where preview.items.contains(clip.id) {
                if preview.parameter == .gain { show.previewItemGain(clip.id, gain: clip.gain ?? 1) }
                else { show.previewItemPan(clip.id, pan: clip.pan ?? 0) }
            }
        }
        scrolling.itemMix = nil
    }
    private func updateNativeItemMix(_ id: UUID, _ parameter: IpadItemMixParameter, _ value: Double, _ finished: Bool, _ cancelled: Bool) {
        guard let show = localShow, show.snapshot.project.id == state.project, let song = show.current, song.id == state.song else { return }
        guard !show.timelineItemMixLocked else { scrolling.itemMix = nil; return }
        if !cancelled && (!editorEnabled || !show.canControl()) { cancelItemMix(); return }
        scrolling.selectionScope = .grid
        let requested = scrolling.itemMix?.items ?? (scrolling.itemSelection.items.contains(id) ? scrolling.itemSelection.items : [id])
        let clips = song.tracks.filter { $0.kind == .standard }.flatMap(\.clips).filter { requested.contains($0.id) }
        let ids = Set(clips.map(\.id))
        guard !ids.isEmpty, value.isFinite else { scrolling.itemMix = nil; return }
        if cancelled {
            for clip in clips {
                if parameter == .gain { show.previewItemGain(clip.id, gain: clip.gain ?? 1) }
                else { show.previewItemPan(clip.id, pan: clip.pan ?? 0) }
            }
            scrolling.itemMix = nil; return
        }
        if finished {
            if ids.count == 1, let target = ids.first {
                if parameter == .gain { show.setItemGain(target, gain: value) } else { show.setItemPan(target, pan: value) }
            } else {
                show.setItemsMix(ids, gain: parameter == .gain ? value : nil, pan: parameter == .pan ? value : nil)
            }
            scrolling.itemMix = nil
        } else {
            for clip in clips {
                if parameter == .gain { show.previewItemGain(clip.id, gain: value) } else { show.previewItemPan(clip.id, pan: value) }
            }
            scrolling.itemMix = IpadNativeItemMix(project: state.project, song: song.id, items: ids, parameter: parameter, value: value)
        }
    }
    private func timelineRow(_ track: DAWRemoteState.Track, width: CGFloat, nativeSong: Song?) -> some View {
        RemoteTimelineTrackRow(track: trackWithVolumePreview(track), width: width, displayScale: displayScale,
            start: start, end: end, span: span, hasRegion: local || region != nil, heightScale: scrolling.heightScale,
            project: state.project, song: state.song,
            scrolling: scrolling, local: local, headersHidden: itemHeadersHidden, invertWaveformColors: local && invertWaveformColors, nativeTrack: nativeContent?.tracks[track.id], nativeSong: nativeSong, preparedTrack: nativeContent?.track(track.id),
            nativeDirectory: local ? DAWRemoteHostBridge.documents?.currentURL?.deletingLastPathComponent() : nil,
            nativeRevision: localShow?.projectRevision ?? 0, mixPreview: scrolling.itemMix, selectedItem: scrolling.selectedItem,
            selectedItems: scrolling.itemSelection.items, movementLocked: localShow?.timelineItemsLocked ?? false,
            itemMixLocked: localShow?.timelineItemMixLocked ?? false,
            resizeEnabled: editorEnabled && localShow?.canControl() == true, touchItemEditing: touchItemEditing,
            snapRulerSections: { snapRulerSections }, interactionID: scrolling.pointerReset,
            cursorPosition: { [weak show = localShow] in
                guard let transport = show?.snapshot.transport else { return nil }
                return transport.editPosition ?? transport.position
            },
            selectTrack: { localShow?.setMixerTrackSelection([track.id], anchor: track.id) },
            itemFade: { id, fadeIn, value, finished in
                if finished { localShow?.setItemFade(id, fadeIn: fadeIn, seconds: value) }
                else { localShow?.previewItemFade(id, fadeIn: fadeIn, seconds: value) }
            }, beginResize: { pauseFollowing() }, resizeItem: { id, left, right in
                guard editorEnabled, let show = localShow, show.canControl(),
                      show.snapshot.project.id == state.project, show.current?.id == state.song else { return }
                show.resizeItem(id, start: left, end: right)
            }, resizeShared: { left, right, position in
                guard editorEnabled, let show = localShow, show.snapshot.project.id == state.project,
                      let song = show.current, song.id == state.song,
                      let source = song.tracks.first(where: { $0.id == track.id }) else { return }
                let selected = scrolling.itemSelection.items
                if TeleprompterBoundaryEdit(track: source, selected: selected, left: left, right: right, position: position) != nil {
                    show.resizeTeleprompterBoundary(selected: selected, left: left, right: right, position: position)
                } else if selected.count == 2 {
                    show.resizeSharedItemBoundary(left: left, right: right, position: position)
                }
            },
            openItemMenu: { id in
                let ids = scrolling.itemSelection.items.contains(id) ? scrolling.itemSelection.items : [id]
                if let openSelectedItemMenu { openSelectedItemMenu(id, ids) } else { openItemMenu?(id) }
            }, openItemFX: openItemFX.map { callback in { id in
                if local, let localShow {
                    localShow.reportItemSelection(scrolling.itemSelection.items)
                    let keyboard = GCKeyboard.coalesced?.keyboardInput
                    if keyboard?.button(forKeyCode: .leftAlt)?.isPressed == true || keyboard?.button(forKeyCode: .rightAlt)?.isPressed == true {
                        localShow.removeAllClipFX(id); return
                    }
                    if keyboard?.button(forKeyCode: .leftShift)?.isPressed == true || keyboard?.button(forKeyCode: .rightShift)?.isPressed == true {
                        localShow.toggleClipFXAllBypass(id); return
                    }
                }
                callback(id)
            } },
            openVolume: { id in volumePreview = nil; volumeItem = id },
            itemMix: updateNativeItemMix, itemPhase: { localShow?.toggleItemPhase($0) }, control: { action, id, value in
                let ids = scrolling.itemSelection.items
                if local, ids.contains(id), ids.count > 1, let show = localShow {
                    switch action {
                    case .clipGain: show.setItemsMix(ids, gain: value)
                    case .clipMute:
                        let muted = show.current?.tracks.flatMap(\.clips).first(where: { $0.id == id })?.muted == true
                        show.setItemsMix(ids, muted: !muted)
                    default: control(action, id, value)
                    }
                } else { control(action, id, value) }
            }).equatable()
            .overlay(alignment: .bottom) {
                if local { Color(hex: UInt32(localHorizontalColor)).frame(height: 1 / displayScale).allowsHitTesting(false) }
            }
            .overlay(alignment: .topLeading) {
                if local, let show = localShow, let source = nativeSong?.tracks.first(where: { $0.id == track.id }), source.kind == .programChange {
                    ProgramChangeMarkerLane(show: show, track: source, pixelsPerSecond: width / span,
                        height: DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale, minimum: minimumTrackRowHeight), start: start)
                        .frame(width: width, height: DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale, minimum: minimumTrackRowHeight))
                }
            }
    }

}

/// Use the desktop overlap components for item drawing and pointer hit testing.
/// Unrelated overlaps elsewhere in the track do not shrink isolated items.
private struct IpadNativeItemGeometry {
    let rowHeight: Double
    let fallbackLaneHeight: Double
    let lanes: TrackLanes?
    init(track: Track?, remoteTrack: DAWRemoteState.Track, scale: Double, minimumRowHeight: Double = 0, preparedLanes: TrackLanes? = nil) {
        rowHeight = DAWRemoteItemLayout.rowHeight(remoteTrack, scale: scale, minimum: minimumRowHeight)
        fallbackLaneHeight = max(minimumRowHeight / Double(max(1, remoteTrack.laneCount ?? 1)),
            DAWRemoteItemLayout.laneHeight(remoteTrack, scale: scale))
        lanes = track.map { source in
            var layout = preparedLanes ?? TrackLanes(track: source)
            if (remoteTrack.laneCount ?? 1) > layout.count {
                layout.reserveRecordingLanes(count: remoteTrack.laneCount ?? 1)
            }
            return layout
        }
    }
    private func laneHeight(_ id: UUID) -> Double {
        lanes.map { rowHeight / Double(max(1, $0.localCount(for: id))) } ?? fallbackLaneHeight
    }
    // The touch timeline already spaces its rows by one point.
    static let itemInset = Double(GridSelectionItem.verticalInset) - 0.5
    func height(_ id: UUID) -> Double { max(0, laneHeight(id) - 2 * Self.itemInset) }
    func offset(_ id: UUID, fallbackLane: Int = 0) -> Double {
        Double(lanes?.localLane(for: id) ?? fallbackLane) * laneHeight(id) + Self.itemInset
    }
}

/// Clip drawing is independent of the playhead. The needle can advance without
/// rebuilding waveform paths or item touch targets in every visible row.
private struct RemoteTimelineTrackRow: View, Equatable {
    let track: DAWRemoteState.Track
    let width: CGFloat
    let displayScale: CGFloat
    let start: Double
    let end: Double
    let span: Double
    let hasRegion: Bool
    let heightScale: Double
    let project: UUID
    let song: UUID?
    let scrolling: RemoteTrackScrollController
    var local = false
    var headersHidden = false
    var invertWaveformColors = false
    var nativeTrack: Track? = nil
    var nativeSong: Song? = nil
    var preparedTrack: IpadTimelineTrackContent? = nil
    var nativeDirectory: URL? = nil
    var nativeRevision: UInt64 = 0
    var mixPreview: IpadNativeItemMix?
    var selectedItem: UUID? = nil
    var selectedItems: Set<UUID> = []
    var movementLocked = false
    var itemMixLocked = false
    var resizeEnabled = false
    var touchItemEditing = false
    var snapRulerSections: () -> [TimelineTempoSection]? = { nil }
    let interactionID: UUID
    var cursorPosition: () -> Double? = { nil }
    var selectTrack: (() -> Void)? = nil
    var itemFade: ((UUID, Bool, Double, Bool) -> Void)? = nil
    var beginResize: (() -> Void)? = nil
    var resizeItem: ((UUID, Double, Double) -> Void)? = nil
    var resizeShared: ((UUID, UUID, Double) -> Void)? = nil
    @State private var sharedResizePreview: [AudioClip]?
    @State private var resizing: IpadItemResizePreview?
    @State private var fadePreview: (id: UUID, fadeIn: Bool, value: Double)?
    var openItemMenu: ((UUID) -> Void)? = nil
    var openItemFX: ((UUID) -> Void)? = nil
    var openVolume: ((UUID) -> Void)? = nil
    var itemMix: ((UUID, IpadItemMixParameter, Double, Bool, Bool) -> Void)? = nil
    var itemPhase: ((UUID) -> Void)? = nil
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.song == rhs.song && lhs.scrolling === rhs.scrolling &&
            lhs.track.id == rhs.track.id && lhs.track.name == rhs.track.name && lhs.track.color == rhs.track.color &&
            lhs.track.nameColor == rhs.track.nameColor && lhs.track.clips == rhs.track.clips &&
            lhs.track.silenced == rhs.track.silenced &&
            lhs.track.laneCount == rhs.track.laneCount && lhs.track.heightScale == rhs.track.heightScale && lhs.track.emphasized == rhs.track.emphasized &&
            lhs.preparedTrack === rhs.preparedTrack && lhs.width == rhs.width && lhs.displayScale == rhs.displayScale && lhs.heightScale == rhs.heightScale &&
            lhs.selectedItem == rhs.selectedItem && lhs.selectedItems == rhs.selectedItems && lhs.itemMixLocked == rhs.itemMixLocked && lhs.movementLocked == rhs.movementLocked && lhs.resizeEnabled == rhs.resizeEnabled && lhs.interactionID == rhs.interactionID && lhs.start == rhs.start && lhs.end == rhs.end && lhs.span == rhs.span && lhs.nativeRevision == rhs.nativeRevision && lhs.mixPreview == rhs.mixPreview && lhs.nativeDirectory == rhs.nativeDirectory && lhs.hasRegion == rhs.hasRegion && lhs.local == rhs.local && lhs.headersHidden == rhs.headersHidden &&
            lhs.invertWaveformColors == rhs.invertWaveformColors && lhs.touchItemEditing == rhs.touchItemEditing
    }
    private func nativeClip(_ id: UUID) -> AudioClip? {
        if let shared = sharedResizePreview {
            if let clip = shared.first(where: { $0.id == id }) { return clip }
        }
        if let resizing, resizing.original.id == id { return resizing.candidate }
        return preparedTrack?.clips[id] ?? nativeTrack?.clips.first(where: { $0.id == id })
    }
    private var previewTrack: Track? {
        guard var result = nativeTrack, let resizing,
              let index = result.clips.firstIndex(where: { $0.id == resizing.original.id }) else { return nativeTrack }
        result.clips[index] = resizing.candidate
        if let shared = sharedResizePreview {
            for i in result.clips.indices {
                if let clip = shared.first(where: { $0.id == result.clips[i].id }) { result.clips[i] = clip }
            }
        }
        return result
    }
    private var previewClips: [DAWRemoteState.Clip] {
        guard let resizing else { return track.clips }
        return track.clips.map { source in
            if let shared = sharedResizePreview {
                let candidate = shared.first(where: { $0.id == source.id })
                if let candidate { var result = source; result.start = candidate.startTime; result.duration = candidate.duration; return result }
            }
            guard source.id == resizing.original.id else { return source }
            var result = source; result.start = resizing.candidate.startTime; result.duration = resizing.candidate.duration
            return result
        }
    }
    private func resize(_ id: UUID, left: Bool, translation: Double, finished: Bool, cancelled: Bool) {
        if cancelled { resizing = nil; sharedResizePreview = nil; return }
        guard local, resizeEnabled, !movementLocked, let nativeSong, let nativeTrack,
              let clip = nativeTrack.clips.first(where: { $0.id == id }) else { resizing = nil; sharedResizePreview = nil; return }
        if let preview = resizing, preview.original != clip { resizing = nil; sharedResizePreview = nil; return }
        if resizing == nil { beginResize?(); resizing = IpadItemResizePreview(original: clip, candidate: clip, secondsPerPoint: span / max(1, width)) }
        guard var preview = resizing else { return }
        let original = preview.original
        let selectedLane = track.clips.first(where: { $0.id == id })?.lane ?? 0
        let neighbour = nativeTrack.clips.first { other in
            selectedItems.contains(id) && selectedItems.contains(other.id) &&
            (selectedItems.count == 2 || (nativeTrack.kind.isTeleprompter && original.text != nil && other.text != nil &&
                original.audioFile == nil && other.audioFile == nil && original.midi == nil && other.midi == nil)) &&
            other.id != id && (track.clips.first(where: { $0.id == other.id })?.lane ?? 0) == selectedLane &&
            abs(left ? other.startTime + other.duration - original.startTime : original.startTime + original.duration - other.startTime) < 1e-7
        }
        if let neighbour {
            let a = left ? neighbour : original, b = left ? original : neighbour
            let target = TimelineTempo.snap(max(0, b.startTime + translation * preview.secondsPerPoint), song: nativeSong,
                pixelsPerSecond: 1 / preview.secondsPerPoint, cursor: cursorPosition(),
                enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift), includeItemEdges: true,
                excludingItems: [a.id,b.id], rulerSections: snapRulerSections())
            if let chain = TeleprompterBoundaryEdit(track: nativeTrack, selected: selectedItems, left: a.id, right: b.id, position: target) {
                sharedResizePreview = chain.clips
            } else if selectedItems.count == 2 {
                let durations = [a, b].reduce(into: [UUID: Double]()) { $0[$1.id] = sourceDuration($1, track: nativeTrack) }
                let edit = SharedItemBoundaryEdit(song: nativeSong, track: nativeTrack, left: a, right: b,
                                                  position: target, sourceDurations: durations)
                sharedResizePreview = edit.map { [$0.left, $0.right] }
            }
            if let candidate = sharedResizePreview?.first(where: { $0.id == id }) {
                preview.candidate = candidate; resizing = preview
            }
            if finished {
                resizing = nil; sharedResizePreview = nil
                if abs(target - b.startTime) > 1e-7 { resizeShared?(a.id, b.id, target) }
            }
            return
        }
        sharedResizePreview = nil
        let edge = left ? original.startTime : original.startTime + original.duration
        let target = TimelineTempo.snap(max(0, edge + translation * preview.secondsPerPoint), song: nativeSong,
                                       pixelsPerSecond: 1 / preview.secondsPerPoint, cursor: cursorPosition(),
                                       enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
                                       includeItemEdges: true, excludingItems: [id], rulerSections: snapRulerSections())
        let lower = left ? min(target, original.startTime + original.duration - 0.01) : original.startTime
        let upper = left ? original.startTime + original.duration : max(original.startTime + 0.01, target)
        let unchanged = lower == original.startTime && upper == original.startTime + original.duration
        let candidate: AudioClip
        if nativeTrack.kind == .click, !original.isProjectionMedia {
            guard let resized = nativeSong.resizedClick(original, start: lower, end: upper) else { return }
            candidate = resized
        } else {
            let duration = sourceDuration(original, track: nativeTrack)
            candidate = unchanged ? original : original.resized(start: lower, end: upper, sourceDuration: duration)
        }
        if nativeTrack.canPlaceItem(start: candidate.startTime, duration: candidate.duration, excluding: id) {
            preview.candidate = candidate; resizing = preview
        }
        if finished {
            resizing = nil
            if preview.candidate != original { resizeItem?(id, preview.candidate.startTime, preview.candidate.startTime + preview.candidate.duration) }
        }
    }
    private func sourceDuration(_ clip: AudioClip, track: Track) -> Double? {
        guard let file = clip.audioFile ?? track.audioFile, clip.midi == nil, !clip.isImage, let nativeDirectory else { return nil }
        let url = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : nativeDirectory.appendingPathComponent(file.path)
        guard let header = TimelineAudioWaveform.shared.header(url), header.rate > 0 else { return nil }
        return Double(header.frames) / header.rate
    }
    private func nativeClickBeats(_ clip: DAWRemoteState.Clip, left: Double, right: Double, width: Double, sections: [TimelineTempoSection]?) -> [Double] {
        guard nativeTrack?.kind == .click, let nativeSong, let item = nativeClip(clip.id), right > left else { return [] }
        let scale = width / (right - left)
        return ClickTrackProgram.visibleBeats(sections: sections ?? nativeSong.tempoSections(until: max(nativeSong.duration, right)), start: clip.start, end: clip.start + clip.duration,
            visibleStart: left, visibleEnd: right, pixelsPerSecond: scale, doubled: item.clickDouble == true, rate: item.clickRate).map { ($0 - left) * scale }
    }
    private func gridItem(_ clip: DAWRemoteState.Clip, width itemWidth: Double, height itemHeight: Double, left: Double, right: Double, drawing: IpadTimelineTrackContent?) -> RemoteNativeGridItem {
        let item = nativeClip(clip.id)
        let fragments = item.flatMap { item in nativeSong.map { drawing?.segments(item, song: $0) ?? $0.tempoAudioSegments(item) } }
        let seams: [Double]
        if local, let item, item.loopLength != nil, let fragments, right > left {
            let scale = itemWidth / (right - left)
            seams = ClipRepetitionBoundaries.positions(clip: item, fragments: fragments,
                visible: left...right, minimumSpacing: 10 / max(0.001, scale)).map { ($0 - left) * scale }
        } else { seams = [] }
        return
                RemoteNativeGridItem(clip: clip, width: itemWidth, height: itemHeight, color: track.color, nameColor: track.nameColor ?? 0xffffff,
                    scrolling: scrolling,
                    sourceFraction: (left - clip.start) / max(0.001, clip.duration),
                    visibleFraction: (right - left) / max(0.001, clip.duration),
                    mute: { control(.clipMute, clip.id, 0) },
                    openVolume: { openVolume?(clip.id) }, local: local, headersHidden: headersHidden, trackSilenced: track.silenced == true,
                    highlightHeader: local && selectedItems.contains(clip.id) && nativeTrack.map { item?.hasSelectableMediaHeader(on: $0) == true } == true,
                    lyric: nativeTrack.flatMap { track in item.flatMap { $0.isTeleprompterLyric(on: track) ? ($0.text ?? "") : nil } },
                    nativeClip: item, nativeKind: nativeTrack?.kind, itemMixLocked: itemMixLocked,
                    invertedWaveformColors: local && invertWaveformColors && nativeTrack.map { track in
                        item.map { TimelineItemWaveformColors.hasWaveform($0, track: track) } ?? false
                    } == true,
                    clickBeats: nativeClickBeats(clip, left: left, right: right, width: itemWidth, sections: drawing?.tempoSections),
                    loopSeams: seams,
                    itemTitle: local ? item.map { TimelineItemPlaybackRate.title(clip.name, rates: fragments?.map(\.audioRate) ?? [$0.audioRate]) } : nil,
                    itemMix: { parameter, value, finished, cancelled in itemMix?(clip.id, parameter, value, finished, cancelled) },
                    itemPhase: { itemPhase?(clip.id) },
                    nativeWaveform: nativeDirectory != nil && item.map { !$0.isImage && ($0.audioFile ?? nativeTrack?.audioFile) != nil } == true,
                    select: local ? { scrolling.selectedItem = clip.id; selectTrack?() } : nil,
                    openMenu: openItemMenu.map { callback in { callback(clip.id) } }, openFX: openItemFX.map { callback in { callback(clip.id) } })
    }
    var body: some View {
        let drawing = resizing == nil ? preparedTrack : previewTrack.map {
            IpadTimelineTrackContent($0, tempoSections: preparedTrack?.tempoSections ?? [])
        }
        let itemGeometry = IpadNativeItemGeometry(track: local ? previewTrack : nil, remoteTrack: track, scale: heightScale,
            minimumRowHeight: RemoteNativeGridMetrics.minimumTrackHeight(local: local), preparedLanes: drawing?.lanes)
        ZStack(alignment: .topLeading) {
            // The shared grid is behind every item, including Remote rows.
            Color.clear
            if local && track.emphasized == true {
                remoteColor(track.color).opacity(0.16).saturation(track.silenced == true ? 0 : 1).allowsHitTesting(false)
            }
            ForEach(previewClips.filter { hasRegion && $0.start < end && $0.start + $0.duration > start && (!local || RecordingLaneLayout.shared.items[$0.id] == nil) }) { clip in
                let left = max(start, clip.start), right = min(end, clip.start + clip.duration)
                let itemWidth = max(0, (right - left) / span * width)
                gridItem(clip, width: itemWidth, height: itemGeometry.height(clip.id), left: left, right: right, drawing: drawing)
                    .equatable()
                    .overlay {
                        if local && selectedItems.contains(clip.id) {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 1.5).allowsHitTesting(false)
                        }
                    }
                    .frame(width: itemWidth, height: itemGeometry.height(clip.id))
                    .offset(x: (left - start) / span * width, y: itemGeometry.offset(clip.id, fallbackLane: clip.lane ?? 0))
            }
            if local, let drawing, let nativeSong, let nativeDirectory {
                IpadNativeWaveformRow(drawing: drawing, song: nativeSong, remoteTrack: track, directory: nativeDirectory,
                    start: start, end: end, span: span, width: width, itemGeometry: itemGeometry, revision: nativeRevision, invertWaveformColors: invertWaveformColors)
                    .allowsHitTesting(false)
            }
            if local, let nativeTrack {
                let rowHeight = itemGeometry.rowHeight
                let scale = width / max(0.001, span)
                RecordingGridOverlay(visibleRect: CGRect(x: start * scale, y: 0, width: width, height: rowHeight),
                    tracks: [nativeTrack], offsets: [0], heights: [rowHeight], rulerHeight: 0,
                    scale: scale, alignsToViewport: true, itemInset: IpadNativeItemGeometry.itemInset).allowsHitTesting(false)
            }
            if local, resizeEnabled, let nativeTrack, nativeTrack.kind != .click {
                ForEach(nativeTrack.clips.filter { selectedItems.contains($0.id) && $0.startTime < end && $0.startTime + $0.duration > start }) { item in
                    ForEach([true, false], id: \.self) { fadeIn in
                        let duration = (fadeIn ? item.fadeIn : item.fadeOut) ?? 0
                        let displayedFade = fadePreview?.id == item.id && fadePreview?.fadeIn == fadeIn ? fadePreview!.value : duration
                        let edge = item.startTime + (fadeIn ? displayedFade : item.duration - displayedFade)
                        if edge >= start && edge <= end {
                            IpadItemResizeHandle(left: fadeIn, interactionID: interactionID, showsGrip: false, changed: { delta, finished, cancelled in
                                let value = cancelled ? duration : min(item.duration, max(0, duration + (fadeIn ? delta : -delta) * span / max(1, width)))
                                fadePreview = finished || cancelled ? nil : (item.id, fadeIn, value)
                                itemFade?(item.id, fadeIn, value, finished || cancelled)
                            })
                            .overlay(Image(systemName: fadeIn ? "arrow.up.right" : "arrow.down.right").font(.system(size: 10)).foregroundStyle(JarasTheme.green).allowsHitTesting(false))
                            .frame(width: 20, height: 20)
                            .offset(x: min(width - 20, max(0, (edge - start) / span * width - 10)),
                                    y: itemGeometry.offset(item.id, fallbackLane: 0) + GridSelectionItem.headerHeight)
                        }
                    }
                }
            }
            if local, resizeEnabled, !movementLocked, let selectedItem, let clip = previewClips.first(where: { $0.id == selectedItem }) {
                let laneHeight = itemGeometry.height(clip.id)
                ForEach([true, false], id: \.self) { left in
                    let edge = left ? clip.start : clip.start + clip.duration
                    let handle = IpadItemResizeHandleLayout(edge: (edge - start) / span * width, viewportWidth: width)
                    if (edge >= start && edge <= end) || resizing?.original.id == clip.id {
                        IpadItemResizeHandle(left: left, interactionID: interactionID, gripX: handle.gripX, showsGrip: handle.showsGrip, touchEnabled: touchItemEditing, changed: { delta, finished, cancelled in
                            resize(clip.id, left: left, translation: delta, finished: finished, cancelled: cancelled)
                        }).id(clip.id).frame(width: handle.width, height: max(0, laneHeight - GridSelectionItem.headerHeight - 2))
                            .offset(x: handle.origin,
                                    y: itemGeometry.offset(clip.id, fallbackLane: clip.lane ?? 0) + GridSelectionItem.headerHeight + 1)
                    }
                }
            }
        }.frame(width: width, height: itemGeometry.rowHeight, alignment: .topLeading)
            .onChange(of: track.id) { _ in resizing = nil; sharedResizePreview = nil; fadePreview = nil }
            .onChange(of: interactionID) { _ in resizing = nil }
            .onChange(of: project) { _ in resizing = nil }
            .onChange(of: song) { _ in resizing = nil }
            .onChange(of: selectedItem) { _ in resizing = nil }
            .onChange(of: resizeEnabled) { if !$0 { resizing = nil } }
            .onChange(of: movementLocked) { if $0 { resizing = nil } }
            .onDisappear { resizing = nil; fadePreview = nil }
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1 / displayScale).allowsHitTesting(false) }
            .accessibilityLabel(track.name + ", clipes")
    }}
/// Reuse the desktop PCM cache, channel selection, tempo fragments and Metal
/// strokes. Panning/zooming changes transforms, not a synthetic peak drawing.
private struct IpadNativeWaveformRow: View {
    let drawing: IpadTimelineTrackContent
    let song: Song
    let remoteTrack: DAWRemoteState.Track
    let directory: URL
    let start: Double
    let end: Double
    let span: Double
    let width: CGFloat
    let itemGeometry: IpadNativeItemGeometry
    let revision: UInt64
    var invertWaveformColors = false
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var cache = TimelineAudioWaveform.shared
    @State private var owner = TimelineWaveformVertexOwner()
    var body: some View {
        let scale = width / max(0.001, span)
        let track = drawing.track
        let viewport = CGRect(x: start * scale, y: 0, width: width, height: itemGeometry.rowHeight)
        let rgb = TrackNameContrast.components(track.color ?? 0x705264, emphasized: false)
        let gray = TimelineItemWaveformColors.normalGray
        let items = drawing.visibleClips(from: start, to: end).compactMap { clip -> TimelineWaveformItem? in
            guard let source = drawing.source(clip, directory: directory) else { return nil }
            return TimelineWaveformItem(clip: clip, fragments: drawing.segments(clip, song: song), url: source.url,
                rect: CGRect(x: clip.startTime * scale, y: itemGeometry.offset(clip.id),
                             width: clip.duration * scale, height: itemGeometry.height(clip.id)),
                gray: gray, sourcePath: source.path, mediaSource: source,
                tint: invertWaveformColors && TimelineItemWaveformColors.hasWaveform(clip, track: track)
                    ? TimelineItemWaveformColors.ink(rgb: SIMD4(Float(rgb.red), Float(rgb.green), Float(rgb.blue), 1),
                        silenced: remoteTrack.silenced == true || clip.muted == true) : nil)
        }
        MetalWaveformView(frame: TimelineMetalWaveformFrameBuilder.make(items: items, viewport: viewport,
            scale: scale, cache: cache, owner: owner,
            contentRevision: Int(truncatingIfNeeded: revision) ^ track.id.hashValue, pixelDensity: displayScale))
            .frame(width: width, height: viewport.height).clipped()
            .allowsHitTesting(false)
    }
}
private struct RemoteNativeLoopOutline: Shape {
    let seams: [Double]
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = rect.width < 20 ? 0 : 3
        guard !seams.isEmpty else { return Path(roundedRect: rect, cornerRadius: radius) }
        var path = Path(); let depth = min(5, rect.height / 3)
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        for seam in seams.reversed() {
            let x = rect.minX + CGFloat(seam)
            guard x > rect.minX + radius, x < rect.maxX - radius else { continue }
            path.addLine(to: CGPoint(x: min(rect.maxX - radius, x + 4), y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY - depth))
            path.addLine(to: CGPoint(x: max(rect.minX + radius, x - 4), y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: rect.origin)
        path.closeSubpath(); return path
    }
}
private struct RemoteNativeGridItem: View, Equatable {
    let clip: DAWRemoteState.Clip
    let width: CGFloat
    let height: CGFloat
    let color: UInt32
    let nameColor: UInt32
    let scrolling: RemoteTrackScrollController
    let sourceFraction: Double
    let visibleFraction: Double
    let mute: () -> Void
    let openVolume: () -> Void
    var local = false
    var headersHidden = false
    var trackSilenced = false
    var highlightHeader = false
    var lyric: String?
    var nativeClip: AudioClip? = nil
    var nativeKind: TrackKind? = nil
    var itemMixLocked = false
    var invertedWaveformColors = false
    var clickBeats: [Double] = []
    var loopSeams: [Double] = []
    var itemTitle: String? = nil
    var itemMix: ((IpadItemMixParameter, Double, Bool, Bool) -> Void)? = nil
    var itemPhase: (() -> Void)? = nil
    var nativeWaveform = false
    var select: (() -> Void)? = nil
    var openMenu: (() -> Void)? = nil
    var openFX: (() -> Void)? = nil
    @Environment(\.isEnabled) private var controlsEnabled
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clip == rhs.clip && lhs.width == rhs.width && lhs.height == rhs.height && lhs.color == rhs.color &&
            lhs.highlightHeader == rhs.highlightHeader && lhs.lyric == rhs.lyric &&
            lhs.nameColor == rhs.nameColor && lhs.scrolling === rhs.scrolling &&
            lhs.sourceFraction == rhs.sourceFraction && lhs.visibleFraction == rhs.visibleFraction &&
            lhs.invertedWaveformColors == rhs.invertedWaveformColors && lhs.local == rhs.local && lhs.headersHidden == rhs.headersHidden && lhs.trackSilenced == rhs.trackSilenced && lhs.nativeClip == rhs.nativeClip && lhs.itemMixLocked == rhs.itemMixLocked && lhs.nativeKind == rhs.nativeKind && lhs.clickBeats == rhs.clickBeats && lhs.nativeWaveform == rhs.nativeWaveform && lhs.loopSeams == rhs.loopSeams && lhs.itemTitle == rhs.itemTitle && (lhs.openMenu != nil) == (rhs.openMenu != nil) &&
            (lhs.openFX != nil) == (rhs.openFX != nil)
    }
    var body: some View {
        let headerHeight = min(local ? GridSelectionItem.headerHeight : 28 * GridSelectionItem.headerScale, height)
        let headerScale = width / max(0.001, clip.duration * visibleFraction)
        let pinnedHeader = GridSelectionItem.pinsHeader(pixelsPerSecond: headerScale)
        let headerSourceOffset = pinnedHeader ? 0 : max(0, sourceFraction * clip.duration * headerScale)
        let silenced = trackSilenced || clip.muted == true
        let itemColor = silenced ? Color(white: 0.55) : remoteColor(color)
        let blackTitle = highlightHeader || TimelineItemWaveformColors.usesBlackTitle(trackColor: color, silenced: silenced, inverted: invertedWaveformColors)
        let titleInk: Color = blackTitle ? .black : .white
        let waveformColor: Color? = invertedWaveformColors && !silenced ? remoteColor(color) : (local ? TimelineItemWaveformColors.normal : nil)
        VStack(spacing: 0) {
            if headersHidden && pinnedHeader {
                Color.clear.frame(width: width, height: headerHeight).allowsHitTesting(false)
            } else if local, let nativeClip {
                IpadItemHeader(clip: nativeClip, editable: nativeKind == .standard || nativeClip.isProjectionMedia,
                    textEditable: nativeKind?.isText == true && !nativeClip.isProjectionMedia,
                    interactionID: scrolling.pointerReset, itemTitle: lyric == nil ? itemTitle : "",
                    pinsToViewport: pinnedHeader, sourceStartOffset: headerSourceOffset, mixLocked: itemMixLocked, blackTitle: blackTitle,
                    mix: { itemMix?($0, $1, $2, $3) }, mute: mute, phase: { itemPhase?() },
                    fx: { openFX?() }, menu: { openMenu?() })
                    .frame(width: width, height: headerHeight)
            } else {
            HStack(spacing: 4) {
                Button(action: mute) { Text(verbatim: "M").font(.jarasSystem(size: local ? GridSelectionItem.headerFontSize : 11 * GridSelectionItem.headerScale, weight: .bold)).frame(width: (local ? 17 : 28) * GridSelectionItem.headerScale, height: headerHeight) }
                    .buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(Color.white)
                    .background(clip.muted == true ? TrackMixerButtonAppearance.muted : TrackMixerButtonAppearance.normal)
                    .cornerRadius(TrackMixerButtonAppearance.radius)
                    .accessibilityLabel("Mute do item " + clip.name)
                if let openFX {
                    Button("FX", action: openFX).font(.jarasSystem(size: 10, weight: .semibold))
                        .frame(width: local ? 20 * GridSelectionItem.headerScale : 32, height: headerHeight).contentShape(Rectangle()).buttonStyle(.plain).foregroundStyle(Color.white)
                        .background(TrackMixerButtonAppearance.normal).cornerRadius(TrackMixerButtonAppearance.radius)
                }
                Text(verbatim: itemTitle ?? clip.name).font(.jarasSystem(size: local ? GridSelectionItem.headerFontSize : 10 * GridSelectionItem.headerScale, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(titleInk).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 3).frame(width: width + headerSourceOffset, height: headerHeight, alignment: .leading)
                .offset(x: -headerSourceOffset).frame(width: width, alignment: .leading).clipped()
            }
            if let lyric {
                ItemTextColors.view(lyric, fallback: .black)
                    .font(.jarasSystem(size: 12, weight: .semibold))
                    .padding(.horizontal, 5)
                    .frame(width: width, height: max(0, height - headerHeight), alignment: .topLeading)
                    .clipped().allowsHitTesting(false)
            } else {
            Canvas { context, size in
                guard !nativeWaveform else { return }
                var wave = Path()
                if local && nativeKind == .click {
                    let middle = size.height / 2, amplitude = size.height * 0.45
                    for x in clickBeats {
                        wave.move(to: CGPoint(x: x, y: middle - amplitude))
                        wave.addLine(to: CGPoint(x: x + 2, y: middle))
                        wave.addLine(to: CGPoint(x: x, y: middle + amplitude)); wave.closeSubpath()
                    }
                    context.fill(wave, with: .color(waveformColor ?? (silenced ? .gray : Color(white: 0.8))))
                    return
                }
                let seed = local ? 0 : clip.id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % 997 }
                let peaks = clip.waveform ?? []
                let count = max(1, Int(size.width / 3))
                for index in 0..<count {
                    let fraction = sourceFraction + Double(index) / Double(count) * visibleFraction
                    let amplitude: Double
                    if local {
                        guard !peaks.isEmpty else { continue }
                        if let length = clip.waveformLoopLength, length > 0 {
                            let source = (clip.waveformOffset ?? 0) + fraction * clip.duration * (clip.waveformRate ?? 1)
                            let phase = ((source.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)) / length
                            amplitude = min(1, peaks[min(peaks.count - 1, Int(phase * Double(peaks.count)))])
                        } else {
                            let first = min(peaks.count - 1, max(0, Int(fraction * Double(peaks.count))))
                            let last = min(peaks.count, max(first + 1, Int((fraction + visibleFraction / Double(count)) * Double(peaks.count))))
                            amplitude = min(1, peaks[first..<last].max() ?? 0)
                        }
                    } else {
                        amplitude = DAWRemoteItemWaveform.amplitude(seed: seed, fraction: fraction, gain: clip.gain)
                    }
                    let height = size.height * amplitude
                    wave.addRect(CGRect(x: CGFloat(index) * 3, y: (size.height - height) / 2, width: 1.5, height: height))
                }
                context.fill(wave, with: .color(waveformColor ?? (silenced ? .gray : remoteColor(nameColor).opacity(0.75))))
            }.frame(height: max(0, height - headerHeight)).allowsHitTesting(false)
            }
        }.frame(width: width, height: height, alignment: .topLeading).clipped()
            .background(alignment: .top) {
                if highlightHeader { Color(white: GridSelectionItem.selectedHeaderWhite).frame(height: headerHeight) }
            }
            .background {
                if invertedWaveformColors && !silenced { TimelineItemWaveformColors.invertedBackground }
                else { itemColor }
            }
            .clipShape(RemoteNativeLoopOutline(seams: loopSeams))
            .overlay(RemoteNativeLoopOutline(seams: loopSeams).stroke(itemColor.opacity(0.75), lineWidth: 0.6).allowsHitTesting(false))
            .modifier(RemoteItemMenuGesture(local: local, item: clip.id, selection: scrolling.itemSelection.items))
            .background {
                if local {
                    IpadItemMenuAnchor(id: clip.id).allowsHitTesting(false)
                    RemoteGridItemHoldProbe(controller: scrolling, tap: select, hold: { openMenu?() })
                } else if !local {
                    RemoteGridItemHoldProbe(controller: scrolling, tap: nil, hold: {
                        if controlsEnabled { openVolume() }
                    })
                }
            }
            .accessibilityLabel(clip.name).accessibilityAction(named: "Editar item") {
                if local { openMenu?() } else if controlsEnabled { openVolume() }
            }
    }
}
// Own the light scrim so phone and tablet do not add a system sheet backdrop.
private struct RemoteItemEditorPresentation: UIViewControllerRepresentable {
    let clip: DAWRemoteState.Clip?
    let color: UInt32
    let setGain: (Double) -> Void
    let mute: () -> Void
    let close: () -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter() }
    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.presentation = self
        DispatchQueue.main.async { [weak controller] in controller?.refresh() }
    }
    static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
        controller.presentation = nil
        controller.editor?.dismiss(animated: false)
        controller.editor = nil
    }

    final class Presenter: UIViewController {
        var presentation: RemoteItemEditorPresentation?
        var editor: UIHostingController<RemoteItemEditorOverlay>?
        override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .clear }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); refresh() }
        func refresh() {
            guard let presentation else { return }
            guard let clip = presentation.clip else {
                editor?.dismiss(animated: false)
                editor = nil
                return
            }
            let content = RemoteItemEditorOverlay(clip: clip, color: presentation.color,
                setGain: presentation.setGain, mute: presentation.mute,
                close: presentation.close)
            if let editor { editor.rootView = content; return }
            guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            let controller = UIHostingController(rootView: content)
            controller.modalPresentationStyle = .overFullScreen
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            controller.view.accessibilityViewIsModal = true
            editor = controller
            present(controller, animated: false)
        }
    }
}
private struct RemoteItemEditorOverlay: View {
    let clip: DAWRemoteState.Clip
    let color: UInt32
    let setGain: (Double) -> Void
    let mute: () -> Void
    let close: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
                .accessibilityHidden(true)
            RemoteNativeItemEditor(clip: clip, color: color, setGain: setGain, mute: mute, close: close).id(clip.id)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).preferredColorScheme(.dark)
    }
}
private struct RemoteItemMenuGesture: ViewModifier {
    let local: Bool
    let item: UUID
    let selection: Set<UUID>
    @ViewBuilder func body(content: Content) -> some View {
        if local {
            content.overlay {
                GeometryReader { geometry in
                    // Keep the menu recognizer off the header's volume/pan
                    // controls so holding a knob cannot open an editor.
                    IpadItemBodyContextMenu { IpadItemContextMenu.commands(item, selection) }
                        .frame(height: max(0, geometry.size.height - GridSelectionItem.headerHeight))
                        .offset(y: GridSelectionItem.headerHeight)
                }
            }
        } else {
            content.contentShape(Rectangle())
        }
    }
}
/// A compact inspector anchored to the item, with the same fader and mute
/// behavior as the grid. Its stable item identity survives bridge updates.
private struct RemoteNativeItemEditor: View {
    let clip: DAWRemoteState.Clip
    let color: UInt32
    let setGain: (Double) -> Void
    let mute: () -> Void
    let close: () -> Void
    @State private var gainPreview: Double?
    private var confirmedDecibels: Double { clip.gain == 0 ? -60 : min(24, max(-59.9, 20 * log10(max(0.000001, clip.gain ?? 1)))) }
    private var decibels: Double { gainPreview ?? confirmedDecibels }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(remoteColor(color)).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Item volume").font(.jarasSystem(size: 10, weight: .medium)).foregroundStyle(JarasTheme.secondary)
                    Text(verbatim: clip.name).font(.jarasSystem(size: 13, weight: .semibold)).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.jarasSystem(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28).background(RemoteSurface.display).cornerRadius(5)
                }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Close")
            }
            HStack(spacing: 10) {
                Text(verbatim: (decibels <= -60 ? "−∞" : String(format: "%+.1f", decibels)) + " dB")
                    .font(.jarasSystem(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(JarasTheme.green).frame(width: 67, height: 34)
                    .background(RemoteSurface.display).cornerRadius(5)
                RemoteNativeSlider(value: decibels, range: -60...24, height: 36) {
                    gainPreview = $0
                    setGain($0 <= -60 ? 0 : pow(10, $0 / 20))
                }.accessibilityLabel("Volume do item " + clip.name)
                Button(action: mute) {
                    Text(verbatim: "M").font(.jarasSystem(size: 13, weight: .bold)).frame(width: 38, height: 34)
                        .foregroundStyle(clip.muted == true ? Color.white : JarasTheme.text)
                        .modifier(RemoteControlSurface(color: clip.muted == true ? Color.red.opacity(0.8) : nil, radius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(clip.muted == true ? Color.red : JarasTheme.line))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Mute do item " + clip.name)
            }
        }.padding(14).frame(width: 330).fixedSize(horizontal: false, vertical: true)
            .background(RemoteSurface.panel).foregroundStyle(JarasTheme.text)
            .onChange(of: clip.gain) { _ in
                if let gainPreview, abs(gainPreview - confirmedDecibels) < 0.05 { self.gainPreview = nil }
            }
            .task(id: gainPreview) {
                guard gainPreview != nil else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                gainPreview = nil
            }
    }
}
private func remoteColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
}
struct RemoteNativeSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 28
    var linked = false
    var resetValue = 0.0
    var locksScrolling = false
    var trackID: UUID? = nil
    var meter: TrackMeterLevel? = nil
    var mixerFader = false
    var selectionScope: UUID? = nil
    var showsValueTooltip = false
    var preview: ((Double) -> Void)? = nil
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var railTheme = JarasInterfaceTheme.defaultTheme
    let change: (Double) -> Void
    @State private var editing = false
    @State private var draft = 0.0
    @State private var pending = false
    @State private var commitID = UUID()
    @State private var lastSentAt = 0.0
    @State private var draftTrack: UUID?
    @State private var faderSelected = false
    @State private var pointerOver = false
    private var displayed: Double { draftTrack == trackID && (editing || pending) ? draft : value }
    private func commit(_ next: Double) {
        draftTrack = trackID
        draft = next; editing = false
        pending = abs(value - next) > 0.000001
        commitID = UUID()
        change(next)
    }
    private var usesFixedUpperSpan: Bool { mixerFader && trackID != nil && range == -60...12 }
    private func value(at x: CGFloat, width: CGFloat) -> Double {
        let travel = max(1, width - 12)
        let fraction = min(1, max(0, (x - 6) / travel))
        if usesFixedUpperSpan {
            return HorizontalTrackFaderScale.decibels(fraction: fraction, travel: travel)
        }
        return range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
    }
    private func update(_ x: CGFloat, width: CGFloat) {
        draft = value(at: x, width: width)
        if !editing || draftTrack != trackID { lastSentAt = 0 }
        draftTrack = trackID
        editing = true
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSentAt >= 0.05 { lastSentAt = now; (preview ?? change)(draft) }
    }
    var body: some View {
        GeometryReader { geometry in
            let fraction = usesFixedUpperSpan
                ? HorizontalTrackFaderScale.fraction(decibels: displayed, travel: geometry.size.width - 12)
                : CGFloat(min(1, max(0, (displayed - range.lowerBound) / (range.upperBound - range.lowerBound))))
            ZStack(alignment: .leading) {
                Group {
                    if let meter {
                        IpadMixerMeter(meter: meter, preparesOffscreen: true, linked: linked, fixedUpperSpan: usesFixedUpperSpan)
                    } else if mixerFader {
                        Capsule()
                            .fill(Color(cgColor: linked ? MixerMeterStyle.linkedBackground : MixerMeterStyle.railBackground(for: railTheme)))
                            .overlay { Capsule().strokeBorder(Color(cgColor: MixerMeterStyle.railBorder), lineWidth: 0.75) }
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(linked ? JarasTheme.yellow : Color.white.opacity(0.22))
                    }
                }.frame(height: mixerFader || meter != nil ? MixerMeterStyle.railThickness : 6).padding(.horizontal, 6)
                Group {
                    if mixerFader {
                        MixerFaderThumb(vertical: false, linked: linked, selected: faderSelected)
                    } else {
                        RemoteSurface.fill(linked ? JarasTheme.green : Color(white: 0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 2)).frame(width: 12, height: 18)
                            .overlay(Rectangle().fill(Color(white: 0.33)).frame(width: 1, height: 12))
                    }
                }.frame(width: 12).offset(x: CGFloat(fraction) * max(1, geometry.size.width - 12))
            }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .overlay(RemoteSliderTouchInput(locksScrolling: locksScrolling, trackID: trackID,
                    selectionScope: selectionScope,
                    thumbPosition: mixerFader ? 6 + CGFloat(fraction) * max(1, geometry.size.width - 12) : nil,
                    selectionChanged: mixerFader ? { faderSelected = $0 } : nil,
                    changed: { update($0, width: geometry.size.width) },
                    ended: { commit(value(at: $0, width: geometry.size.width)) },
                    reset: { commit(resetValue) }))
        }.frame(height: height)
            .onHover { pointerOver = $0 }
            .overlay(alignment: .top) {
                if showsValueTooltip && (editing || pointerOver) {
                    Text(displayed <= -60 ? "−∞ dB" : String(format: "%+.1f dB", displayed))
                        .font(.jarasSystem(size: 10, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(hex: 0x292929), in: RoundedRectangle(cornerRadius: 4))
                        .offset(y: -17).allowsHitTesting(false)
                }
            }
            .onChange(of: trackID) { _ in
                editing = false
                pending = false
                commitID = UUID()
            }
            .onChange(of: value) { confirmed in
                if !editing, abs(confirmed - draft) <= 0.000001 { pending = false }
            }
            .task(id: commitID) {
                guard pending else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                pending = false
            }
            .accessibilityElement().accessibilityValue(String(format: "%.1f", displayed))
            .accessibilityAdjustableAction { direction in
                let step = range.upperBound > 1 ? 0.5 : 0.05
                let next = min(range.upperBound, max(range.lowerBound, displayed + (direction == .increment ? step : -step)))
                commit(next)
            }
    }
}
/// Tap and pan are distinct native gestures: a double tap never commits a
/// positional drag afterwards. The single tap waits for the double-tap decision.
struct RemoteSliderTouchInput: UIViewRepresentable {
    var locksScrolling = false
    var trackID: UUID? = nil
    var axis: Axis = .horizontal
    var selectionScope: UUID? = nil
    var thumbPosition: CGFloat? = nil
    var selectionChanged: ((Bool) -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let reset: () -> Void
    func makeUIView(context: Context) -> RemoteSliderTouchView { RemoteSliderTouchView() }
    func updateUIView(_ view: RemoteSliderTouchView, context: Context) {
        view.rebind(trackID, scope: selectionScope)
        view.changed = changed; view.ended = ended; view.reset = reset; view.locksScrolling = locksScrolling
        view.axis = axis
        view.thumbPosition = thumbPosition; view.selectionChanged = selectionChanged
        if !enabled { view.clearSelection(deferred: true) }
        view.isUserInteractionEnabled = enabled
    }
}

/// Observe the next touch without taking it away from the tapped control or scroll view.
private final class OutsideTouchObserver: UIGestureRecognizer {
    let isInside: (UITouch) -> Bool
    let outside: () -> Void

    init(isInside: @escaping (UITouch) -> Bool, outside: @escaping () -> Void) {
        self.isInside = isInside
        self.outside = outside
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.contains(where: { !isInside($0) }) { outside() }
        state = .failed
    }
}

final class RemoteSliderTouchView: UIView, UIGestureRecognizerDelegate {
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat) -> Void)?
    var reset: (() -> Void)?
    var locksScrolling = false
    var axis: Axis = .horizontal
    var thumbPosition: CGFloat?
    var selectionChanged: ((Bool) -> Void)?
    private var outsideTouch: OutsideTouchObserver?
    private var dragOrigin: CGFloat?
    private var needsSelection: Bool { selectionChanged != nil }
    private var isSelected: Bool { outsideTouch != nil }

    private func selectFader() {
        guard !isSelected, let window else { return }
        let observer = OutsideTouchObserver(isInside: { [weak self] touch in
            guard let self else { return true }
            return touch.view === self || touch.view?.isDescendant(of: self) == true
        }, outside: { [weak self] in self?.clearSelection() })
        outsideTouch = observer
        window.addGestureRecognizer(observer)
        selectionChanged?(true)
    }

    func clearSelection(deferred: Bool = false) {
        guard let observer = outsideTouch else { return }
        observer.view?.removeGestureRecognizer(observer)
        outsideTouch = nil
        if deferred {
            let notify = selectionChanged
            DispatchQueue.main.async { [weak self] in
                if self?.isSelected != true { notify?(false) }
            }
        } else {
            selectionChanged?(false)
        }
    }
    private final class ScrollLock { weak var view: UIScrollView?; init(_ view: UIScrollView) { self.view = view } }
    private var scrollLocks: [ScrollLock] = []
    private func lockAncestorScrolling() {
        guard locksScrolling, scrollLocks.isEmpty else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled { scrollLocks.append(ScrollLock(scroll)); scroll.isScrollEnabled = false }
            ancestor = view.superview
        }
    }
    func restoreScrolling() { for lock in scrollLocks { lock.view?.isScrollEnabled = true }; scrollLocks.removeAll() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if outsideTouch?.view !== window { clearSelection(deferred: true) }
        if window == nil { restoreScrolling() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { restoreScrolling(); super.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !(gestureRecognizers ?? []).contains(where: { $0 is UIPanGestureRecognizer && ($0.state == .began || $0.state == .changed) }) { restoreScrolling() }
        super.touchesCancelled(touches, with: event)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if needsSelection && !isSelected {
            return (gestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 1
        }
        lockAncestorScrolling()
        return true
    }
    private var lastDragPosition: CGFloat?
    private var trackID: UUID?
    private var selectionScope: UUID?
    func rebind(_ id: UUID?, scope: UUID?) {
        guard trackID != id || selectionScope != scope else { return }
        trackID = id; selectionScope = scope
        clearSelection(deferred: true)
        changed = nil; ended = nil; reset = nil
        lastDragPosition = nil; dragOrigin = nil
        restoreScrolling()
        for recognizer in gestureRecognizers ?? [] where recognizer.isEnabled {
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        doubleTap.numberOfTapsRequired = 2; doubleTap.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:))); tap.delegate = self
        tap.require(toFail: doubleTap)
        addGestureRecognizer(pan); addGestureRecognizer(doubleTap); addGestureRecognizer(tap)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func resetTapped() {
        if !needsSelection || isSelected { reset?() }
        restoreScrolling()
    }
    private func position(_ gesture: UIGestureRecognizer) -> CGFloat {
        if let pan = gesture as? UIPanGestureRecognizer, let dragOrigin {
            let movement = pan.translation(in: self)
            return dragOrigin + (axis == .vertical ? movement.y : movement.x)
        }
        let point = gesture.location(in: self)
        return axis == .vertical ? point.y : point.x
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if needsSelection { selectFader() } else { ended?(position(gesture)) }
        restoreScrolling()
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        defer {
            if [.ended, .cancelled, .failed].contains(gesture.state) {
                dragOrigin = nil
                restoreScrolling()
            }
        }
        if gesture.state == .began { dragOrigin = thumbPosition }
        switch gesture.state {
        case .began, .changed:
            let current = position(gesture)
            lastDragPosition = current
            changed?(current)
        case .ended:
            lastDragPosition = nil; ended?(position(gesture))
        case .cancelled, .failed:
            if let current = lastDragPosition { lastDragPosition = nil; ended?(current) }
        default: break
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard !needsSelection || isSelected else { return false }
        if locksScrolling { return true }
        let velocity = pan.velocity(in: self)
        return axis == .vertical ? abs(velocity.y) >= abs(velocity.x) : abs(velocity.x) >= abs(velocity.y)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }
}

private func remoteDecibelText(_ gain: Double) -> String {
    gain <= 0 ? "−∞" : String(format: "%+.1f", DAWRemoteFaderScale.decibels(gain))
}
// Keep Cancel visibly yellow even when no section is queued. The disabled
// state still prevents sending a command; only the system dimming is omitted.
private struct RemoteCancelSectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .modifier(RemoteControlSurface(color: Color(hex: 0xffd600), radius: 4))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct RemoteNativeTrackButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    var width: CGFloat = 26
    var touchPadding: CGFloat = 6
    var height: CGFloat = 22
    var usesTrackFace = false
    var ink: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label.font(.jarasSystem(size: 10, weight: .semibold))
            .foregroundStyle(ink ?? (activeColor == nil ? Color.white : Color.black))
            .frame(width: width, height: height)
        return Group {
            if usesTrackFace {
                label.background((activeColor ?? TrackMixerButtonAppearance.trackControl).opacity(configuration.isPressed ? 0.75 : 1),
                                 in: RoundedRectangle(cornerRadius: TrackMixerButtonAppearance.radius))
            } else {
                label.modifier(RemoteControlSurface(color: activeColor?.opacity(configuration.isPressed ? 0.75 : 1), radius: 3))
            }
        }
            .frame(width: width + touchPadding, height: height < 22 ? height : max(28, height)).contentShape(Rectangle())
    }
}

/// Native Parts docks share only the grid's free space. Preserve the original
/// right-dock behavior when the left one is hidden; with both visible, reserve
/// room for the grid and reduce the docks proportionally on narrow displays.
private struct RemoteNativePartsLayout {
    let left: DAWRemotePartsWidths
    let right: DAWRemotePartsWidths
    init(available: Double, leftRequested: Double, rightRequested: Double,
         leftVisible: Bool, rightVisible: Bool) {
        let available = available.isFinite ? max(0, available) : 0
        let handle = 22.0
        guard leftVisible else {
            left = DAWRemotePartsWidths(available: 0, requested: 0, visible: false, handle: handle)
            right = DAWRemotePartsWidths(available: available, requested: rightRequested, visible: rightVisible, handle: handle)
            return
        }
        let leftWidth = max(0, leftRequested.isFinite ? leftRequested : 240)
        let rightWidth = max(0, rightRequested.isFinite ? rightRequested : 240)
        let budget = max(0, available - min(140, available * 0.5))
        let dockCount = rightVisible ? 2.0 : 1.0
        let visibleHandle = min(handle, budget / dockCount)
        let contentBudget = max(0, budget - visibleHandle * dockCount)
        let demand = leftWidth + (rightVisible ? rightWidth : 0)
        let ratio = min(1, contentBudget / max(1, demand))
        left = DAWRemotePartsWidths(available: visibleHandle + leftWidth * ratio, requested: leftWidth, visible: true, handle: visibleHandle)
        right = DAWRemotePartsWidths(available: rightVisible ? visibleHandle + rightWidth * ratio : 0,
            requested: rightWidth, visible: rightVisible, handle: visibleHandle)
    }
}

/// Fit the actual control strip, including touch widths, row padding, edit
/// grip and folder gutter. Pan keeps its slot when the row changes height.
private struct RemoteNativeTrackControlLayout {
    static let buttonFaceWidth: CGFloat = 26
    static let buttonTouchWidth = buttonFaceWidth + 6
    private static let recordWidth: CGFloat = 32
    private static let panWidth: CGFloat = 22
    private static let gap: CGFloat = 3
    static let patchWidth: CGFloat = 36
    static let envWidth: CGFloat = 26
    let env: Bool
    let fx: Bool
    let buttonsWidth: CGFloat
    init(width: CGFloat, compact: Bool, editing: Bool, hierarchyWidth: CGFloat,
         isGroup: Bool, hasVolume: Bool, hasPan: Bool, hasRecord: Bool, hasPatch: Bool, hasFX: Bool, hasEnv: Bool = false) {
        let available = width - hierarchyWidth - (editing ? 36 : 6) - (hasVolume && compact ? 17 : 6)
            - (compact || !hasVolume ? 70 : 0) - (isGroup ? 14 : 0)
        // M/S are always present. Each extra control contributes its real
        // touch width and one 3-point gap.
        let base = 2 * Self.buttonTouchWidth + Self.gap
            + (hasRecord ? Self.recordWidth + Self.buttonTouchWidth + 2 * Self.gap : 0)
            + (compact && hasVolume ? Self.panWidth + Self.gap : 0)
        let panWidth = hasPan ? Self.panWidth + Self.gap : 0
        let fxWidth = hasFX ? Self.buttonTouchWidth + Self.gap : 0
        let patchWidth = hasPatch ? Self.patchWidth + Self.gap : 0
        fx = hasFX && available >= base + panWidth + patchWidth + fxWidth
        let envWidth = hasEnv ? Self.envWidth + Self.gap : 0
        env = hasEnv && available >= base + panWidth + patchWidth + fxWidth + envWidth
        buttonsWidth = base + panWidth + patchWidth + (fx ? fxWidth : 0) + (env ? envWidth : 0)
    }
}
/// Keep the presented scroll view independent of transport/position snapshots.
/// Stable playlist IDs retain its scroll position while the bridge updates.
private struct RemoteNativePlaylistPicker: View, Equatable {
    let playlists: [DAWRemoteState.Song]
    let selected: UUID?
    let choose: (UUID?) -> Void
    let close: () -> Void
    let edit: (UUID) -> Void
    let duplicate: (UUID) -> Void
    let remove: (UUID) -> Void
    let copy: (UUID?) -> Void
    var add: ((UUID) -> Void)? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.playlists == rhs.playlists && lhs.selected == rhs.selected }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet").foregroundStyle(JarasTheme.green)
                Text(verbatim: "Playlists").font(.jarasSystem(size: 16, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.jarasSystem(size: 12, weight: .bold)).frame(width: 30, height: 30) }
                    .buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Fechar")
            }.padding(.horizontal, 14).frame(height: 54).background(RemoteSurface.panel)
            Rectangle().fill(JarasTheme.line).frame(height: 1)
            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                    row(id: nil, name: JarasLocalization.string("All regions"))
                    ForEach(playlists) { playlist in row(id: playlist.id, name: playlist.name) }
                }.padding(10)
            }
        }.foregroundStyle(JarasTheme.text).background(RemoteSurface.background)
            .frame(width: 310, height: min(420, CGFloat(playlists.count + 1) * 47 + 75))
            .preferredColorScheme(.dark)
    }
    private func row(id: UUID?, name: String) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(id == selected ? JarasTheme.green : JarasTheme.secondary.opacity(0.4)).frame(width: 3, height: 22)
                Text(verbatim: name).font(.jarasSystem(size: 14, weight: id == selected ? .semibold : .medium))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if id == selected { Image(systemName: "checkmark").font(.jarasSystem(size: 12, weight: .bold)).foregroundStyle(JarasTheme.green) }
            }.padding(.horizontal, 12).frame(height: 42)
                .background(RemoteSurface.fill(id == selected ? JarasTheme.green.opacity(0.10) : JarasTheme.panel))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(id == selected ? JarasTheme.green.opacity(0.5) : JarasTheme.line))
        }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityAddTraits(id == selected ? .isSelected : [])
            .contextMenu {
                Button("Copy to share") { copy(id) }
                if let id {
                    Divider()
                    if let add { Button("Add regions") { add(id) } }
                    Button("Edit") { edit(id) }
                    Button("Clone playlist") { duplicate(id) }
                    Button("Delete playlist", role: .destructive) { remove(id) }
                }
            }
    }
}

private struct IpadPlaylistCreator: View {
    let regions: [DAWRemoteState.Region]
    var adding = false
    let create: (String, [UUID]) -> Bool
    let close: () -> Void
    @State private var name = ""
    @State private var query = ""
    private var filteredRegions: [DAWRemoteState.Region] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return regions.filter { term.isEmpty || $0.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    @State private var selected: [UUID] = []
    var body: some View {
        VStack(spacing: 0) {
            IpadModalHeader(title: adding ? "Add regions" : "Create playlist", close: close)
            if !adding { TextField("Name", text: $name).textFieldStyle(.roundedBorder).padding(16) }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(JarasTheme.secondary)
                TextField("Search songs", text: $query).textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear")
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(filteredRegions) { region in
                        Button {
                            if let index = selected.firstIndex(of: region.id) { selected.remove(at: index) }
                            else { selected.append(region.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(region.id) ? "checkmark.square.fill" : "square").foregroundStyle(JarasTheme.green)
                                if let index = selected.firstIndex(of: region.id) {
                                    Text(String(format: "%02d", index + 1)).monospacedDigit().foregroundStyle(JarasTheme.green)
                                }
                                Text(verbatim: region.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).contentShape(Rectangle()).background(JarasTheme.panel, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
            Divider()
            HStack {
                Button("Cancel", action: close); Spacer()
                Button(adding ? "Add regions" : "Create") {
                    if create(name, selected) { close() }
                }.disabled((!adding && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || selected.isEmpty)
            }.padding(16)
        }
    }
}

private struct RemoteSetlistEntryEditor: View {
    let close: () -> Void
    @State private var name: String
    @State private var color: Color
    let colored: Bool
    let save: (String, UInt32?) -> Void
    init(name: String, color: UInt32?, close: @escaping () -> Void, save: @escaping (String, UInt32?) -> Void) {
        _name = State(initialValue: name); _color = State(initialValue: remoteColor(color ?? 0xffffff))
        colored = color != nil; self.save = save; self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(colored ? "Editar região" : "Rename playlist").font(.jarasTitle3.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if colored { ColorPicker("Color", selection: $color, supportsOpacity: false) }
            HStack {
                Button("Cancel") { close() }
                Spacer()
                Button("Save") {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                    save(name.trimmingCharacters(in: .whitespacesAndNewlines), colored ? UInt32(r * 255) << 16 | UInt32(g * 255) << 8 | UInt32(b * 255) : nil)
                    close()
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 500)
            }.buttonStyle(StageButtonStyle(color: JarasTheme.green))
        }.padding(24).frame(maxWidth: 420).background(RemoteSurface.panel)

    }
}

/// Holding Save opens the package dialog; releasing a hold must not also save.
private struct NativeProjectShareHold: ViewModifier {
    let share: (() -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if let share {
            content.buttonStyle(IpadTapHoldButtonStyle(hold: share))
                .contextMenu {
                    Button(action: share) { Text(verbatim: "Share") }
                }
                .accessibilityAction(named: Text(verbatim: "Share"), share)
        } else { content.buttonStyle(RemoteFullAreaButtonStyle()) }
    }
}

private struct NativeRegionDrawerGesture: ViewModifier {
    let enabled: Bool
    let expanded: Bool
    let change: (Bool) -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.background(NativeRegionDrawerSwipeInput(change: change).accessibilityHidden(true))
                .accessibilityAction(named: Text(expanded ? "Close drawer" : "Open drawer")) { change(!expanded) }
        } else { content }
    }
}

private struct NativeRegionDrawerSwipeInput: UIViewRepresentable {
    let change: (Bool) -> Void

    func makeUIView(context: Context) -> NativeRegionDrawerSwipeView { NativeRegionDrawerSwipeView() }
    func updateUIView(_ view: NativeRegionDrawerSwipeView, context: Context) {
        view.change = change
        view.attach()
    }
    static func dismantleUIView(_ view: NativeRegionDrawerSwipeView, coordinator: ()) { view.detach() }
}

private final class NativeRegionDrawerSwipeView: UIView, UIGestureRecognizerDelegate {
    var change: ((Bool) -> Void)?
    private weak var scroll: UIScrollView?
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        return pan
    }()

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
    func attach() {
        guard window != nil else { detach(); return }
        var parent = superview
        while let view = parent, !(view is UIScrollView) { parent = view.superview }
        guard let host = parent as? UIScrollView else { detach(); return }
        guard scroll !== host else { return }
        detach()
        host.addGestureRecognizer(pan); scroll = host
    }
    func detach() {
        scroll?.removeGestureRecognizer(pan); scroll = nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        window != nil && bounds.contains(touch.location(in: self))
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: self)
        return NativeRegionDrawerSwipe.isHorizontal(x: velocity.x, y: velocity.y)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other === scroll?.panGestureRecognizer
    }
    @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let offset = gesture.translation(in: self)
        if let expanded = NativeRegionDrawerSwipe.expansion(x: offset.x, y: offset.y) { change?(expanded) }
    }
}

private struct RemoteRegionDrawerGesture: ViewModifier {
    let enabled: Bool
    let toggle: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            // A recognized hold wins over the button tap, so opening a drawer
            // never selects, queues or starts its parent song on release.
            content.highPriorityGesture(LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
                .onEnded { _ in toggle() })
                .accessibilityAction(named: Text("Toggle region drawer"), toggle)
        } else { content }
    }
}

/// A held scalar is reused from the host; this view has no sampling timer or moving meter.
/// Transport position updates do not invalidate the fixed readout while its value stays equal.
private struct RemotePeakReadout: View, Equatable {
    @Environment(\.jarasNativePalette) private var nativePalette
    let decibels: Double?
    let name: String
    let project: UUID
    let song: UUID?
    let target: UUID?
    var nameColor: UInt32 = 0xffffff
    let reset: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.decibels == rhs.decibels && lhs.name == rhs.name && lhs.project == rhs.project &&
            lhs.song == rhs.song && lhs.target == rhs.target && lhs.nameColor == rhs.nameColor
    }
    var body: some View {
        Button(action: reset) {
            Text(verbatim: decibels.map { String(format: "%+.2f", $0) } ?? "")
                .font(.jarasSystem(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(nativePalette && (decibels ?? -.infinity) > 0 ? Color.red : remoteColor(nameColor))
                .padding(.horizontal, 2)
                .background(nativePalette && (decibels ?? -.infinity) > 0 ? Color.black : Color.clear)
                .frame(minWidth: 34, minHeight: 12)
                .frame(height: 22).contentShape(Rectangle())
        }.buttonStyle(RemoteFullAreaButtonStyle()).disabled(decibels == nil)
            .accessibilityLabel(Text(verbatim: "Peak · " + name))
            .accessibilityValue(Text(verbatim: decibels.map { String(format: "%+.2f dB", $0) } ?? "—"))
            .accessibilityHint("Reset peak")
    }
}

private struct IpadTrackAudioContextMenu: ViewModifier {
    let enabled: Bool
    let openPatch: (() -> Void)?
    let addAudio: (() -> Void)?
    var fx: (() -> Void)? = nil
    var soundDesigner: (() -> Void)? = nil
    var group: (() -> Void)? = nil
    var ungroup: (() -> Void)? = nil
    var removeFromGroup: (() -> Void)? = nil
    var link: (() -> Void)? = nil
    var unlink: (() -> Void)? = nil
    var edit: (() -> Void)? = nil
    var icon: (() -> Void)? = nil
    var addMedia: (() -> Void)? = nil
    var duplicate: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    var count = 1
    var createMIDI: (() -> Void)?
    var componentMask: Int?
    var toggleComponent: ((TrackMixerComponent) -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.overlayPreferenceValue(IpadTrackControlsBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    let areas = IpadTrackMenuSurface.areas(in: CGRect(origin: .zero, size: proxy.size),
                                                         excluding: anchors.map { proxy[$0] })
                    ForEach(areas.indices, id: \.self) { index in
                        let area = areas[index]
                        IpadTrackMenuSurface(actions: menuActions)
                            .frame(width: area.width, height: area.height)
                            .position(x: area.midX, y: area.midY)
                    }
                }
            }
        } else { content }
    }
    private var menuActions: [IpadTrackMenuAction] {
        var actions: [IpadTrackMenuAction] = []
        func append(_ title: String, _ action: (() -> Void)?, destructive: Bool = false) {
            if let action { actions.append(IpadTrackMenuAction(title: JarasLocalization.string(title), destructive: destructive, action: action)) }
        }
        append("Patch", openPatch); append("Sound Designer", soundDesigner); append("FX", fx)
        append("Insert media", addAudio)
        if let createMIDI {
            append("Create MIDI item", createMIDI)
            actions.append(.init(title: "", destructive: false, action: {}, separator: true))
        }
        append("Create group", group); append("Ungroup", ungroup)
        append("Remove from group", removeFromGroup); append("Link tracks", link); append("Unlink tracks", unlink)
        append("Set Track Color", edit); append("Set Track Icon", icon)
        append("Add media", addMedia)
        append(count > 1 ? "Duplicate tracks" : "Duplicate track", duplicate)
        if let componentMask, let toggleComponent {
            let choices = TrackMixerComponent.allCases.map { component in
                IpadTrackMenuAction(title: component.title, destructive: false, action: { toggleComponent(component) },
                                    checked: componentMask & component.rawValue == 0)
            }
            actions.append(.init(title: "", destructive: false, action: {}, separator: true))
            actions.append(.init(title: "Componentes View", destructive: false, action: {}, children: choices))
            actions.append(.init(title: "", destructive: false, action: {}, separator: true))
        }
        append(count > 1 ? "Delete tracks" : "Delete track", remove, destructive: true)
        return actions
    }
}

private struct IpadTrackMenuAction {
    let title: String
    let destructive: Bool
    let action: () -> Void
    var checked = false
    var separator = false
    var children: [IpadTrackMenuAction] = []
}

/// The row menu owns only its empty/name area. A context menu on the whole
/// SwiftUI row intercepts holds and secondary clicks intended for REC controls.
private struct IpadTrackMenuSurface: UIViewRepresentable {
    let actions: [IpadTrackMenuAction]
    @Environment(\.isEnabled) private var enabled
    func makeUIView(context: Context) -> TouchView { TouchView() }
    func updateUIView(_ view: TouchView, context: Context) {
        view.actions = actions; view.isUserInteractionEnabled = enabled
    }
    // A representable covering the whole row still blocks sibling UIKit
    // controls on iPadOS 16 even if its UIView rejects their hit. Create actual
    // separate surfaces so no UIKit/SwiftUI wrapper covers a control or grip.
    static func areas(in bounds: CGRect, excluding controls: [CGRect]) -> [CGRect] {
        controls.reduce([bounds]) { areas, control in
            areas.flatMap { area -> [CGRect] in
                let cut = area.intersection(control)
                guard !cut.isNull, !cut.isEmpty else { return [area] }
                return [CGRect(x: area.minX, y: area.minY, width: area.width, height: cut.minY - area.minY),
                        CGRect(x: area.minX, y: cut.maxY, width: area.width, height: area.maxY - cut.maxY),
                        CGRect(x: area.minX, y: cut.minY, width: cut.minX - area.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: area.maxX - cut.maxX, height: cut.height)]
                    .filter { $0.width > 0.5 && $0.height > 0.5 }
            }
        }
    }
    final class TouchView: UIView, UIContextMenuInteractionDelegate {
        var actions: [IpadTrackMenuAction] = []
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear; isOpaque = false; isAccessibilityElement = false
            addInteraction(UIContextMenuInteraction(delegate: self))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private func menuPreview() -> UITargetedPreview {
            // This is only an invisible hit surface over part of the row.
            // UIKit's default lifted preview gives that transparent rectangle
            // an opaque backdrop/shadow, obscuring half of the coloured track.
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.shadowPath = UIBezierPath()
            return UITargetedPreview(view: self, parameters: parameters)
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            menuPreview()
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            menuPreview()
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard point(inside: location, with: nil), !actions.isEmpty else { return nil }
            let actions = actions
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                var items: [UIMenuElement] = []
                var group: [UIMenuElement] = []
                func flush() {
                    if !group.isEmpty { items.append(UIMenu(options: .displayInline, children: group)); group.removeAll() }
                }
                func button(_ action: IpadTrackMenuAction) -> UIAction {
                    UIAction(title: action.title, attributes: action.destructive ? .destructive : [],
                             state: action.checked ? .on : .off) { _ in action.action() }
                }
                for action in actions {
                    if action.separator { flush() }
                    else if !action.children.isEmpty { group.append(UIMenu(title: action.title, children: action.children.map(button))) }
                    else { if action.destructive { flush() }; group.append(button(action)) }
                }
                flush()
                return UIMenu(children: items)
            }
        }
    }
}

private struct RemoteNativePhaseButton: View {
    let inverted: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RemoteNativePhaseGlyph().stroke(inverted ? Color.black : JarasTheme.text,
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: 14, height: 14).frame(width: 20, height: 20)
                .background(inverted ? JarasTheme.yellow : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: 28, height: 23).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Invert polarity")
            .accessibilityValue(inverted ? "On" : "Off")
    }
}
private struct RemoteNativePhaseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.07, y: rect.maxY - rect.height * 0.07))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.07, y: rect.minY + rect.height * 0.07))
        return path
    }
}


/// A tap never writes a position. Only a drag changes the knob, and two taps reset it.
private struct IpadKnobTouchInput: UIViewRepresentable {
    let drag: (CGPoint, Bool) -> Void
    let reset: () -> Void

    final class Input: UIView, UIGestureRecognizerDelegate {
        var drag: ((CGPoint, Bool) -> Void)?
        var reset: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let movement = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
            movement.maximumNumberOfTouches = 1
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            addGestureRecognizer(movement)
            addGestureRecognizer(doubleTap)
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func resetTapped() { reset?() }

        @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: drag?(recognizer.translation(in: self), false)
            case .ended, .cancelled: drag?(recognizer.translation(in: self), true)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let single = other as? UITapGestureRecognizer, single.numberOfTapsRequired == 1,
                  let ancestor = single.view else { return false }
            return isDescendant(of: ancestor)
        }
    }

    func makeUIView(context: Context) -> Input { Input() }
    func updateUIView(_ view: Input, context: Context) { view.drag = drag; view.reset = reset }
}

struct IpadMixerKnob: View {
    let value: Double
    var trackID: UUID? = nil
    var pan = false
    var usesMixerPanFace = false
    var showsPanTooltip = false
    var preview: ((Double) -> Void)? = nil
    let changed: (Double) -> Void
    @State private var origin: Double?
    @State private var live: Double?
    @State private var hovering = false
    @State private var dragTrack: UUID?
    private var range: ClosedRange<Double> { pan ? -1...1 : -60...12 }
    private var displayed: Double {
        let initial = pan ? value : value <= 0 ? -60 : 20 * log10(value)
        return (dragTrack == trackID ? live : nil) ?? min(range.upperBound, max(range.lowerBound, initial))
    }
    private var label: String {
        if pan { return mixerPanText(displayed) }
        return displayed <= -60 ? "−∞ dB" : String(format: "%+.1f dB", displayed)
    }
    private func send(_ value: Double) { changed(pan ? value : value <= -60 ? 0 : pow(10, value / 20)) }
    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                if usesMixerPanFace {
                    MixerPanFace.draw(value: displayed, in: CGRect(origin: .zero, size: size), context: cg)
                    return
                }
                cg.saveGState()
                cg.translateBy(x: size.width/2, y: size.height/2)
                cg.scaleBy(x: 1.5, y: 1.5)
                cg.translateBy(x: -size.width/2, y: -size.height/2)
                IpadItemHeaderKnob.draw(in: CGRect(origin: .zero,size: size),position: (displayed - range.lowerBound) / (range.upperBound - range.lowerBound), pan: pan, context: cg)
                cg.restoreGState()
            }
        }.frame(width: 20,height: 20).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .background(IpadItemMixTooltipAnchor(text: (!pan || showsPanTooltip) && (origin != nil || hovering) ? label : nil))
            .onHover { hovering = $0 }
            .onChange(of: trackID) { _ in origin = nil; live = nil; hovering = false }
            .overlay {
                IpadKnobTouchInput(drag: { translation, ended in
                    if origin == nil { origin = displayed; dragTrack = trackID }
                    guard dragTrack == trackID else { return }
                    let delta = Double(translation.x - translation.y) * (pan ? 0.02 : 0.5)
                    let next = min(range.upperBound, max(range.lowerBound, (origin ?? displayed) + delta))
                    if ended {
                        origin = nil; live = nil; send(next)
                    } else {
                        live = next
                        if let preview { preview(next) } else { send(next) }
                    }
                }, reset: {
                    origin = nil; live = nil; send(0)
                })
            }
            .accessibilityLabel(pan ? "Pan" : "Track volume")
            .accessibilityValue(label)
            .accessibilityAdjustableAction { direction in
                let step = pan ? 0.05 : 1
                send(min(range.upperBound, max(range.lowerBound, displayed + (direction == .increment ? step : -step))))
            }
    }
}

private struct InlineNameTouchBoundary: UIViewRepresentable {
    let dismiss: () -> Void

    final class Boundary: UIView {
        var dismiss: (() -> Void)?
        private lazy var observer = OutsideTouchObserver(isInside: { [weak self] touch in
            guard let self else { return true }
            return self.bounds.contains(touch.location(in: self))
        }, outside: { [weak self] in self?.dismiss?() })

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observer.view?.removeGestureRecognizer(observer)
            window?.addGestureRecognizer(observer)
        }
    }

    func makeUIView(context: Context) -> Boundary {
        let boundary = Boundary()
        boundary.isUserInteractionEnabled = false
        return boundary
    }
    func updateUIView(_ view: Boundary, context: Context) { view.dismiss = dismiss }
}

struct InlineNameInput: UIViewRepresentable {
    @Binding var text: String
    let compact: Bool
    let finish: () -> Void
    let move: (Int) -> Void
    var accessibilityName = "Track name"

    final class Field: UITextField, UITextFieldDelegate {
        var changed: ((String) -> Void)?
        var finish: (() -> Void)?
        var move: ((Int) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.becomeFirstResponder() else { return }
                self.selectAll(nil)
            }
        }
        @objc func edited() { changed?(text ?? "") }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { finish?(); return true }
        func textFieldDidEndEditing(_ textField: UITextField) { finish?() }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for press in presses {
                guard let key = press.key,
                      key.modifierFlags.intersection([.command, .control, .alternate, .shift]).isEmpty,
                      let code = HardwareKeyboardInput.keyCode(hidUsage: key.keyCode.rawValue) else { continue }
                if code == 125 || code == 126 {
                    move?(code == 125 ? 1 : -1)
                    return
                }
            }
            super.pressesBegan(presses, with: event)
        }
    }
    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = field; field.text = text
        field.font = .systemFont(ofSize: compact ? 10 : 11, weight: .semibold)
        field.textAlignment = compact ? .center : .left
        field.textColor = .white; field.backgroundColor = UIColor(white: 0.10, alpha: 1)
        field.accessibilityLabel = accessibilityName
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(field, action: #selector(Field.edited), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: Field, context: Context) {
        field.changed = { text = $0 }; field.finish = finish; field.move = move
    }
    static func dismantleUIView(_ field: Field, coordinator: ()) {
        field.finish = nil
        field.delegate = nil
        field.resignFirstResponder()
    }
}

private struct InlineNameNavigationAnchor: UIViewRepresentable {
    let id: UUID
    let compact: Bool
    let editable: Bool
    let open: () -> Void

    @MainActor private static let anchors = NSHashTable<Anchor>.weakObjects()
    final class Anchor: UIView {
        var id: UUID?
        var compact = false
        var open: (() -> Void)?
        var scroll: UIScrollView? {
            var parent = superview
            while let view = parent {
                if let scroll = view as? UIScrollView { return scroll }
                parent = view.superview
            }
            return nil
        }
    }
    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor(); anchor.isUserInteractionEnabled = false
        Self.anchors.add(anchor)
        return anchor
    }
    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.id = id; anchor.compact = compact; anchor.open = editable ? open : nil
    }
    @MainActor static func step(from id: UUID, direction: Int, finish: () -> Void) {
        let anchors = Self.anchors.allObjects
        guard let source = anchors.first(where: { $0.id == id }),
              let window = source.window, let scroll = source.scroll else { return }
        func position(_ anchor: Anchor) -> CGFloat {
            let point = anchor.convert(anchor.bounds.origin, to: window)
            return source.compact ? point.x : point.y
        }
        let origin = position(source)
        let candidates = anchors.filter {
            $0 !== source && $0.window === window && $0.scroll === scroll && $0.compact == source.compact &&
            $0.open != nil && !$0.bounds.isEmpty && (position($0) - origin) * CGFloat(direction) > 0.5
        }
        guard let next = candidates.min(by: { abs(position($0) - origin) < abs(position($1) - origin) }) else { return }
        finish()
        scroll.scrollRectToVisible(next.convert(next.bounds, to: scroll), animated: false)
        next.open?()
    }
}

struct InlineMixerTrackName: View {
    let name: String
    var number: Int? = nil
    var compact = false
    let editable: Bool
    let select: () -> Void
    let commit: (String) -> Void
    var reorder: (() -> NSItemProvider)? = nil
    @State private var editing = false
    @State private var draft = ""
    @State private var navigationID = UUID()

    var body: some View {
        Group {
            if editing {
                GeometryReader { geometry in
                    let font = UIFont.systemFont(ofSize: compact ? 10 : 11, weight: .semibold)
                    let width = min(geometry.size.width, max(84, (name as NSString).size(withAttributes: [.font: font]).width + 36))
                    InlineNameInput(text: $draft, compact: compact, finish: finish, move: { direction in
                        InlineNameNavigationAnchor.step(from: navigationID, direction: direction, finish: finish)
                    }).padding(.horizontal, 3).background(Color(white: 0.10))
                        .frame(width: width, height: geometry.size.height)
                        .background(InlineNameTouchBoundary(dismiss: finish))
                        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                }
            } else {
                let label = HStack(spacing: 4) {
                    if let number {
                        Text(verbatim: String(format: "%02d", number)).onTapGesture(perform: select)
                    }
                    Text(verbatim: name).lineLimit(compact ? 2 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: begin)
                        .onTapGesture(perform: select)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .leading)
                if let reorder { label.onDrag(reorder) } else { label }
            }
        }.font(.jarasSystem(size: compact ? 10 : 11, weight: .semibold))
            .multilineTextAlignment(compact ? .center : .leading)
            .background(InlineNameNavigationAnchor(id: navigationID, compact: compact, editable: editable, open: begin))
    }

    private func begin() {
        guard editable, !editing else { return }
        select()
        draft = name; editing = true
    }
    private func finish() {
        guard editing else { return }
        editing = false
        commit(draft)
    }
}

private struct NativeTransportMeterField: View {
    let show: ShowController
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var displayedMeter: String {
        guard let meter = show.transportMeter else { return "–" }
        return "\(meter.beats)/\(meter.unit)"
    }

    var body: some View {
        TextField("4/4", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.jarasSystem(size: 12, weight: .semibold, design: .monospaced))
            .keyboardType(.numbersAndPunctuation)
            .submitLabel(.done)
            .focused($editing)
            .frame(width: 48, height: 25)
            .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(editing ? JarasTheme.green : JarasTheme.line)
                    .allowsHitTesting(false)
            }
            .disabled(!show.transportMeterEditingAllowed)
            .accessibilityLabel("Time signature")
            .onAppear { draft = displayedMeter }
            .onChange(of: displayedMeter) { value in if !editing { draft = value } }
            .onChange(of: show.transportMeterEditingAllowed) { allowed in
                if !allowed { editing = false; draft = displayedMeter }
            }
            .onChange(of: editing) { focused in if !focused { commit() } }
            .onSubmit { editing = false }
    }

    private func commit() {
        let fields = draft.split(separator: "/", omittingEmptySubsequences: false)
        if draft != displayedMeter, fields.count == 2,
           let beats = Int(fields[0].trimmingCharacters(in: .whitespaces)),
           let unit = Int(fields[1].trimmingCharacters(in: .whitespaces)) {
            _ = show.setTransportMeter(beats: beats, unit: unit)
        }
        draft = displayedMeter
    }
}

// Build the mixer in its own SwiftUI update. Merely erasing the already-built
// mixer still resolves its layout types on the project window's startup stack.
private struct NativeTrackMixerPane: View {
    let spacing: CGFloat
    let header: () -> AnyView
    let viewport: () -> AnyView

    var body: some View {
        VStack(spacing: spacing) {
            header()
            viewport()
        }
    }
}

private struct RemoteNativeMixerRow: View, Equatable {
    @AppStorage(MixerTrackStyle.trackMixerKey) private var trackStyle = MixerTrackStyle.standard
    let track: DAWRemoteState.Track
    let project: UUID
    let song: UUID?
    let number: Int
    var compact = false
    var nativeTrackSnapshot: Track? = nil
    var local = false
    var localShow: ShowController? = nil
    var nativeContextMenu = false
    var nativePhaseInverted = false
    var mixFeedback: TrackMixFeedback? = nil
    var editing = false
    var selected = false
    var selection: Set<UUID> = []
    var groupGuides: [Bool] = []
    var groupColor: UInt32? = nil
    var isGroup = false
    var select: (() -> Void)? = nil
    var selectionMenu: (() -> Void)? = nil
    var openPatch: (() -> Void)? = nil
    var openFX: (() -> Void)? = nil
    var openAutomation: (() -> Void)? = nil
    var addText: (() -> Void)? = nil
    var addLyrics: (() -> Void)? = nil
    let send: (DAWRemoteCommand.Action, Double) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.song == rhs.song && lhs.number == rhs.number &&
            lhs.compact == rhs.compact && lhs.nativeTrackSnapshot?.kind == rhs.nativeTrackSnapshot?.kind && lhs.nativeTrackSnapshot?.hiddenMixerComponents == rhs.nativeTrackSnapshot?.hiddenMixerComponents && lhs.local == rhs.local && lhs.nativeContextMenu == rhs.nativeContextMenu && lhs.nativePhaseInverted == rhs.nativePhaseInverted &&
            lhs.nativeTrackSnapshot?.fx?.inserted.isEmpty == rhs.nativeTrackSnapshot?.fx?.inserted.isEmpty &&
            lhs.nativeTrackSnapshot?.fx?.allBypassed == rhs.nativeTrackSnapshot?.fx?.allBypassed &&
            lhs.editing == rhs.editing &&
            lhs.selected == rhs.selected &&
            lhs.selection == rhs.selection && lhs.groupGuides == rhs.groupGuides && lhs.groupColor == rhs.groupColor && lhs.isGroup == rhs.isGroup && lhs.track.hasSameMixerControls(as: rhs.track)
    }
    private func condensedRow(show: ShowController, nativeTrack: Track, nameColor: UInt32) -> some View {
        HStack(spacing: 3) {
            if let icon = track.instrumentIcon, TrackIconCatalog.contains(icon) {
                TrackIconDisplay(id: icon).foregroundStyle(.white).frame(width: 20, height: 20)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            InlineMixerTrackName(name: track.name, number: number, editable: nativeTrack.fixedName == nil,
                select: { select?() }, commit: { show.renameMixerTrack(track.id, name: $0, project: project) })
                .foregroundStyle(remoteColor(nameColor))
                .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if nativeTrack.kind == .standard && nativeTrack.showsMixerComponent(.rec) {
                    TrackRecordButton(show: show, track: nativeTrack, touchHeight: 21, touchWidth: 22)
                }
                if nativeTrack.kind == .standard && nativeTrack.showsMixerComponent(.inputMonitor) {
                    TrackInputMonitorButton(show: show, track: nativeTrack, width: 22, height: 21)
                }
                if nativeTrack.showsMixerComponent(.mute) {
                    Button("M") { toggleMix(.mute) }.buttonStyle(RemoteNativeTrackButtonStyle(
                        activeColor: track.mute ? TrackMixerButtonAppearance.muted : nil, width: 22, touchPadding: 0, height: 21, usesTrackFace: true))
                }
                if nativeTrack.showsMixerComponent(.solo) {
                    Button("S") { toggleMix(.solo) }.buttonStyle(RemoteNativeTrackButtonStyle(
                        activeColor: track.solo ? JarasTheme.yellow : nil, width: 22, touchPadding: 0, height: 21, usesTrackFace: true))
                }
            }.anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
            if track.canMeter != false {
                TrackSignalLight(meter: StemAudioPlayback.shared.meter(for: track.id))
                    .frame(width: 14).accessibilityLabel("Signal level")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        GeometryReader { geometry in
        let buttonHeight: CGFloat = geometry.size.height < 28 ? 20 : 22
        let nativeTrack = nativeTrackSnapshot ?? localShow?.current?.tracks.first { $0.id == track.id }
        let kind = nativeTrack?.kind ?? .standard
        let teleprompter = local && kind.isTeleprompter
        let vinhetas = nativeTrack?.role.rawValue == "vinhetas"
        let hasVolume = !local || !kind.isText || teleprompter
        let hierarchyWidth: CGFloat = !groupGuides.isEmpty ? 16 + CGFloat(min(4, groupGuides.count - 1)) * 8 : 0
        let usesStripe = local && trackStyle == .stripeOnly
        let stripeWidth = usesStripe ? MixerTrackStyle.trackStripeWidth : 0
        let nameColor = usesStripe ? MixerTrackStyle.surfaceTextHex : track.nameColor ?? 0xffffff
        let compactControls = local && nativeTrack?.compactMixerControls == true
        let heightCompact = local && (nativeTrack?.supportsMixerComponents == true || kind == .click || teleprompter) &&
            geometry.size.height < TrackHeightGeometry.compactControlHeight
        let mask = local ? (nativeTrack?.mixerComponentMask ?? 0) : 0
        let visible: (TrackMixerComponent) -> Bool = { mask & $0.rawValue == 0 }
        let hasPan = !local || (kind == .standard && visible(.pan))
        let controlLayout = RemoteNativeTrackControlLayout(width: max(0, geometry.size.width - stripeWidth), compact: compact,
            editing: editing, hierarchyWidth: hierarchyWidth, isGroup: isGroup, hasVolume: hasVolume, hasPan: hasPan || kind == .click,
            hasRecord: localShow != nil && (kind == .standard || kind == .click), hasPatch: openPatch != nil, hasFX: openFX != nil, hasEnv: openAutomation != nil)
        let titleBesideControls = !local && (compact || !hasVolume)
        let fxVisible = !local || controlLayout.fx
        let emphasized = track.emphasized == true || (editing && selected)
        let showsPhase = local && hasVolume && !teleprompter && !vinhetas && !compactControls && localShow != nil && visible(.phase)
        let showsPhasePeak = showsPhase && track.canMeter != false
        let phaseWidth: CGFloat = showsPhasePeak ? 34 : 28
        let volumeWidth: CGFloat = 36
        let alignsVolumeWithPatch = local && (kind == .standard || kind == .click) && openPatch != nil && visible(.patch)
        let faderWidth = min(186, max(80, controlLayout.buttonsWidth - volumeWidth - 3 - (showsPhase ? phaseWidth + 3 : 0)))
        Group {
            if editing {
                HStack(spacing: 6) {
                    if let icon = track.instrumentIcon, TrackIconCatalog.contains(icon) {
                        TrackIconDisplay(id: icon).foregroundStyle(.white)
                            .frame(width: min(40, geometry.size.height), height: min(40, geometry.size.height))
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: String(format: "%02d  %@", number, track.name))
                        .font(.jarasSystem(size: 11, weight: .semibold))
                        .foregroundStyle(remoteColor(nameColor))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            } else if heightCompact && teleprompter {
                HStack(spacing: 4) {
                    Text(verbatim: String(format: "%02d  %@", number, track.name))
                        .font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(remoteColor(nameColor)).frame(maxWidth: .infinity, alignment: .leading)
                    teleprompterControls(width: min(200, max(0, geometry.size.width - stripeWidth - 75)))
                        .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                }.frame(maxHeight: .infinity)
            } else if heightCompact, let localShow, let nativeTrack {
                condensedRow(show: localShow, nativeTrack: nativeTrack, nameColor: nameColor)
            } else {
                ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    if !compactControls {
                    HStack(spacing: 3) {
                        if teleprompter {
                            Spacer(minLength: 0)
                            teleprompterControls(width: geometry.size.width - hierarchyWidth - stripeWidth - (editing ? 40 : 10))
                                .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                        } else {
                        if titleBesideControls {
                            Text(String(format: "%02d  %@", number, track.name)).font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                                .foregroundStyle(remoteColor(nameColor)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !titleBesideControls { Spacer(minLength: 0) }
                        HStack(spacing: 3) {
                        if !local || kind == .standard {

                        if visible(.patch), let openPatch {
                            Button("Patch", action: openPatch).buttonStyle(RemoteNativeTrackButtonStyle(
                                width: RemoteNativeTrackControlLayout.patchWidth, touchPadding: 0, height: buttonHeight))
                        }
                        if visible(.envelope), controlLayout.env, let openAutomation {
                            let expanded = nativeTrack?.automation?.visibleEnvelopes.isEmpty == false
                            Button(action: openAutomation) {
                                ControlIcon(name: "automationLanes", active: expanded, size: 16)
                            }.buttonStyle(RemoteNativeTrackButtonStyle(
                                activeColor: expanded ? JarasTheme.green : nil,
                                width: RemoteNativeTrackControlLayout.envWidth, touchPadding: 0, height: buttonHeight, usesTrackFace: true))
                                .accessibilityLabel("Envelopes")
                        }
                        if compact && hasVolume {
                            IpadMixerKnob(value: track.volume, trackID: track.id, changed: adjustVolume)
                                .frame(width: 22, height: buttonHeight)
                        }
                        if visible(.fx), fxVisible, let openFX {
                            Button("FX", action: openFX).buttonStyle(RemoteNativeTrackButtonStyle(height: buttonHeight, usesTrackFace: true,
                                ink: TrackMixerButtonAppearance.fxText(hasEffects: nativeTrack?.fx?.inserted.isEmpty == false,
                                                                       bypassed: nativeTrack?.fx?.allBypassed == true)))
                        }
                        if let localShow, let row = nativeTrack, row.kind == .standard {
                            let touchHeight: CGFloat = buttonHeight < 22 ? buttonHeight : 28
                            if visible(.rec) { TrackRecordButton(show: localShow, track: row, touchHeight: touchHeight, touchWidth: 32)
                                .frame(width: 32, height: touchHeight) }
                            if visible(.inputMonitor) { TrackInputMonitorButton(show: localShow, track: row,
                                width: RemoteNativeTrackControlLayout.buttonFaceWidth, height: buttonHeight)
                                .frame(width: RemoteNativeTrackControlLayout.buttonTouchWidth, height: touchHeight) }
                        }
                        } else if kind == .click, let localShow {
                            if let openPatch { Button("Patch", action: openPatch).buttonStyle(RemoteNativeTrackButtonStyle(width: 44, height: buttonHeight)) }
                            Button("Insert") { localShow.insertClickItems(track: track.id) }
                                .buttonStyle(RemoteNativeTrackButtonStyle(width: 52, height: buttonHeight))
                        } else if kind.isText, let addText {
                            Button("Add text", action: addText).buttonStyle(RemoteNativeTrackButtonStyle(width: 82, height: buttonHeight))
                        }
                        let mute = Button { toggleMix(.mute) } label: { Text(verbatim: "M") }
                            .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.mute ? TrackMixerButtonAppearance.muted : nil,
                                height: buttonHeight, usesTrackFace: true))
                        if hasPan {
                            IpadMixerKnob(value: track.pan, trackID: track.id, pan: true, usesMixerPanFace: local,
                                          showsPanTooltip: true, changed: adjustPan)
                                .frame(width: 22, height: buttonHeight).accessibilityLabel("Pan " + track.name)
                        }
                        if !local || visible(.mute) { mute }
                        if visible(.solo) { Button { toggleMix(.solo) } label: { Text(verbatim: "S") }
                            .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil, height: buttonHeight)) }
                        }.anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                        }
                    }
                    }
                    if !compact || compactControls {
                        VStack(alignment: .leading, spacing: 0) {
                            if hasVolume {
                                HStack(spacing: 3) {
                                    Color.clear.frame(width: compactControls ? 24 : 40, height: 22)
                                        .overlay {
                                            if let icon = track.instrumentIcon, TrackIconCatalog.contains(icon) {
                                                TrackIconDisplay(id: icon).foregroundStyle(.white)
                                                    .frame(width: compactControls ? 24 : 32, height: compactControls ? 22 : 32)
                                                    .offset(y: compactControls ? 0 : -8)
                                            }
                                        }.allowsHitTesting(false).accessibilityHidden(true)
                                    if compactControls, let localShow, let row = nativeTrack {
                                        if visible(.inputMonitor), !vinhetas { TrackInputMonitorButton(show: localShow, track: row, width: 22, height: 21) }
                                        if visible(.mute) { Button("M") { toggleMix(.mute) }.buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.mute ? TrackMixerButtonAppearance.muted : nil, width: 22, height: 21, usesTrackFace: true)) }
                                        if visible(.solo) { Button("S") { toggleMix(.solo) }.buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil, width: 22, height: 21, usesTrackFace: true)) }
                                    }
                                    if (!local || vinhetas) && track.canMeter != false {
                                        RemotePeakReadout(decibels: track.peakDB, name: track.name, project: project, song: song, target: track.id, nameColor: nameColor, reset: { send(.resetMeterPeak, 0) }).equatable()
                                            .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                                    }
                                    let volume = Text(remoteDecibelText(track.volume))
                                        .font(.jarasSystem(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(JarasTheme.text).frame(width: volumeWidth, alignment: local ? .trailing : .leading)
                                    Spacer(minLength: 0)
                                    RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(track.volume), range: -60...12, height: 22,
                                        linked: track.linkedTrack != nil, locksScrolling: local, trackID: track.id,
                                        meter: local && track.canMeter != false ? StemAudioPlayback.shared.meter(for: track.id) : nil, mixerFader: true,
                                        selectionScope: song,
                                        preview: localShow.map { show in
                                            { show.sendMixerControl(.volume, target: track.id, value: DAWRemoteFaderScale.gain($0), preview: true) }
                                        }) { adjustVolume(DAWRemoteFaderScale.gain($0)) }
                                        .frame(minWidth: min(80, max(0, geometry.size.width - hierarchyWidth - 130)), maxWidth: alignsVolumeWithPatch ? faderWidth : 186)
                                        .accessibilityLabel("Volume " + track.name)
                                    volume
                                }.frame(height: 23)
                                    .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                                    .padding(.trailing, showsPhase ? phaseWidth + 3 : 0)
                            }
                        }.overlay(alignment: .topTrailing) {
                            if showsPhase, let localShow {
                                VStack(spacing: 0) {
                                    RemoteNativePhaseButton(inverted: nativePhaseInverted) { localShow.send(.phase, target: track.id) }
                                    if showsPhasePeak {
                                        TrackPeakReadout(peak: StemAudioPlayback.shared.meter(for: track.id).peakHold,
                                                         foreground: remoteColor(nameColor))
                                    }
                                }.frame(width: phaseWidth)
                                    .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                            }
                        }
                    }
                    Spacer(minLength: (!compact || compactControls) && !titleBesideControls ? (teleprompter ? 15 : 13) : 0)
                }
                if (!compact || compactControls) && !titleBesideControls {
                        HStack(spacing: 4) {
                            if local, let localShow, nativeTrack?.fixedName == nil, !vinhetas, kind == .standard {
                                InlineMixerTrackName(name: track.name, number: number, editable: true,
                                    select: { select?() }, commit: { localShow.renameMixerTrack(track.id, name: $0, project: project) })
                                    .foregroundStyle(remoteColor(nameColor))
                                    .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                            } else {
                                Text(String(format: "%02d  %@", number, track.name)).font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                                    .foregroundStyle(remoteColor(nameColor)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.frame(height: teleprompter ? 15 : local ? 13 : nil)
                            .padding(.trailing, showsPhasePeak ? phaseWidth + 3 : 0)
                }
                }
            }
        }.padding(.top, teleprompter ? 2 : local ? 1 : 0)
            .padding(.bottom, teleprompter ? 2 : local ? 1 : 0)
            .padding(.leading, (teleprompter ? 4 : 6) + stripeWidth)
            .padding(.trailing, editing ? 36 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: local ? .topLeading : .center)
            .background {
                if usesStripe {
                    MixerTrackSurface(selected: selected || track.emphasized == true)
                        .overlay(alignment: .leading) {
                            Capsule().fill(remoteColor(track.color)).frame(width: stripeWidth)
                                .padding(.vertical, 3)
                        }
                } else {
                    let components = TrackNameContrast.components(track.color, emphasized: emphasized)
                    Color(red: components.red, green: components.green, blue: components.blue)
                        .opacity(emphasized ? 0.65 : 0.50).saturation(track.silenced == true ? 0 : 1)
                }
            }.background(JarasTheme.mixer)
            .backgroundPreferenceValue(IpadTrackControlsBoundsKey.self) { anchors in
                if local {
                    GeometryReader { proxy in
                        IpadTrackSelectionSurface(excluded: anchors.map { proxy[$0] }, name: track.name,
                            selected: selected, holdEnabled: editing && !nativeContextMenu, tap: { select?() }, hold: { selectionMenu?() })
                    }
                }
            }
            // Indent the complete colored row, not only its controls. The
            // uncolored gutter uses the same connector and spacing as the Mac.
            .padding(.leading, hierarchyWidth)
            .overlay(alignment: .leading) {
                if hierarchyWidth > 0 {
                    GroupTrackConnector(last: groupGuides.last != true)
                        .stroke(groupColor.map(Color.init(hex:)) ?? JarasTheme.green, lineWidth: 1)
                        .frame(width: 12)
                        .padding(.leading, hierarchyWidth - 16)
                        .allowsHitTesting(false)
                }
            }

        }
    }

    private func adjustVolume(_ gain: Double) {
        if let localShow { localShow.sendMixerControl(.volume, target: track.id, value: gain) }
        else { send(.volume, gain) }
    }

    private func adjustPan(_ value: Double) {
        send(.pan, value)
        mixFeedback?.show(track: track.id, name: track.name, control: .pan, value: value)
    }

    private func toggleMix(_ control: TrackMixControl) {
        let muted = control == .mute
        send(muted ? .mute : .solo, 0)
        if local {
            mixFeedback?.show(track: track.id, name: track.name, control: control,
                              value: (muted ? track.mute : track.solo) ? 0 : 1)
        }
    }

    private func teleprompterControls(width: CGFloat) -> some View {
        let count = CGFloat((addText == nil ? 0 : 1) + (addLyrics == nil ? 0 : 1))
        let patchSpace: CGFloat = openPatch == nil ? 0 : 40
        let labelWidth = min(86, max(24, (width - patchSpace - 12) / max(1, count)))
        return HStack(spacing: 3) {
            if let openPatch {
                Button("Patch", action: openPatch)
                    .buttonStyle(CompactTrackButtonStyle(width: 34))
            }
            if let addText {
                Button(action: addText) {
                    Text("Add text").lineLimit(1).minimumScaleFactor(0.65).frame(width: labelWidth)
                }.buttonStyle(TrackControlButtonStyle(height: 22))
            }
            if let addLyrics {
                Button(action: addLyrics) {
                    Text("Full lyrics").lineLimit(1).minimumScaleFactor(0.65).frame(width: labelWidth)
                }.buttonStyle(TrackControlButtonStyle(height: 22))
            }
        }
    }
}

/// Meter samples update retained layers inside each row.
/// Detached rows stop observing; only meters on screen consume display work.
private struct TrackSignalLight: View {
    @ObservedObject var meter: TrackMeterLevel
    var body: some View {
        Circle().fill(Color(cgColor: MixerMeterStyle.signalLight(max(meter.levels.x, meter.levels.y))))
            .overlay { Circle().strokeBorder(Color(cgColor: MixerMeterStyle.railBorder), lineWidth: 0.5) }
            .frame(width: 10, height: 10).allowsHitTesting(false)
    }
}

private struct IpadMixerMeter: UIViewRepresentable {
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme
    let meter: TrackMeterLevel
    var preparesOffscreen = false
    var compact = false
    var linked = false
    var fixedUpperSpan = false
    func makeUIView(context: Context) -> IpadMixerMeterView { IpadMixerMeterView() }
    func updateUIView(_ view: IpadMixerMeterView, context: Context) {
        view.bind(meter, preparesOffscreen: preparesOffscreen, compact: compact, linked: linked, theme: theme, fixedUpperSpan: fixedUpperSpan)
    }
    static func dismantleUIView(_ view: IpadMixerMeterView, coordinator: ()) { view.unbind() }
}
private final class IpadMixerMeterView: UIView {
    private var meter: TrackMeterLevel?
    private var subscription: AnyCancellable?
    private var preparesOffscreen = false
    private var compact = false
    private var linked = false
    private var theme = JarasInterfaceTheme.defaultTheme
    private var fixedUpperSpan = false
    private let drawing = MixerRailLayers(flipped: true)
    private var levels = SIMD2<Double>(repeating: 0)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(drawing.layer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func bind(_ next: TrackMeterLevel, preparesOffscreen: Bool, compact: Bool, linked: Bool,
              theme: JarasInterfaceTheme, fixedUpperSpan: Bool) {
        let needsPaint = self.preparesOffscreen != preparesOffscreen || self.compact != compact ||
            self.linked != linked || self.theme != theme || self.fixedUpperSpan != fixedUpperSpan
        self.fixedUpperSpan = fixedUpperSpan
        self.preparesOffscreen = preparesOffscreen; self.theme = theme
        self.compact = compact; self.linked = linked
        guard meter !== next else {
            if needsPaint { paint() }
            return
        }
        subscription = nil
        meter = next
        levels = next.levels
        observe()
    }
    func unbind() { subscription = nil; meter = nil }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        subscription = nil; observe()
    }
    private func observe() {
        guard window != nil, let meter else { return }
        subscription = meter.$levels.sink { [weak self] levels in
            self?.levels = levels; self?.paint()
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); paint() }
    private func paint() {
        guard window != nil, bounds.height > 0 else { return }
        // A recycler mounts only a small reserve. Paint that reserve before
        // it scrolls onscreen, even if the next level is identical.
        if !preparesOffscreen {
            var ancestor = superview
            while let view = ancestor {
                if view.clipsToBounds && !convert(bounds, to: view).intersects(view.bounds) { return }
                ancestor = view.superview
            }
        }
        drawing.update(size: bounds.size, levels: levels, compact: compact, linked: linked, theme: theme, fixedUpperSpan: fixedUpperSpan)
    }
}

@MainActor private struct NativeRemoteProjectsView: View {
    let state: DAWRemoteState
    let computerName: String
    let open: (UUID) -> Void
    let openInNewTab: (UUID) -> Void
    let close: () -> Void
    let exit: () -> Void
    @State private var requested: UUID?
    private var browser: DAWRemoteState.ProjectBrowser? { state.projects }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent projects").font(.jarasTitle2.bold())
                    Label { Text(verbatim: computerName) } icon: { Image(systemName: "desktopcomputer") }
                        .font(.jarasSubheadline).foregroundStyle(JarasTheme.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.jarasSystem(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                        .background(RemoteSurface.panel).clipShape(Circle())
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Close")
            }
            Text("Choose a project to open on the PC.").font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
            if let browser {
                if browser.recent.isEmpty {
                    Text("No recent projects on this PC.").foregroundStyle(JarasTheme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(browser.recent) { project in
                                Button { requested = project.id; open(project.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text").font(.jarasSystem(size: 22)).foregroundStyle(JarasTheme.green)
                                        Text(verbatim: project.name).font(.jarasBody.weight(.semibold)).lineLimit(2)
                                        Spacer()
                                        if project.current {
                                            Text("Open").font(.jarasCaption.weight(.semibold)).foregroundStyle(JarasTheme.green)
                                        } else if requested == project.id && browser.busy {
                                            ProgressView().tint(JarasTheme.green)
                                        } else {
                                            Image(systemName: "chevron.right").font(.jarasCaption.weight(.semibold)).foregroundStyle(JarasTheme.secondary)
                                        }
                                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RemoteSurface.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(project.current ? JarasTheme.green.opacity(0.45) : JarasTheme.line))
                                }.buttonStyle(RemoteFullAreaButtonStyle())
                                    .contextMenu {
                                        if browser.canOpenInNewTab == true {
                                            Button { requested = project.id; openInNewTab(project.id) } label: {
                                                Label("Open in new tab", systemImage: "plus.square.on.square")
                                            }
                                        }
                                    }
                                    .disabled(project.current || !browser.canOpen)
                            }
                        }
                    }
                }
                if !browser.status.isEmpty {
                    HStack(spacing: 10) {
                        if browser.busy { ProgressView().tint(JarasTheme.green) }
                        Text(LocalizedStringKey(browser.status)).font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
                    }
                }
                if !browser.error.isEmpty {
                    Text(LocalizedStringKey(browser.error)).font(.jarasCallout).foregroundStyle(JarasTheme.yellow)
                }
            } else {
                Text("Update CatLive on the PC to browse recent projects.").font(.jarasCallout).foregroundStyle(JarasTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("Exit Remote", action: exit).buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RemoteSurface.background).foregroundStyle(JarasTheme.text)
            .onChange(of: browser?.recent.first(where: { $0.current })?.id) { current in
                if let requested, current == requested { close() }
            }
            .onChange(of: state.projectTabs?.first(where: { $0.selected })?.id) { _ in
                // Each tab owns its recent-project catalog, so opaque IDs can change.
                if requested != nil { close() }
            }
    }
}

@MainActor private final class RemoteTrackScrollController: NSObject, ObservableObject {
    enum SelectionScope { case grid, tracks, setlist }
    @Published var selectionScope: SelectionScope = .grid
    @Published var itemSelection = TimelinePointerSelection()
    @Published var itemMove: IpadNativeItemMove?
    @Published var itemMix: IpadNativeItemMix?
    @Published var pointerReset = UUID()
    var pointerEditing = false
    var modifiers: HardwareKeyboardModifiers = []
    var selectedItem: UUID? {
        get { itemSelection.anchor }
        set { itemSelection.replace(newValue.map { [$0] } ?? []); selectionScope = .grid }
    }
    @Published private(set) var heightScale = DAWRemoteItemLayout.heightScale(
        UserDefaults.standard.object(forKey: "jaras.remote.trackHeightScale") as? Double ?? 1)
    private var pinchStartScale: Double?
    private var pinchAnchorY: CGFloat?
    var heightTracks: [DAWRemoteState.Track] = []
    var heightSelectedTrack: UUID?
    func revealTrack(_ id: UUID) {
        guard let scroll = scrollView,
              let index = heightTracks.firstIndex(where: { $0.id == id }) else { return }
        let minimum = RemoteNativeGridMetrics.minimumTrackHeight(local: true)
        let top = heightTracks.prefix(index).reduce(CGFloat.zero) {
            $0 + DAWRemoteItemLayout.rowHeight($1, scale: heightScale, minimum: minimum) + 1
        }
        let height = DAWRemoteItemLayout.rowHeight(heightTracks[index], scale: heightScale, minimum: minimum)
        scroll.scrollRectToVisible(CGRect(x: 0, y: top, width: scroll.bounds.width, height: height), animated: false)
    }
    #if os(iOS)
    var usesNativeTrackHeight = false
    private lazy var mixerHeightPinch: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(mixerHeightPinched(_:)))
        gesture.delegate = self
        return gesture
    }()
    private func bindMixerHeightPinch(from previous: UIScrollView?, to next: UIScrollView?) {
        previous?.removeGestureRecognizer(mixerHeightPinch)
        next?.addGestureRecognizer(mixerHeightPinch)
    }
    @objc private func mixerHeightPinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            if gesture.state == .began, let scroll = scrollView {
                pinchAnchorY = gesture.location(in: scroll).y - scroll.bounds.minY
            }
            resizeTracks(gesture.scale)
        case .ended, .cancelled, .failed:
            finishResizingTracks()
        default: break
        }
    }
    private func receivesMixerHeightPinch(_ touch: UITouch) -> Bool {
        guard let scroll = scrollView else { return false }
        let point = touch.location(in: scroll)
        guard scroll.bounds.contains(point), point.y >= 0 else { return false }
        let minimum = RemoteNativeGridMetrics.minimumTrackHeight(local: usesNativeTrackHeight)
        let rowsHeight = max(0, heightTracks.reduce(0.0) {
            $0 + DAWRemoteItemLayout.rowHeight($1, scale: heightScale, minimum: minimum) + 1
        } - 1)
        // Existing rows accept the gesture in the number gutter. The open
        // area below them can use its full width without taking over controls.
        if usesNativeTrackHeight && point.y >= rowsHeight { return true }
        let numberAreaWidth = min(scroll.bounds.width, 98)
        return point.y < rowsHeight && point.x - scroll.bounds.minX <= numberAreaWidth
    }
    private var pendingHeightOffset: CGFloat?
    private var pendingHeightContent: CGFloat = 0
    private var heightAppliedViews = Set<ObjectIdentifier>()
    func applyHeightOffset() {
        guard let offset = pendingHeightOffset else { return }
        for scroll in [scrollView, gridScrollView].compactMap({ $0 }) {
            let id = ObjectIdentifier(scroll)
            guard !heightAppliedViews.contains(id),
                  abs(scroll.contentSize.height - max(scroll.bounds.height, pendingHeightContent)) < 2 else { continue }
            let limited = DAWRemoteScrollRange.clamp(Double(offset), content: Double(scroll.contentSize.height),
                viewport: Double(scroll.bounds.height), topInset: Double(scroll.adjustedContentInset.top),
                bottomInset: Double(scroll.adjustedContentInset.bottom))
            heightAppliedViews.insert(id)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: limited), animated: false)
        }
        if [scrollView, gridScrollView].compactMap({ $0 }).allSatisfy({ heightAppliedViews.contains(ObjectIdentifier($0)) }) {
            pendingHeightOffset = nil
        }
    }
    #endif
    func resizeTracks(_ scale: CGFloat) {
        if pinchStartScale == nil {
            pinchStartScale = max(heightScale, minimumTrackHeightScale)
        }
        let next = max(minimumTrackHeightScale, DAWRemoteItemLayout.heightScale((pinchStartScale ?? heightScale) * Double(scale)))
        if abs(next - heightScale) > 0.0001 {
            #if os(iOS)
            let minimum = RemoteNativeGridMetrics.minimumTrackHeight(local: usesNativeTrackHeight)
            let heights = heightTracks.map { DAWRemoteItemLayout.rowHeight($0, scale: heightScale, minimum: minimum) + 1 }
            let nextHeights = heightTracks.map { DAWRemoteItemLayout.rowHeight($0, scale: next, minimum: minimum) + 1 }
            if let scroll = scrollView ?? gridScrollView,
               let anchor = TrackHeightGeometry.ScrollAnchor(heights: heights,
                   offset: Double((pendingHeightOffset ?? scroll.contentOffset.y) + (pinchAnchorY ?? scroll.bounds.height / 2)),
                   selected: nil),
               let offset = anchor.offset(heights: nextHeights) {
                pendingHeightOffset = max(0, CGFloat(offset) - (pinchAnchorY ?? scroll.bounds.height / 2))
                pendingHeightContent = CGFloat(max(0, nextHeights.reduce(0, +) - 1))
                heightAppliedViews.removeAll()
            }
            #endif
            heightScale = next
            #if os(iOS)
            DispatchQueue.main.async { [weak self] in self?.applyHeightOffset() }
            #endif
        }
    }
    private var minimumTrackHeightScale: Double {
        #if os(iOS)
        let minimum = usesNativeTrackHeight && heightTracks.contains(where: { $0.compactComponents == true })
            ? TrackHeightGeometry.compactMinimumLaneHeight : RemoteNativeGridMetrics.minimumTrackHeight(local: usesNativeTrackHeight)
        return minimum / DAWRemoteItemLayout.defaultLaneHeight
        #else
        return 0.1
        #endif
    }
    func finishResizingTracks() {
        guard pinchStartScale != nil else { return }
        pinchStartScale = nil
        pinchAnchorY = nil
        UserDefaults.standard.set(heightScale, forKey: "jaras.remote.trackHeightScale")
    }
    #if os(iOS)
    weak var scrollView: UIScrollView? {
        didSet {
            guard oldValue !== scrollView else { return }
            bindMixerHeightPinch(from: oldValue, to: scrollView)
            trackSizeObservation = scrollView?.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.applyHeightOffset(); self?.alignAttachedView() }
            }
            if gridScrollView?.window != nil { awaitingAlignment = scrollView }
            alignAttachedView()
            trackObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] source, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.synchronize(source, to: self.gridScrollView)
                }
            }
        }
    }
    let timelineBar = TimelineTouchScrollConnection()
    weak var gridScrollView: UIScrollView? {
        didSet {
            guard oldValue !== gridScrollView else { return }
            timelineBar.scroll = gridScrollView
            oldValue?.removeGestureRecognizer(itemHold)
            oldValue?.removeGestureRecognizer(gridTapRecognizer)
            gridScrollView?.addGestureRecognizer(itemHold)
            gridScrollView?.addGestureRecognizer(gridTapRecognizer)
            gridSizeObservation = gridScrollView?.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.applyHeightOffset(); self?.alignAttachedView() }
            }
            if scrollView?.window != nil { awaitingAlignment = gridScrollView }
            alignAttachedView()
            gridObservation = gridScrollView?.observe(\.contentOffset, options: [.new]) { [weak self] source, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if source.isDragging || source.isDecelerating { self.manualGridScroll?() }
                    self.synchronize(source, to: self.scrollView)
                }
            }
        }
    }
    private weak var awaitingAlignment: UIScrollView?
    private func alignAttachedView() {
        guard pendingHeightOffset == nil, let target = awaitingAlignment, target.window != nil,
              let source = target === scrollView ? gridScrollView : scrollView, source.window != nil,
              target.bounds.height > 0, target.contentSize.height > 0 else { return }
        let requested = source.contentOffset.y
        let offset = DAWRemoteScrollRange.clamp(Double(requested), content: Double(target.contentSize.height),
            viewport: Double(target.bounds.height), topInset: Double(target.adjustedContentInset.top),
            bottomInset: Double(target.adjustedContentInset.bottom))
        // A freshly mounted lazy stack can still report just one screen of content.
        guard abs(offset - requested) <= 0.5 || target.contentSize.height >= source.contentSize.height - 1 else { return }
        if abs(target.contentOffset.y - offset) > 0.5 {
            target.setContentOffset(CGPoint(x: target.contentOffset.x, y: offset), animated: false)
        }
        awaitingAlignment = nil
    }
    private var trackSizeObservation: NSKeyValueObservation?
    private var gridSizeObservation: NSKeyValueObservation?
    private var trackObservation: NSKeyValueObservation?
    var manualGridScroll: (() -> Void)?
    private var gridObservation: NSKeyValueObservation?
    private final class HoldArea {
        weak var view: RemoteGridItemHoldArea?
        init(_ view: RemoteGridItemHoldArea) { self.view = view }
    }
    private var holdAreas: [ObjectIdentifier: HoldArea] = [:]
    private weak var heldArea: RemoteGridItemHoldArea?
    private lazy var itemHold: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(itemHeld(_:)))
        gesture.minimumPressDuration = 0.45
        gesture.allowableMovement = 8
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        return gesture
    }()
    var gridTap: ((Double) -> Void)?
    private lazy var gridTapRecognizer: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(gridTapped(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        gesture.require(toFail: itemHold)
        return gesture
    }()
    @objc private func gridTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let scroll = gridScrollView,
              !scroll.isDragging, scroll.bounds.width > 0 else { return }
        let area = holdAreas.values.compactMap(\.view).first { $0.window != nil && !$0.isHidden && $0.bounds.contains(gesture.location(in: $0)) }
        if let tap = area?.tap { tap() } else { selectedItem = nil }
        let x = gesture.location(in: scroll).x - scroll.bounds.minX
        gridTap?(min(1, max(0, Double(x / scroll.bounds.width))))
    }
    private func receiveGridTap(_ touch: UITouch) -> Bool {
        if ProgramChangeHeadAnchorView.contains(touch) { return false }
        if pointerEditing && touch.type == .indirectPointer { return false }
        var view = touch.view
        while let candidate = view, candidate !== gridScrollView {
            if candidate is UIControl { return false }
            view = candidate.superview
        }
        // SwiftUI's M button may not be a UIControl. Exclude its registered bounds too.
        return !holdAreas.values.compactMap(\.view).contains { area in
            area.window != nil && !area.isHidden &&
                CGRect(x: 0, y: 0, width: 35, height: 28).contains(touch.location(in: area))
        }
    }
    func registerHoldArea(_ view: RemoteGridItemHoldArea) { holdAreas[ObjectIdentifier(view)] = HoldArea(view) }
    func unregisterHoldArea(_ view: RemoteGridItemHoldArea) { holdAreas.removeValue(forKey: ObjectIdentifier(view)) }
    @objc private func itemHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let scroll = gridScrollView,
              !scroll.isDragging, let area = heldArea, area.window != nil,
              area.bounds.contains(gesture.location(in: area)) else { return }
        area.hold?()
    }
    fileprivate func receiveItemHold(_ touch: UITouch) -> Bool {
        if pointerEditing { return false } // The item's native context menu owns long press.

        if pointerEditing && touch.type == .indirectPointer { return false }
        var view = touch.view
        while let candidate = view, candidate !== gridScrollView {
            if candidate is UIControl || candidate is IpadItemBodyContextMenu.Surface { return false }
            view = candidate.superview
        }
        holdAreas = holdAreas.filter { $0.value.view != nil }
        heldArea = holdAreas.values.compactMap(\.view).first { area in
            let point = touch.location(in: area)
            return area.window != nil && !area.isHidden && area.bounds.contains(point)
                && !CGRect(x: 0, y: 0, width: 35, height: 28).contains(point)
        }
        return heldArea != nil
    }
    private var isSynchronizing = false
    private func synchronize(_ source: UIScrollView, to target: UIScrollView?) {
        guard !isSynchronizing, pendingHeightOffset == nil, source !== awaitingAlignment, let target, source.window != nil, target.window != nil else { return }
        if source === gridScrollView {
            guard source.isDragging || source.isDecelerating else { return }
        } else if gridScrollView?.isDragging == true || gridScrollView?.isDecelerating == true { return }
        let offset = DAWRemoteScrollRange.clamp(Double(source.contentOffset.y), content: Double(target.contentSize.height), viewport: Double(target.bounds.height), topInset: Double(target.adjustedContentInset.top), bottomInset: Double(target.adjustedContentInset.bottom))
        if target.contentOffset.y != offset {
            isSynchronizing = true
            defer { isSynchronizing = false }
            target.setContentOffset(CGPoint(x: target.contentOffset.x, y: offset), animated: false)
        }
    }
    func pointerScroll(_ delta: CGFloat) {
        guard let grid = gridScrollView else { return }
        setGridOffset(grid.contentOffset.y + delta)
    }
    func setGridOffset(_ requested: CGFloat) {
        guard let grid = gridScrollView else { return }
        manualGridScroll?()
        func move(_ scroll: UIScrollView, to y: CGFloat) {
            let offset = DAWRemoteScrollRange.clamp(Double(y), content: Double(scroll.contentSize.height),
                viewport: Double(scroll.bounds.height), topInset: Double(scroll.adjustedContentInset.top),
                bottomInset: Double(scroll.adjustedContentInset.bottom))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
        }
        move(grid, to: requested)
        if let scrollView { move(scrollView, to: grid.contentOffset.y) }
    }
    func step(_ direction: Int) {
        guard let scrollView else { return }
        move(to: scrollView.contentOffset.y + CGFloat(direction) * max(86, scrollView.bounds.height * 0.5), animated: !pointerEditing)
    }
    private func move(to offset: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let limited = DAWRemoteScrollRange.clamp(Double(offset), content: Double(scrollView.contentSize.height),
            viewport: Double(scrollView.bounds.height), topInset: Double(scrollView.adjustedContentInset.top), bottomInset: Double(scrollView.adjustedContentInset.bottom))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: CGFloat(limited)), animated: animated)
    }
    #else
    func step(_ direction: Int) {}
    #endif
}
#if os(iOS)
extension RemoteTrackScrollController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === mixerHeightPinch { return receivesMixerHeightPinch(touch) }
        return gestureRecognizer === gridTapRecognizer ? receiveGridTap(touch) : receiveItemHold(touch)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer === gridScrollView?.panGestureRecognizer
    }
}

/// Register item bounds without putting a SwiftUI recognizer between the finger
/// and UIScrollView. One native hold recognizer shares the grid's touch stream.
private struct RemoteGridItemHoldProbe: UIViewRepresentable {
    let controller: RemoteTrackScrollController
    let tap: (() -> Void)?
    let hold: () -> Void
    func makeUIView(context: Context) -> RemoteGridItemHoldArea {
        let view = RemoteGridItemHoldArea()
        view.isUserInteractionEnabled = false
        view.bind(controller: controller, tap: tap, hold: hold)
        return view
    }
    func updateUIView(_ view: RemoteGridItemHoldArea, context: Context) {
        view.bind(controller: controller, tap: tap, hold: hold)
    }
    static func dismantleUIView(_ view: RemoteGridItemHoldArea, coordinator: ()) { view.unbind() }
}
private final class RemoteGridItemHoldArea: UIView {
    private weak var controller: RemoteTrackScrollController?
    var hold: (() -> Void)?
    var tap: (() -> Void)?
    func bind(controller: RemoteTrackScrollController, tap: (() -> Void)?, hold: @escaping () -> Void) {
        if self.controller !== controller {
            self.controller?.unregisterHoldArea(self)
            self.controller = controller
            controller.registerHoldArea(self)
        }
        self.hold = hold; self.tap = tap
    }
    func unbind() {
        controller?.unregisterHoldArea(self)
        controller = nil; hold = nil; tap = nil
    }
}

/// Find the containing native scroll view without replacing SwiftUI's delegate.
private struct RemoteTrackScrollProbe: UIViewRepresentable {
    let controller: RemoteTrackScrollController
    var tracks: [DAWRemoteState.Track]? = nil
    var selectedTrack: UUID? = nil
    var isGrid = false
    var twoFingerScroll = false
    var usesNativeTrackHeight = false
    var gridTap: ((Double) -> Void)? = nil
    func makeUIView(context: Context) -> RemoteTrackScrollProbeView {
        let view = RemoteTrackScrollProbeView()
        view.isUserInteractionEnabled = false; view.controller = controller; view.isGrid = isGrid; view.twoFingerScroll = twoFingerScroll
        if isGrid { controller.gridTap = gridTap }
        else { controller.usesNativeTrackHeight = usesNativeTrackHeight }
        return view
    }
    func updateUIView(_ view: RemoteTrackScrollProbeView, context: Context) {
        view.controller = controller; view.isGrid = isGrid; view.twoFingerScroll = twoFingerScroll
        if let tracks { controller.heightTracks = tracks; controller.heightSelectedTrack = selectedTrack }
        if isGrid { controller.gridTap = gridTap }
        else { controller.usesNativeTrackHeight = usesNativeTrackHeight }
        view.resolve()
        DispatchQueue.main.async { controller.applyHeightOffset() }
    }
}
private final class RemoteTrackScrollProbeView: UIView {
    var controller: RemoteTrackScrollController?
    var isGrid = false
    var twoFingerScroll = false
    private weak var resolvedScroll: UIScrollView?
    private var resolveScheduled = false
    override func didMoveToWindow() { super.didMoveToWindow(); resolvedScroll = nil; resolve() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); resolvedScroll = nil; resolve() }
    func resolve() {
        guard window != nil else { return }
        if let resolvedScroll, resolvedScroll.window === window,
           (isGrid ? controller?.gridScrollView : controller?.scrollView) === resolvedScroll { return }
        guard !resolveScheduled else { return }
        resolveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resolveScheduled = false
            guard self.window != nil else { return }
            var parent = self.superview
            while let view = parent {
                if let scroll = view as? UIScrollView {
                    if scroll.bounces { scroll.bounces = false }
                    if scroll.alwaysBounceVertical { scroll.alwaysBounceVertical = false }
                    if scroll.alwaysBounceHorizontal { scroll.alwaysBounceHorizontal = false }
                    scroll.contentInsetAdjustmentBehavior = .never
                    if self.isGrid {
                        if self.twoFingerScroll {
                            scroll.panGestureRecognizer.minimumNumberOfTouches = 2
                            scroll.panGestureRecognizer.maximumNumberOfTouches = 2
                            scroll.showsVerticalScrollIndicator = false
                        }
                        self.controller?.gridScrollView = scroll
                    }
                    else { self.controller?.scrollView = scroll }
                    self.resolvedScroll = scroll
                    return
                }
                parent = view.superview
            }
        }
    }
}
#endif
#endif

#if os(iOS)
/// Static assets are fetched once and retained independently of the 10 Hz state stream.
private struct RemoteNativeProjectionImage: View {
    let id: UUID
    let project: UUID
    var stretch = false
    @ObservedObject var remote: DAWRemoteSession = .shared
    @State private var image: UIImage?
    @State private var loadedID: UUID?
    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    if stretch { Image(uiImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                    else { Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                }
            }
            else if loadedID == id {
                Label("Imagem indisponível", systemImage: "photo").foregroundStyle(JarasTheme.secondary)
            }
            else { ProgressView().tint(JarasTheme.green) }
        }.task(id: id) {
            image = nil; loadedID = nil
            load()
            remote.requestImage(id: id, project: project)
        }.onChange(of: remote.imageRevision) { _ in load() }
    }
    private func load() {
        guard loadedID != id else { return }
        if let data = remote.imageData(id: id, project: project) {
            loadedID = id; image = UIImage(data: data)
        } else if remote.imageUnavailable(id: id, project: project) {
            loadedID = id; image = nil
        }
    }
}

@MainActor struct RemoteNativeTeleprompterPanel: View {
    let index: Int
    @ObservedObject var timer: RemoteLocalTimer
    var fullscreen = false
    let toggleFullscreen: () -> Void
    var toggleSetlist: (() -> Void)? = nil
    var setlistVisible = true
    var managesSubscription = true
    @ObservedObject var remote: DAWRemoteSession = .shared
    private var content: DAWRemoteTeleprompter? { remote.remoteState?.teleprompters?.first { $0.index == index } }
    var body: some View {
        VStack(spacing: 6) {
            if !fullscreen {
            HStack {
                Text("TP-\(index)").font(.jarasSystem(size: 15, weight: .semibold)).foregroundStyle(JarasTheme.green)
                Spacer()
                if let toggleSetlist {
                    Button(action: toggleSetlist) {
                        Image(systemName: "sidebar.right").frame(width: 30, height: 30)
                            .foregroundStyle(setlistVisible ? JarasTheme.green : JarasTheme.secondary)
                    }.buttonStyle(RemoteFullAreaButtonStyle())
                        .accessibilityLabel(setlistVisible ? "Recolher Setlist" : "Expandir Setlist")
                        .accessibilityValue(setlistVisible ? "Shown" : "Hidden")
                }
            }.padding(.horizontal, 16).padding(.top, 8)
            }
            Group {
            if let content, let state = remote.remoteState {
                projection(content, state: state)
            } else if remote.remoteState?.timer == nil {
                Text("Atualize o CatLive no PC para usar este painel.")
                    .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Aguardando teleprompter…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded(toggleFullscreen))
                .accessibilityAction(named: Text(fullscreen ? "Sair da tela cheia" : "Tela cheia"), toggleFullscreen)
        }.background(Color.black).foregroundStyle(JarasTheme.text)
            .onAppear { if managesSubscription { subscribe(index) }; localProjection(index) }
            .onChange(of: index) { if managesSubscription { subscribe($0) }; localProjection($0) }
            .onDisappear { if managesSubscription { subscribe(0) }; localProjection(0) }
    }
    private func localProjection(_ panel: Int) {
        guard remote.isLocalWorkspace else { return }
        VideoPlayback.teleprompter.setProjectionEnabled(panel == 1)
        VideoPlayback.teleprompter2.setProjectionEnabled(panel == 2)
    }
    private func subscribe(_ panel: Int) {
        guard let state = remote.remoteState else { return }
        remote.send(.init(project: state.project, song: state.song, action: .remotePanel, value: Double(panel)))
    }
    private func projection(_ content: DAWRemoteTeleprompter, state: DAWRemoteState) -> some View {
        var content = content
        if content.loopActive == nil { content.loopActive = state.loop }
        let notice = state.notices
        let active = notice.map { $0.active && (index == 1 ? $0.window1 : $0.window2) } ?? false
        return TeleprompterNoticeStage(settings: content.resolvedSettings, preview: content.preview, noticeActive: active) {
            TeleprompterProjectionLayout(content: content, fullscreen: fullscreen,
                timerValue: { (timer.displayText().replacingOccurrences(of: ":", with: " : "), timer.displayOpacity(), timer.expired()) },
                media: {
                    if remote.isLocalWorkspace {
                        ProjectionMediaSurface(controller: index == 1 ? .teleprompter : .teleprompter2)
                    } else if let image = content.imageID {
                        RemoteNativeProjectionImage(id: image, project: state.project, stretch: content.resolvedSettings.stretchesMedia, remote: remote)
                    }
                })
        } notice: {
            if let notice { RemoteNativeNoticeOverlay(notice: notice, project: state.project, remote: remote) }
        }
    }
}

private struct RemoteNativeNoticeOverlay: View {
    let notice: DAWRemoteNotices
    let project: UUID
    var remote: DAWRemoteSession = .shared
    var body: some View {
        GeometryReader { geometry in
          TimelineView(.periodic(from: .now, by: 0.175)) { context in
            let elapsed = context.date.timeIntervalSince1970 - notice.sentAt
            let flash = elapsed >= 0 && elapsed < 1.05 && Int(elapsed / 0.175) % 2 == 0
            VStack {
                if let image = notice.imageID {
                    RemoteNativeProjectionImage(id: image, project: project, remote: remote)
                } else {
                    let text = notice.message.uppercased()
                    Text(notice.emoji.isEmpty ? text : "\(notice.emoji) \(text) \(notice.emoji)")
                        .font(tpNoticeFont(notice.font, size: min(72, max(24, geometry.size.width * 0.078)) * notice.scale / 100)).minimumScaleFactor(0.3)
                        .foregroundStyle(remoteColor(notice.textColor)).multilineTextAlignment(.center)
                }
            }.padding(24).frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .background(remoteColor(flash ? notice.flashColor : notice.backgroundColor))
                .clipped()
          }
        }.allowsHitTesting(false)
    }
}

@MainActor struct RemoteNativeNoticesView: View {
    let close: () -> Void
    var managesSubscription = true
    @ObservedObject var remote: DAWRemoteSession = .shared
    @State private var draft = ""
    @State private var globalDraft = ""
    @State private var slot = -1
    @StateObject private var sendFeedback = NoticeSendFeedback()
    @State private var presentation = RemoteNoticePresentation()
    private var notices: DAWRemoteNotices? { remote.remoteState?.notices }
    var body: some View {
        RemoteNoticePanel {
            HStack {
                Text("Messages").font(.jarasHeadline)
                Spacer()
                if managesSubscription {
                    RemoteDesktopBatteryBadge(percent: remote.remoteState?.desktopBatteryPercent, vertical: false)
                }
                if let notices {
                    Text(notices.pinned ? "∞" : "\(notices.remaining)s")
                        .font(.jarasCaption).monospacedDigit().foregroundStyle(JarasTheme.secondary)
                }
                Button(action: closeNotices) {
                    Text("Fechar").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(presentation.dismissed)
            }
        } actions: {
            if let notices {
                RemoteNoticeActions {
                  HStack(spacing: 8) {
                    Button { sendNotice() } label: {
                        NoticeSendButtonLabel(phase: sendFeedback.phase)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(NoticeSendButtonStyle(phase: sendFeedback.phase))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (slot < 0 || !notices.imageSlots[slot]))
                    Button { command(.noticeClear) } label: {
                        Text("Withdraw message").frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteNoticeActionStyle()).disabled(!notices.active)
                  }
                } pin: {
                  HStack(spacing: 8) {
                    Button { command(.noticePin, value: notices.pinned ? 0 : 1) } label: {
                        Label("Pin", systemImage: notices.pinned ? "pin.fill" : "pin")
                            .frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteNoticeActionStyle())
                        .foregroundStyle(notices.pinned ? JarasTheme.yellow : JarasTheme.text)
                    if let pinWhenStopped = notices.pinWhenStopped {
                        Button {
                            command(.noticePinStopped, value: Double(slot), text: draft, enabled: !pinWhenStopped)
                        } label: {
                            Text("Pin while transport is stopped").lineLimit(2)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(RemoteNoticeActionStyle())
                            .foregroundStyle(pinWhenStopped ? JarasTheme.yellow : JarasTheme.text)
                            .disabled(!pinWhenStopped && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                      (slot < 0 || !notices.imageSlots[slot]))
                    }
                  }
                }.font(.jarasSystem(size: 13, weight: .semibold))
            }
        } content: {
            if let notices {
                NoticeSendFeedbackView(feedback: sendFeedback)
                Picker("Recado", selection: $slot) {
                    Text("Global").tag(-1)
                    ForEach(0..<3) { Text("Recado \($0 + 1)").tag($0) }
                }.pickerStyle(.segmented).onChange(of: slot) { value in
                    draft = value < 0 ? globalDraft : notices.templates[value]
                }
                TextEditor(text: $draft).font(.jarasSystem(size: 18)).scrollContentBackground(.hidden)
                    .frame(height: 150).padding(8).background(Color(hex: 0x101010))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.14), lineWidth: 1).allowsHitTesting(false))
                    .onChange(of: draft) { value in
                        var bounded = String(value.prefix(500))
                        while bounded.utf8.count > 4000 { bounded.removeLast() }
                        if bounded != value { draft = bounded }
                        if slot < 0 { globalDraft = bounded }
                    }
                HStack {
                    Text("\(draft.count) / 500").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    if slot >= 0 && notices.imageSlots[slot] {
                        Label("Imagem salva", systemImage: "photo").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    }
                    Spacer()
                    if slot >= 0 { Button("Salvar recado") { command(.noticeSaveTemplate, value: Double(slot), text: draft) } }
                }
            } else if remote.remoteState?.timer == nil {
                Text("Atualize o CatLive no PC para usar este painel.")
                    .font(.jarasCallout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("Aguardando recados…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(RemoteSurface.panel).foregroundStyle(JarasTheme.text)
            .disabled(presentation.dismissed)
            .onAppear {
                presentation = RemoteNoticePresentation(project: remote.remoteState?.project)
                if managesSubscription { command(.remotePanel, value: 3) }
            }
            .onChange(of: remote.remoteState?.project) { presentation.observe(project: $0) }
            .onDisappear {
                withdrawPresentedNotice()
                sendFeedback.reset()
                if managesSubscription { command(.remotePanel) }
            }
    }
    private func closeNotices() {
        guard !presentation.dismissed else { return }
        if let command = presentation.dismiss(project: remote.remoteState?.project, song: remote.remoteState?.song,
                                              preserveStoppedNotice: notices?.stoppedNoticeActive == true),
           remote.connected && !remote.reconnecting {
            // The notices-only close action disconnects. Complete the write
            // first so disconnect cannot cancel the withdrawal behind it.
            remote.sendNoticeClear(command, completion: close)
        } else { close() }
    }
    private func withdrawPresentedNotice() {
        guard let command = presentation.dismiss(project: remote.remoteState?.project, song: remote.remoteState?.song,
                                              preserveStoppedNotice: notices?.stoppedNoticeActive == true),
              remote.connected && !remote.reconnecting else { return }
        remote.send(command)
    }
    private func sendNotice() {
        let id = sendFeedback.begin()
        guard let state = remote.remoteState else { sendFeedback.complete(id, result: .disconnected); return }
        let command = DAWRemoteCommand(id: id, project: state.project, song: state.song,
                                       action: .noticeSend, value: Double(slot), text: draft)
        remote.sendNotice(command) { [weak sendFeedback] result in sendFeedback?.complete(id, result: result) }
    }
    private func command(_ action: DAWRemoteCommand.Action, value: Double = 0, text: String? = nil, enabled: Bool? = nil) {
        guard let state = remote.remoteState else { return }
        remote.send(.init(project: state.project, song: state.song, action: action, value: value, text: text, enabled: enabled))
    }
}
#endif

// MARK: - Remote notice presentation
/// Dismissal belongs to the project that opened the editor. It is never queued
/// for a later connection or allowed to clear another project's notice.
struct RemoteNoticePresentation {
    private(set) var project: UUID?
    private(set) var dismissed = false
    init(project: UUID? = nil) { self.project = project }
    mutating func observe(project: UUID?) {
        if self.project == nil && !dismissed { self.project = project }
    }
    mutating func dismiss(project: UUID?, song: UUID?, preserveStoppedNotice: Bool = false) -> DAWRemoteCommand? {
        guard !dismissed else { return nil }
        dismissed = true
        guard !preserveStoppedNotice, let captured = self.project, project == captured else { return nil }
        return .init(project: captured, song: song, action: .noticeClear)
    }
}

/// Keep the stopped-transport option beside Pin, wrapping the two action
/// groups on narrow phones instead of shrinking or hiding their touch targets.
struct RemoteNoticeActions: View {
    private let primary: AnyView
    private let pin: AnyView
    init<Primary: View, Pin: View>(@ViewBuilder primary: () -> Primary, @ViewBuilder pin: () -> Pin) {
        self.primary = AnyView(primary()); self.pin = AnyView(pin())
    }
    var body: some View {
        actionLayout.frame(maxWidth: .infinity, alignment: .leading)
    }
    // iOS 16 can fail while resolving the symbolic metadata of an availability
    // branch containing generic action tuples. Keep that branch out of body and
    // erase both its result and its children before SwiftUI resolves the layout.
    private var actionLayout: AnyView {
        let vertical = AnyView(VStack(alignment: .leading, spacing: 8) { primary; pin })
        if #available(macOS 13.0, iOS 16.0, *) {
            let horizontal = AnyView(HStack(spacing: 8) { primary; pin }
                .fixedSize(horizontal: true, vertical: false))
            return AnyView(ViewThatFits(in: .horizontal) { horizontal; vertical })
        }
        return vertical
    }
}

/// Actions stay pinned during normal editing. With a very short keyboard
/// viewport they scroll with the editor so every control remains reachable.
struct RemoteNoticePanel<Header: View, Actions: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header().frame(minHeight: 44).padding(.horizontal, 16).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) {
                    // Keep one stable editor hierarchy when the keyboard opens.
                    LazyVStack(spacing: 0, pinnedViews: geometry.size.height >= 240 ? [.sectionHeaders] : []) {
                        Section {
                            VStack(spacing: 10) { content() }.frame(maxWidth: .infinity)
                                .padding(16)
                        } header: {
                            VStack(spacing: 0) {
                                actions().padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                                    .fixedSize(horizontal: false, vertical: true)
                                Divider()
                            }.background(JarasTheme.panel)
                        }
                    }
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct RemoteNoticeActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.22 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Notice delivery feedback
/// This state is local to the sender. Network delivery can only finish after
/// a matching application receipt; old receipts cannot confirm a newer tap.
@MainActor final class NoticeSendFeedback: ObservableObject {
    enum Phase: Equatable {
        case idle, sending, finished(DAWRemoteNoticeDelivery)
        var message: String {
            switch self {
            case .idle: return ""
            case .sending: return "Sending message…"
            case .finished(.accepted): return "Message sent."
            case .finished(.rejected): return "Message was not sent."
            case .finished(.disconnected): return "Not connected. Message was not sent."
            case .finished(.unconfirmed): return "Could not confirm delivery. Check the PC."
            }
        }
        var accepted: Bool { self == .finished(.accepted) }
        var failed: Bool {
            if case .finished(let result) = self { return result != .accepted }
            return false
        }
    }
    @Published private(set) var phase = Phase.idle
    private var currentID: UUID?
    private var dismissal: Task<Void, Never>?
    private let successDuration: UInt64
    private let failureDuration: UInt64
    init(successDuration: UInt64 = 2_500_000_000, failureDuration: UInt64 = 5_000_000_000) {
        self.successDuration = successDuration; self.failureDuration = failureDuration
    }
    func begin() -> UUID {
        dismissal?.cancel(); dismissal = nil
        let id = UUID(); currentID = id; phase = .sending
        return id
    }
    func complete(_ id: UUID, result: DAWRemoteNoticeDelivery) {
        guard currentID == id, phase == .sending else { return }
        phase = .finished(result)
        let duration = result == .accepted ? successDuration : failureDuration
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: duration) } catch { return }
            guard self?.currentID == id else { return }
            self?.reset()
        }
    }
    func reset() {
        dismissal?.cancel(); dismissal = nil; currentID = nil; phase = .idle
    }
}

struct NoticeSendButtonLabel: View {
    let phase: NoticeSendFeedback.Phase
    var body: some View {
        Label("Send", systemImage: phase.accepted ? "checkmark" : "paperplane.fill")
            .font(.jarasSystem(size: 13, weight: .semibold))
    }
}
struct NoticeSendButtonStyle: ButtonStyle {
    let phase: NoticeSendFeedback.Phase
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12)
            .frame(minWidth: 76, minHeight: height)
            .foregroundStyle(Color.black)
            .background((phase == .sending ? JarasTheme.yellow : JarasTheme.green).opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
    private var height: CGFloat {
        #if os(macOS)
        return 30
        #else
        return 44
        #endif
    }
}
struct NoticeSendFeedbackView: View {
    @ObservedObject var feedback: NoticeSendFeedback
    var body: some View {
        HStack(spacing: 6) {
            if feedback.phase == .sending { ProgressView().controlSize(.small).accessibilityHidden(true) }
            else if feedback.phase != .idle {
                Image(systemName: feedback.phase.accepted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .accessibilityHidden(true)
            }
            Text(LocalizedStringKey(feedback.phase.message)).font(.jarasSystem(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(feedback.phase.failed ? Color.red : JarasTheme.green)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notice-send-feedback")
            .accessibilityHidden(feedback.phase == .idle)
            .onChange(of: feedback.phase) { phase in
                guard case .finished = phase else { return }
                let message = JarasLocalization.string(phase.message)
                #if os(iOS)
                UIAccessibility.post(notification: .announcement, argument: message)
                #else
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                    userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                #endif
            }
    }
}

// MARK: - Local Remote timer
/// Static gradients are shared by the Remote controls. No blur, shadow,
/// display-link or per-frame color work is needed for these surfaces.
enum RemoteSurface {
    // Both iPad workspaces share these surfaces, including their dialogs.
    // Resolve once; the darker palette adds no rendering or animation work.
    private static let brightness = 0.55
    private static func neutral(_ top: Double, _ bottom: Double) -> LinearGradient {
        LinearGradient(colors: [Color(white: top * brightness), Color(white: bottom * brightness)], startPoint: .top, endPoint: .bottom)
    }
    static var background: some View { JarasNativePaletteSurface(color: { $0.background }, remote: neutral(0.18, 0.115)) }
    static var panel: some View { JarasNativePaletteSurface(color: { $0.panel }, remote: neutral(0.235, 0.155)) }
    static var display: some View { JarasNativePaletteSurface(color: { $0.display }, remote: neutral(0.115, 0.075)) }
    static let edge = LinearGradient(colors: [Color.white.opacity(0.16), Color.black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
    static let shading = LinearGradient(colors: [Color.white.opacity(0.10), .clear, Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
    static func fill(_ color: Color) -> some View {
        JarasNativePaletteSurface(color: { _ in color }, remote: color.overlay(shading)).allowsHitTesting(false)
    }
}

private struct RemoteControlSurface: ViewModifier {
    var color: Color? = nil
    var radius: CGFloat = 6
    var bordered = true
    func body(content: Content) -> some View {
        content.background {
            if let color { RemoteSurface.fill(color) }
            else { RemoteSurface.panel }
        }.clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                if bordered { RoundedRectangle(cornerRadius: radius).stroke(RemoteSurface.edge, lineWidth: 0.5).allowsHitTesting(false) }
            }
    }
}

/// Plain SwiftUI buttons otherwise hit only their drawn content on older iOS.
/// Define the shape inside the style, after the label's frame/padding, so the
/// whole visual control responds without adding a competing tap/drag gesture.
private struct RemoteFullAreaButtonStyle: ButtonStyle {
    var surface = false
    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        if surface {
            configuration.label.modifier(RemoteControlSurface()).contentShape(Rectangle())
        } else {
            configuration.label.contentShape(Rectangle())
        }
        #else
        configuration.label.contentShape(Rectangle())
        #endif
    }
}

/// Anchor once per authoritative timer change. Bridge frame cadence never drives
/// the local display, which keeps counting through a connection interruption.
@MainActor final class RemoteLocalTimer: ObservableObject {
    private struct Anchor: Equatable {
        var targetSeconds = 0
        var mode: TeleprompterTimerMode = .countdown
        var running = false
        var remainingSeconds = 0.0
        var uptime = 0.0
    }
    @Published private var anchor = Anchor()
    @Published private(set) var runID = UUID()
    private var hostRevision: UUID?
    private var pendingCommand: (id: UUID, deadline: Double)?
    private let now: () -> Double
    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    var running: Bool { anchor.running }
    var mode: TeleprompterTimerMode { anchor.mode }
    var targetSeconds: Int { anchor.targetSeconds }
    var targetText: String { TeleprompterTimer.formatted(targetSeconds) }

    func synchronize(_ snapshot: DAWRemoteTimerState?) {
        guard let snapshot, snapshot.valid else { return }
        let timestamp = now()
        guard timestamp.isFinite else { return }
        if let pendingCommand {
            // A response to an earlier Start/Stop must not undo the latest tap.
            // Fall back to a fresh host snapshot if a command was rejected/lost.
            guard snapshot.commandID == pendingCommand.id || timestamp >= pendingCommand.deadline else { return }
            self.pendingCommand = nil
        } else if snapshot.revision == hostRevision { return }
        hostRevision = snapshot.revision
        runID = UUID()
        anchor = Anchor(targetSeconds: snapshot.targetSeconds,
                        mode: snapshot.mode.flatMap(TeleprompterTimerMode.init(rawValue:)) ?? .countdown, running: snapshot.running,
                        remainingSeconds: snapshot.remainingSeconds, uptime: timestamp)
    }
    /// Use when reconnecting to a host so its latest remaining time is sampled.
    func resetSynchronization() { hostRevision = nil; pendingCommand = nil; runID = UUID() }
    @discardableResult func setMode(_ mode: TeleprompterTimerMode) -> UUID? {
        guard !running, mode != self.mode else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        anchor = Anchor(targetSeconds: targetSeconds, mode: mode, running: false,
                        remainingSeconds: mode == .countdown ? Double(targetSeconds) : 0, uptime: timestamp)
        return id
    }
    @discardableResult func start(seconds: Int) -> UUID? {
        guard !running else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let target = min(TeleprompterTimer.maximumTargetSeconds, max(0, seconds))
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        runID = UUID()
        anchor = Anchor(targetSeconds: target, mode: mode, running: true,
                        remainingSeconds: mode == .countdown ? Double(target) : 0, uptime: timestamp)
        return id
    }
    @discardableResult func stop() -> UUID? {
        guard running else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        runID = UUID()
        anchor = Anchor(targetSeconds: targetSeconds, mode: mode, running: false, remainingSeconds: 0, uptime: timestamp)
        return id
    }
    @discardableResult func stop(ifRunID id: UUID) -> UUID? {
        guard running, runID == id else { return nil }
        return stop()
    }
    func displaySeconds() -> Double {
        let timestamp = now()
        guard running, timestamp.isFinite else { return anchor.remainingSeconds }
        let elapsed = max(0, timestamp - anchor.uptime)
        return anchor.remainingSeconds + (mode == .progressive ? elapsed : -elapsed)
    }
    func displayText() -> String {
        let safe = max(-Double(Int.max / 2), min(Double(Int.max / 2), displaySeconds()))
        return TeleprompterTimer.formatted(Int(mode == .progressive ? floor(safe) : ceil(safe)))
    }
    func expired() -> Bool { running && mode == .countdown && displaySeconds() <= 0 }
    func displayOpacity() -> Double { expired() && now().truncatingRemainder(dividingBy: 1) >= 0.5 ? 0.25 : 1 }
    private static let localClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    static func localTime(at date: Date = Date()) -> String { localClock.string(from: date) }
}

// MARK: - Local Remote timer views
@MainActor struct RemoteNativeLocalClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(verbatim: RemoteLocalTimer.localTime(at: context.date)).monospacedDigit()
        }
    }
}
@MainActor struct RemoteNativeTimerReadout: View {
    @ObservedObject var timer: RemoteLocalTimer
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(verbatim: timer.displayText()).monospacedDigit()
                .foregroundStyle(timer.expired() ? Color.red : JarasTheme.green)
                .opacity(timer.displayOpacity())
        }
    }
}
@MainActor struct RemoteNativeTimerView: View {
    @ObservedObject var timer: RemoteLocalTimer
    let send: (DAWRemoteCommand.Action, Double, UUID) -> Void
    let close: () -> Void
    var compact = false
    @State private var digits = ["00", "00", "00"]
    @State private var confirmStop = false
    @State private var stopRunID: UUID?
    @FocusState private var focused: Int?
    var body: some View {
        Group {
        if compact {
            HStack(spacing: 3) {
                Image(systemName: "clock").foregroundStyle(Color.blue).font(.jarasSystem(size: 13))
                if timer.running || timer.mode == .progressive {
                    RemoteNativeTimerReadout(timer: timer).font(.jarasSystem(size: 14, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(0..<3, id: \.self) { index in
                        if index > 0 { Text(verbatim: ":").foregroundStyle(Color.blue) }
                        durationField(index)
                    }
                }
                Button(action: toggleTimer) {
                    Image(systemName: timer.running ? "stop.fill" : "play.fill").frame(width: 28, height: 32)
                }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(timer.running ? Color.red : Color.blue)
                    .accessibilityLabel(timer.running ? "Stop timer" : "Start timer")
            }.frame(height: 32).padding(.horizontal, 3).background {
            #if os(iOS)
            RemoteSurface.display
            #else
            JarasTheme.display
            #endif
        }.cornerRadius(5)
        } else {
        VStack(spacing: 12) {
            Picker("Timer", selection: Binding(get: { timer.mode }, set: { mode in
                focused = nil
                if let id = timer.setMode(mode) { send(.timerSetMode, mode == .progressive ? 0 : 1, id) }
            })) {
                Text("Progressive").tag(TeleprompterTimerMode.progressive)
                Text("Countdown").tag(TeleprompterTimerMode.countdown)
            }.pickerStyle(.segmented).disabled(timer.running)
            HStack {
                Text("Timer").font(.jarasSystem(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 30, height: 30) }
                    .buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Close")
            }
            RemoteNativeTimerReadout(timer: timer)
                .font(.jarasSystem(size: 26, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 42).background {
            #if os(iOS)
            RemoteSurface.display
            #else
            JarasTheme.display
            #endif
        }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            if timer.mode == .countdown {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(spacing: 5) {
                        Text(LocalizedStringKey(["Hours", "Minutes", "Seconds"][index]))
                            .font(.jarasSystem(size: 11)).foregroundStyle(JarasTheme.secondary)
                        durationField(index)
                    }.frame(maxWidth: .infinity)
                }
            }.disabled(timer.running)
            }
            Button(action: toggleTimer) {
                Text(LocalizedStringKey(timer.running ? "Stop" : "Start"))
                    .font(.jarasSystem(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 38)
            }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(timer.running ? Color.white : JarasTheme.green)
                .background {
                    #if os(iOS)
                    RemoteSurface.fill(timer.running ? Color.red.opacity(0.65) : JarasTheme.panel)
                    #else
                    timer.running ? Color.red.opacity(0.65) : JarasTheme.display
                    #endif
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(timer.running ? Color.red : JarasTheme.line))
        }.padding(14).frame(width: 300).background {
            #if os(iOS)
            RemoteSurface.panel
            #else
            JarasTheme.panel
            #endif
        }.foregroundStyle(JarasTheme.text)
        }
        }.onAppear(perform: synchronizeDigits)
            .onChange(of: timer.targetSeconds) { _ in synchronizeDigits() }
            .onChange(of: timer.runID) { _ in confirmStop = false; stopRunID = nil }
            .alert("Stop timer?", isPresented: $confirmStop) {
                Button("Cancel", role: .cancel) { stopRunID = nil }
                Button("Stop timer", role: .destructive) {
                    if let stopRunID, let id = timer.stop(ifRunID: stopRunID) {
                        synchronizeDigits()
                        send(.timerStop, 0, id)
                    }
                    stopRunID = nil
                }
            } message: { Text("The timer will stop and the current count will be reset.") }
            #if os(iOS)
            .background(RemoteKeyboardDismissal(active: focused != nil) { focused = nil })
            #endif
    }
    private func toggleTimer() {
                focused = nil
                if timer.running {
                    stopRunID = timer.runID
                    confirmStop = true
                }
                else {
                    let seconds = TeleprompterTimer.targetSeconds(from: digits.map { $0.isEmpty ? "00" : $0 }.joined(separator: ":")) ?? 0
                    if let id = timer.start(seconds: seconds) { synchronizeDigits(); send(timer.mode == .progressive ? .timerStartProgressive : .timerStart, timer.mode == .progressive ? 0 : Double(seconds), id) }
                }
    }
    private func durationField(_ index: Int) -> some View {
        TextField("00", text: Binding(get: { digits[index] }, set: { value in
            digits[index] = String(value.filter { $0.isASCII && $0.isNumber }.prefix(2))
        }))
        .textFieldStyle(.plain).focused($focused, equals: index)
        .font(.jarasSystem(size: compact ? 14 : 22, weight: .semibold, design: .monospaced))
        .multilineTextAlignment(.center).frame(height: compact ? 30 : 40).background {
            #if os(iOS)
            RemoteSurface.display
            #else
            JarasTheme.display
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused == index ? JarasTheme.green : JarasTheme.line))
        .accessibilityLabel(LocalizedStringKey(["Hours", "Minutes", "Seconds"][index]))
        #if os(iOS)
        .keyboardType(.numberPad)
        #endif
    }
    private func synchronizeDigits() { digits = timer.targetText.components(separatedBy: ":") }
}

#if os(iOS)
/// The probe never receives touches. Its native edge recognizer observes the
/// containing hosting view and fails before recognition for vertical scrolling.
private struct RemoteSidebarEdgeReveal: UIViewRepresentable {
    let active: Bool
    let reveal: () -> Void
    func makeUIView(context: Context) -> RemoteSidebarEdgeView { RemoteSidebarEdgeView() }
    func updateUIView(_ view: RemoteSidebarEdgeView, context: Context) {
        view.reveal = reveal; view.active = active; view.attach()
    }
    static func dismantleUIView(_ view: RemoteSidebarEdgeView, coordinator: ()) { view.detach() }
}
private final class RemoteSidebarEdgeView: UIView, UIGestureRecognizerDelegate {
    var reveal: (() -> Void)?
    var active = false {
        didSet {
            guard active != oldValue else { return }
            edge.isEnabled = active
            isAccessibilityElement = active
            accessibilityLabel = NSLocalizedString("Show sidebar", comment: "")
            accessibilityTraits = .button
        }
    }
    private weak var installedHost: UIView?
    private lazy var edge: UIScreenEdgePanGestureRecognizer = {
        let recognizer = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
        recognizer.edges = .left
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false; recognizer.delaysTouchesEnded = false
        recognizer.delegate = self; recognizer.isEnabled = false
        return recognizer
    }()
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
    func attach() {
        guard window != nil else { detach(); return }
        // Use the nearest hosting controller's view, never a window-wide
        // recognizer. The bounds check below confines it to this workspace.
        var parent = superview
        var host: UIView?
        while let view = parent, !(view is UIWindow) {
            host = view
            if view.next is UIViewController { break }
            parent = view.superview
        }
        guard installedHost !== host else { return }
        detach(); installedHost = host; host?.addGestureRecognizer(edge)
        edge.isEnabled = active
    }
    func detach() {
        installedHost?.removeGestureRecognizer(edge); installedHost = nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        active && window != nil && bounds.contains(touch.location(in: self))
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard active, let host = installedHost else { return false }
        let velocity = edge.velocity(in: host)
        return DAWRemoteSidebarGesture.shouldBegin(horizontal: Double(velocity.x), vertical: Double(velocity.y))
    }
    @objc private func panned(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard active, recognizer.state == .ended, let host = installedHost else { return }
        let movement = recognizer.translation(in: host)
        if DAWRemoteSidebarGesture.shouldReveal(horizontal: Double(movement.x), vertical: Double(movement.y)) { reveal?() }
    }
    override func accessibilityActivate() -> Bool {
        guard active else { return false }
        reveal?(); return true
    }
}

/// Observe taps without taking ownership of the grid's scrolling or control
/// gestures. Switching between text fields must keep the keyboard open.
struct RemoteKeyboardDismissal: UIViewRepresentable {
    let active: Bool
    let dismiss: () -> Void
    func makeUIView(context: Context) -> RemoteKeyboardTapView { RemoteKeyboardTapView() }
    func updateUIView(_ view: RemoteKeyboardTapView, context: Context) {
        view.dismiss = dismiss; view.tap.isEnabled = active
    }
    static func dismantleUIView(_ view: RemoteKeyboardTapView, coordinator: ()) { view.detach() }
}
final class RemoteKeyboardTapView: UIView, UIGestureRecognizerDelegate {
    var dismiss: (() -> Void)?
    private weak var installedWindow: UIWindow?
    lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false; recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard installedWindow !== window else { return }
        detach(); installedWindow = window; window?.addGestureRecognizer(tap)
    }
    func detach() { installedWindow?.removeGestureRecognizer(tap); installedWindow = nil }
    @objc private func tapped() { dismiss?() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif

#if os(iOS)
private struct IpadNativePreviewButton: View {
    let width: CGFloat
    var horizontal = false
    @ObservedObject private var preview = TeleprompterWindow.shared
    var body: some View {
        IpadPreviewButton(width: width, horizontal: horizontal, active: preview.previewActive, page: preview.previewPage,
            toggle: { preview.togglePreview() }, selectPage: { preview.selectPreviewPage($0) })
    }
}
private struct IpadPreviewButton: View {
    let width: CGFloat
    var horizontal = false
    let active: Bool
    let page: Int
    let toggle: () -> Void
    let selectPage: (Int) -> Void
    var body: some View {
        Button(action: toggle) {
            Group {
                if horizontal { ControlIcon(name: "preview", active: active) }
                else { Text(verbatim: "P\nR\nE\nV\nI\nE\nW") }
            }
                .font(.jarasSystem(size: 10, weight: .heavy)).multilineTextAlignment(.center)
                .foregroundStyle(active ? JarasTheme.green : JarasTheme.liveOffRed).frame(width: width, height: horizontal ? 28 : 108)
                .modifier(RemoteControlSurface(radius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Preview")
            .accessibilityValue(active ? "On" : "Off").contextMenu {
            ForEach(0..<6) { candidate in
                Button { selectPage(candidate) } label: {
                    if page == candidate { Label("Blocks \(candidate * 4 + 1)–\(candidate * 4 + 4)", systemImage: "checkmark") }
                    else { Text("Blocks \(candidate * 4 + 1)–\(candidate * 4 + 4)") }
                }
            }
        }
    }
}
#endif

#if os(iOS)
private struct RemoteObserverSectionCue: View {
    let cue: DAWRemoteSectionCue
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(cue.armed ? "Armed section" : "Next section"))
                    .font(.jarasSystem(size: 13, weight: .semibold)).foregroundStyle(JarasTheme.yellow)
                Text(verbatim: cue.name).font(.jarasSystem(size: 23, weight: .bold))
                    .foregroundStyle(.white).lineLimit(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(cue.seconds) s").font(.jarasSystem(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(JarasTheme.yellow).fixedSize()
        }.padding(18).frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(JarasTheme.yellow, lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 14, y: 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("observerSectionCue")
    }
}
#endif

#if os(iOS)
private struct RemoteVinhetasScreen: View {
    let state: DAWRemoteVinhetas?
    let project: UUID
    let song: UUID?
    let phone: Bool
    let send: (DAWRemoteCommand) -> Void
    @State private var held: [Int: DAWRemoteCommand] = [:]
    @Binding var feedback: DAWRemoteVinhetasFeedback
    private func release(_ pad: Int) {
        guard let press = held.removeValue(forKey: pad) else { return }
        if let preset = press.preset { feedback.up(preset: preset, pad: pad) }
        send(.init(project: press.project, song: press.song, action: .vinhetasUp, target: press.target))
    }
    private func releaseAll() { for pad in Array(held.keys) { release(pad) } }
    private func down(_ index: Int, preset: Int) {
        guard held[index] == nil else { return }
        let press = DAWRemoteCommand(project: project, song: song, action: .vinhetasDown,
            target: UUID(), pad: index, preset: preset)
        if let item = state?.presets[preset].pads[index], let id = press.target {
            feedback.down(id: id, preset: preset, pad: index, gate: feedback.gate(preset: preset, pad: index, confirmed: item.gate))
        }
        held[index] = press; send(press)
    }
    var body: some View {
        Group {
            if let state {
                GeometryReader { geometry in
                    VStack(spacing: 8) {
                        if phone {
                            HStack {
                                Text("Vinhetas").font(.jarasHeadline)
                                Spacer()
                                panic
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                ForEach(0..<6) { preset($0, state: state) }
                            }
                        } else {
                            HStack(spacing: 6) {
                                ForEach(0..<6) { preset($0, state: state) }
                                panic
                            }
                        }
                        if !state.available {
                            Text("Crie a pista VINHETAS-FX no computador para tocar os pads.")
                                .font(.jarasCaption).foregroundStyle(JarasTheme.yellow)
                        }
                        if phone {
                            RemoteVinhetasPager(first: AnyView(pads(0..<8, state: state, columns: 2)),
                                second: AnyView(pads(8..<16, state: state, columns: 2)))
                        } else {
                            pads(0..<16, state: state, columns: 8)
                        }
                    }.padding(10).frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                Text("Atualize o CatLive no computador para controlar as Vinhetas.")
                    .font(.jarasCallout).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .task(id: feedback.gateRevision) {
                do { try await Task.sleep(nanoseconds: 2_100_000_000) } catch { return }
                feedback.expireGates()
            }
            .onDisappear(perform: releaseAll)
            .onChange(of: project) { _ in releaseAll() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in releaseAll() }
    }
    private var panic: some View {
        Button { releaseAll(); feedback.stopAll(); send(.init(project: project, song: song, action: .vinhetasPanic)) } label: {
            Text("Panic").font(.system(size: 12, weight: .semibold)).frame(width: 60, height: 30)
                .foregroundStyle(.white).background(Color(hex: 0x8d2845)).cornerRadius(5)
        }.buttonStyle(.plain).accessibilityLabel("Panic")
    }
    private func preset(_ index: Int, state: DAWRemoteVinhetas) -> some View {
        Button { send(.init(project: project, song: song, action: .vinhetasPreset, value: Double(index))) } label: {
            Text(verbatim: state.presets[index].name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Color(hex: state.presets[index].color).opacity(state.selectedPreset == index ? 1 : 0.45))
                .cornerRadius(5)
        }.buttonStyle(.plain).accessibilityValue(state.selectedPreset == index ? "Selecionado" : "")
    }
    private func pads(_ indices: Range<Int>, state: DAWRemoteVinhetas, columns: Int) -> some View {
        GeometryReader { geometry in
            let rows = indices.count / columns
            let height = max(46, (geometry.size.height - CGFloat(rows - 1) * 8) / CGFloat(rows))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    pad(index, preset: state.selectedPreset, state: state).frame(height: height)
                }
            }
        }
    }
    private func pad(_ index: Int, preset: Int, state: DAWRemoteVinhetas) -> some View {
        let item = state.presets[preset].pads[index]
        let gate = feedback.gate(preset: preset, pad: index, confirmed: item.gate)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    let desired = feedback.toggleGate(preset: preset, pad: index, confirmed: item.gate)
                    send(.init(project: project, song: song, action: .vinhetasGate,
                        enabled: desired, pad: index, preset: preset))
                } label: {
                    VStack(spacing: 1) { Text("Gate"); Text(verbatim: gate ? "On" : "Off") }
                        .font(.system(size: 10, weight: .semibold)).frame(width: 34, height: 40)
                }.buttonStyle(.plain).foregroundStyle(gate ? Color.black : JarasTheme.secondary)
                    .background(gate ? JarasTheme.yellow : Color.clear).cornerRadius(4)
                VinhetasPadSurface(name: item.name, color: item.color, active: feedback.lit(preset: preset, pad: index),
                    down: { down(index, preset: preset) }, up: { release(index) },
                    touchMenusEnabled: false, contextMenusEnabled: false, edit: {}, insert: {}, learn: {})
                    .allowsHitTesting(state.available && item.loaded)
                    .opacity(item.loaded ? 1 : 0.55)
                    .accessibilityHint(item.loaded ? "" : "Sem áudio carregado")
            }.frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                Text(verbatim: item.volume <= 0 ? "−∞" : String(format: "%+.1f", 20 * log10(item.volume)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit().frame(width: 34, alignment: .leading)
                RemoteNativeSlider(value: item.volume, range: 0...2, height: 44, resetValue: 1) {
                    send(.init(project: project, song: song, action: .vinhetasVolume, value: $0, pad: index, preset: preset))
                }.accessibilityLabel("Volume do pad")
            }.frame(height: 44)
        }
    }
}

/// Vertical, two-page scrolling is native UIKit on iOS 16 as well. Eight pads
/// stay visible on each page; momentum settles with a short native animation.
private struct RemoteVinhetasPager: UIViewControllerRepresentable {
    let first: AnyView
    let second: AnyView
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.pages = [first, second]; controller.updatePages()
    }
    final class Controller: UIViewController {
        let scroll = UIScrollView()
        let content = UIHostingController(rootView: AnyView(EmptyView()))
        var pages: [AnyView] = []
        private var pageSize = CGSize.zero
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .clear
            scroll.backgroundColor = .clear; scroll.isPagingEnabled = true
            scroll.showsVerticalScrollIndicator = true; scroll.showsHorizontalScrollIndicator = false
            scroll.indicatorStyle = .white; scroll.delaysContentTouches = false
            scroll.canCancelContentTouches = true; scroll.contentInsetAdjustmentBehavior = .never; view.addSubview(scroll)
            addChild(content); content.view.backgroundColor = .clear; scroll.addSubview(content.view); content.didMove(toParent: self)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews(); let oldHeight = scroll.bounds.height
            let page = oldHeight > 0 ? (scroll.contentOffset.y / oldHeight).rounded() : 0
            scroll.frame = view.bounds
            if pageSize != view.bounds.size { updatePages() }
            if oldHeight != scroll.bounds.height { scroll.contentOffset.y = min(1, max(0, page)) * scroll.bounds.height }
        }
        func updatePages() {
            guard isViewLoaded, pages.count == 2 else { return }
            let width = max(1, view.bounds.width - 6), height = max(1, view.bounds.height)
            pageSize = view.bounds.size
            content.rootView = AnyView(VStack(spacing: 0) {
                pages[0].frame(width: width, height: height)
                pages[1].frame(width: width, height: height)
            })
            content.view.frame = CGRect(x: 0, y: 0, width: width, height: height * 2)
            scroll.contentSize = CGSize(width: view.bounds.width, height: height * 2)
        }
    }
}
#endif
