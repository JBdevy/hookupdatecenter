import SwiftUI
import UniformTypeIdentifiers
import Combine
#if os(iOS)
import UIKit
import CoreMIDI
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
            Text("Open Remote on the iPad and choose this computer.").font(.jarasCallout)
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
            .onAppear {
                remote.resumeBrowsing()
                JarasMobileApplicationDelegate.setObserverOrientation(remote.presentationAccess == .observer)
            }
            .onDisappear {
                remote.stop()
                JarasMobileApplicationDelegate.setObserverOrientation(false)
            }
            .onChange(of: remote.presentationAccess) { access in
                JarasMobileApplicationDelegate.setObserverOrientation(access == .observer)
            }
            .onChange(of: remote.connected) { connected in
                directorPIN = ""; enteringMode = nil
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
    private static var noticeImageDate = Date.distantPast
    private static var noticeImageData: Data?
    private static var lastTimerState: TeleprompterTimer?
    private static var timerRevision = UUID()
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
                regionColor: regionTextColor, unifiedColor: unifiedTextColor)
            let presentationChanged = cachedPresentationKey != presentationKey
            if presentationChanged {
                cachedPresentationKey = presentationKey
                cachedRegions = show.listedRegions.map(region)
                cachedTimelineRegions = (song?.parts ?? []).map(region)
                cachedMarkers = (song?.markers ?? []).filter { !$0.isTempo }.map {
                    .init(id: $0.id, name: song?.markerLabel($0) ?? $0.name, position: $0.position,
                        color: $0.color, section: $0.isSection, unifiedRegionID: $0.unifiedRegionID, sourceRegionID: $0.sourceRegionID)
                }
                cachedBlocks = show.listedBlocks.map {
                    .init(id: $0.id, name: $0.name, color: $0.color, beforeRegion: $0.beforeRegionId, symbol: $0.showsSymbol)
                }
                cachedPlaylistSeconds = cachedRegions.reduce(0) { $0 + max(0, $1.end - $1.start) }
                cachedDuration = song?.duration ?? 0
            }
            if presentationChanged || cachedPlayedSet != playedLiveIDs {
                cachedPlayedSet = playedLiveIDs
                cachedPlayedIDs = (song?.parts ?? []).filter { playedLiveIDs.contains($0.id) }.map(\.id)
            }
            let selected = transport.playing ? show.pitchRegion : song?.parts.first { $0.id == (show.focusedRegion.map(show.playlistRegionSourceID) ?? transport.regionId) }
            let hasMultiLoop = selected.map { part in
                part.totalLoop == true || !(part.multiLoops ?? []).isEmpty || (song?.parts.contains { candidate in
                    (candidate.id == part.parentRegionID || candidate.parentRegionID == part.id) &&
                    (candidate.totalLoop == true || !(candidate.multiLoops ?? []).isEmpty)
                } ?? false)
            } ?? false
            let information = transport.loop.enabled ? "Loop Ativo" : transport.ignoreNextAfter != nil ? "Ignore Next" : hasMultiLoop ? JarasLocalization.string("This song has an active multiloop") : ""
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
                          volume: track.volume, pan: track.pan, mute: track.mute, solo: track.solo,
                          clips: items?.clips ?? [],
                          nameColor: JarasTheme.trackNameHex(track, emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute),
                          emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute, laneCount: items?.lanes ?? 1, linkedTrack: track.stereoLink?.partner, heightScale: track.heightScale,
                          peakDB: sendsPeaks && !track.kind.isText && track.kind != .timecode ? StemAudioPlayback.shared.meter(for: track.id).peakHold.decibels : nil,
                          canMeter: !track.kind.isText && track.kind != .timecode, parentTrack: track.parentTrackID,
                          instrumentIcon: track.instrumentIcon)
                }, regions: cachedRegions, timelineRegions: cachedTimelineRegions,
                currentRegion: transport.regionId, queuedRegion: transport.queuedRegionId, focusedRegion: show.focusedRegion,
                currentPlaylistEntryId: transport.playlistEntryId, queuedPlaylistEntryId: transport.queuedPlaylistEntryId,
                position: transport.position, duration: cachedDuration,
                bpm: show.tempoControlBPM,
                playing: transport.playing, paused: transport.paused ?? false,
                subPlaying: transport.subPlay.playing, loop: transport.loop.enabled,
                masterVolume: snapshot.project.masterVolume ?? 1, masterMute: snapshot.project.masterMute ?? false,
                masterSolo: snapshot.project.masterSolo ?? false, masterMono: snapshot.project.masterMono ?? false,
                pendingSave: show.hasUnsavedChanges, saving: show.saving, message: show.message,
                tempoNeedsRender: show.tempoControlNeedsRender,
                loopStart: transport.loop.start ?? song?.parts.first(where: { $0.id == transport.regionId })?.startTime,
                loopEnd: transport.loop.end ?? song?.parts.first(where: { $0.id == transport.regionId })?.endTime,
                multiLoopsBypassed: transport.multiLoopsBypassed == true,
                setlistLiveEnabled: show.setlistLiveEnabled,
                playedLiveRegionIDs: cachedPlayedIDs,
                masterPeakDB: sendsPeaks ? StemAudioPlayback.shared.masterMeter.peakHold.decibels : nil,
                pitchRegion: show.pitchRegion?.id, pitchSemitones: show.pitchRegion?.semitones,
                setlistFontStyle: UserDefaults.standard.integer(forKey: "jaras.setlist.fontStyle"),
                prepareOnly: show.regionSetlist.preparesWithoutPlayback,
                masterColor: snapshot.project.masterColor ?? 0x414141,
                masterNameColor: JarasTheme.masterNameHex(snapshot.project.masterColor ?? 0x414141),
                regionAuto: show.regionSetlist.autoAdvance, queueStartedAt: transport.queueStartedAt,
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
                gridTempo: cachedGridTempo, gridDivisions: song?.projectTime.divisions,
                gridLines: UserDefaults.standard.object(forKey: "jaras.timeline.gridlines") as? Bool ?? (GlobalProjectTiming.load()?.settings.divisions != 0),
                gridPrimaryColor: UInt32(AppearanceColor.shared("jaras.timeline.primaryGrid", default: TimelineAppearanceDefaults.primaryGrid).value),
                gridSecondaryColor: UInt32(AppearanceColor.shared("jaras.timeline.secondaryGrid", default: TimelineAppearanceDefaults.secondaryGrid).value),
                gridBackgroundColor: UInt32(AppearanceColor.shared("jaras.timeline.background", default: TimelineAppearanceDefaults.background).value),
                playCursorColor: UInt32(AppearanceColor.shared("jaras.timeline.playCursor", default: TimelineAppearanceDefaults.playCursor).value),
                editCursorColor: UInt32(AppearanceColor.shared("jaras.timeline.editCursor", default: TimelineAppearanceDefaults.editCursor).value),
                subPlayCursorColor: UInt32(AppearanceColor.shared("jaras.timeline.subPlayCursor", default: TimelineAppearanceDefaults.subPlayCursor).value),
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
                previewPage: TeleprompterWindow.shared.previewPage)
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
            if command.action == .timerStart || command.action == .timerStop {
                lastTimerCommandID = command.id; timerRevision = UUID()
            }
            guard let show, command.project == show.snapshot.project.id else { return }
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            if command.action == .remotePanel { return }
            if command.action == .togglePreview { TeleprompterWindow.shared.togglePreview(); return }
            if command.action == .selectPreviewPage { TeleprompterWindow.shared.selectPreviewPage(Int(command.value)); return }
            if handleNotice(command) { return }
            if command.action == .timerStart {
                let timer = TeleprompterTimerController.shared, seconds = Int(command.value)
                timer.stopAndReset()
                if timer.setTargetText(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)) { timer.start() }
                return
            }
            if command.action == .timerStop { TeleprompterTimerController.shared.stopAndReset(); return }
            if command.action == .selectProjectTab {
                if let target = command.target { Self.selectProjectTabHandler?(target) }
                return
            }
            if command.action == .openRecentProject || command.action == .openRecentProjectInNewTab {
                #if os(macOS)
                if let target = command.target {
                    documents?.openRemoteProject(target, inNewTab: command.action == .openRecentProjectInNewTab)
                }
                #endif
                return
            }
            guard documents?.busy != true, command.song == show.current?.id else { return }
            if [.volume, .pan, .mute, .solo, .resetMeterPeak].contains(command.action), let target = command.target {
                guard show.current?.tracks.contains(where: { $0.id == target }) == true else { return }
            }
            if [.clipGain, .clipMute].contains(command.action) {
                guard let target = command.target, show.current?.tracks.contains(where: { track in
                    (session?.isLocalWorkspace == true || track.kind == .standard) && track.clips.contains { $0.id == target }
                }) == true else { return }
            }
            switch command.action {
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
                     remainingSeconds: state.displaySeconds(at: ProcessInfo.processInfo.systemUptime), commandID: lastTimerCommandID)
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
                     cleanDisplay: appearance.cleanDisplay, sentAt: model.sentAt.timeIntervalSince1970, imageID: imageID)
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
                if media == nil { media = active.first { $0.isProjectionMedia } }
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
        var result = DAWRemoteTeleprompter(index: index, text: settings.display(lyric?.text ?? ""), chords: settings.display(chord?.text ?? ""),
            song: settings.display(region?.name ?? ""), queued: settings.display(queueName), progress: progress,
            style: style, preview: settings.displaysPreview(previewActive), settings: settings)
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
struct IpadTapHoldTouchSurface: UIViewRepresentable {
    let tap: () -> Void
    let hold: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeUIView(context: Context) -> IpadTapHoldControl { IpadTapHoldControl() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: IpadTapHoldControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 44, height: proposal.height ?? 44)
    }
    func updateUIView(_ view: IpadTapHoldControl, context: Context) {
        view.tapAction = tap; view.holdAction = hold; view.isEnabled = enabled
    }
}
final class IpadTapHoldControl: UIButton {
    var tapAction: (() -> Void)?
    var holdAction: (() -> Void)?
    private var suppressTapAfterHold = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(self, action: #selector(released), for: .touchUpInside)
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
    @objc private func released() {
        guard isEnabled, !suppressTapAfterHold else { return }
        tapAction?()
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
            Text(verbatim: "R\nE\nM\nO\nT\nE")
                .font(.jarasSystem(size: 10, weight: .heavy)).multilineTextAlignment(.center)
                .foregroundStyle(Color.black).frame(width: width, height: 94)
                .modifier(RemoteControlSurface(color: host.enabled ? JarasTheme.green : Color(hex: 0xff3434), radius: 5))
                .contentShape(Rectangle())
        }
            .modifier(IpadTeleprompterRemoteHold(open: openSettings))
            .accessibilityLabel("Remote").accessibilityValue(host.enabled ? "On" : "Off")
            .accessibilityAction(named: Text("Configurações"), openSettings)
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

@MainActor struct NativeRemoteWorkspace: View {
    @Environment(\.isEnabled) private var controlsEnabled
    let state: DAWRemoteState
    let computerName: String
    let timer: RemoteLocalTimer
    let send: (DAWRemoteCommand) -> Void
    let exitRemote: () -> Void
    var observer = false
    var local = false
    var localShow: ShowController? = nil
    var timelineFocus: IpadTimelineFocus? = nil
    var openMetronome: (() -> Void)? = nil
    var openRegionActions: ((UUID) -> Void)? = nil
    var detectRegionBPM: ((UUID) -> Void)? = nil
    var openPatch: ((UUID?) -> Void)? = nil
    var openTrackFX: ((UUID?) -> Void)? = nil
    var openSelectedPatch: (([UUID]) -> Void)? = nil
    var openSelectedFX: (([UUID]) -> Void)? = nil
    var openTrackDetails: ((Set<UUID>) -> Void)? = nil
    var openTrackIcon: ((Set<UUID>) -> Void)? = nil
    var openClickSound: ((UUID) -> Void)? = nil
    var openMasterDetails: (() -> Void)? = nil
    var openItemMenu: ((UUID) -> Void)? = nil
    var openSelectedItemMenu: ((UUID, Set<UUID>) -> Void)? = nil
    var openItemFX: ((UUID) -> Void)? = nil
    var addTrack: (() -> Void)? = nil
    var addTrackAudio: ((UUID) -> Void)? = nil
    var addTrackText: ((UUID) -> Void)? = nil
    var addTrackMedia: ((UUID) -> Void)? = nil
    var createPlaylist: ((String, [UUID]) -> Bool)? = nil
    var addBlock: (() -> Void)? = nil
    var toggleRegionStop: (() -> Void)? = nil
    var stopsAtRegionEnd = false
    @State private var addingToPlaylist: UUID?
    @State private var creatingPlaylist = false
    var exportProject: (() -> Void)? = nil
    var groupTracks: ((Set<UUID>) -> Void)? = nil
    var groupableTracks: Set<UUID> = []
    @State private var regionMovePreview: IpadRegionMovePreview?
    @State private var editingTracks = false
    @AppStorage("jaras.ipad.transport.hidden") private var hiddenTransport = ""
    @State private var tempoStepPending = false
    @State private var pitchStepPending = false
    @State private var selectedTracks: Set<UUID> = []
    @State private var trackActionsOpen = false
    @StateObject private var trackReordering = IpadTrackReorderController()
    var openRegionLoops: ((UUID) -> Void)? = nil
    var openAdvanced: (() -> Void)? = nil
    var openSettings: (() -> Void)? = nil
    var openRemoteSettings: (() -> Void)? = nil
    var openTeleprompterRemote: ((Int) -> Void)? = nil
    @ObservedObject var remote: DAWRemoteSession = .shared
    @State private var phonePanel: DAWRemotePhonePanel = .setlist
    @State private var navigationOpen = false
    @State private var sidebarHidden = false
    @State private var projectsOpen = false
    @State private var playlistPickerOpen = false
    private struct EntryEditor: Identifiable {
        let id: UUID
        let playlist: Bool
        var name: String
        var color: UInt32
    }
    @State private var editingEntry: EntryEditor?
    @State private var removal: DAWRemoteCommand?
    @State private var confirmingRemoval = false
    @State private var duplicateQueueWarning = false
    @State private var selectedSetlistEntries: Set<UUID> = []
    @State private var setlistSelectionAnchor: UUID?
    @State private var draggingSetlistEntries: Set<UUID> = []
    @State private var setlistRowHeights: [UUID: CGFloat] = [:]
    private enum PrompterPanel: Int, Identifiable {
        case first = 1, second = 2
        var id: Int { rawValue }
    }
    @State private var prompterPanel: PrompterPanel?
    @State private var prompterFullscreen = false
    @State private var noticesOpen = false
    @State private var timerOpen = false
    @State private var sectionsOpen = false
    @State private var sectionsInList = false
    @AppStorage("jaras.ipad.parts.left.open") private var nativeLeftPartsOpen = false
    @AppStorage("jaras.ipad.parts.left.preferredWidth") private var nativeLeftPartsWidth = 240.0
    @AppStorage("jaras.ipad.vinhetas.open") private var nativeVinhetasOpen = false
    @AppStorage("jaras.ipad.vinhetas.detached") private var nativeVinhetasDetached = false
    @State private var nativeLeftPartsDragStart: Double?
    @State private var liveNativeLeftPartsWidth: Double?
    @AppStorage("catlive.remote.sections.preferredWidth") private var preferredPartsWidth = 240.0
    @State private var partsDragStart: Double?
    @State private var livePartsWidth: Double?
    private var verticalSections: Bool { true }
    @State private var remoteMIDISetlistID: UUID?
    @State private var remoteMIDIPartID: UUID?
    @State private var remoteMIDIPlaylistID: UUID?
    @AppStorage("jaras.remote.observer.setlistScale") private var observerSetlistScale = 1.0
    @State private var settingsOpen = false
    @State private var confirmSave = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var keyboardVisible = false
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
    @State private var configInitRegion: UUID?
    @State private var autoSettings = false
    @State private var unifyingRegion: UUID?
    @State private var unifyName = ""
    @AppStorage("jaras.remote.mixerHidden") private var mixerHidden = false
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
        let visible = state.tracks.filter { !hidden.contains($0.id) }
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
    private var drawerRegion: DAWRemoteState.Region? { DAWRemoteSetlistPresentation.drawer(in: state) }
    private var drawerExpanded: Bool { drawerRegion.map { expandedRegions.contains($0.id) } ?? false }
    private func toggleDrawer(_ id: UUID) {
        guard DAWRemoteSetlistPresentation.canToggleDrawer(id, in: state) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            if !expandedRegions.insert(id).inserted { expandedRegions.remove(id) }
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
    private func updatePanelSubscription() {
        guard state.timer != nil else { return }
        let panel = UIDevice.current.userInterfaceIdiom == .phone ? (observer && phonePanel.subscription > 2 ? 0 : phonePanel.subscription) : (prompterPanel?.rawValue ?? (noticesOpen ? 3 : 0))
        action(.remotePanel, value: Double(panel))
    }
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if !local, !observer, let tabs = state.projectTabs, tabs.count > 1 {
                RemoteProjectTabStrip(tabs: tabs, enabled: controlsEnabled && state.projects?.busy != true) {
                    action(.selectProjectTab, target: $0)
                }
            }
            Group {
                if UIDevice.current.userInterfaceIdiom == .phone {
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
                NameColorEditor(title: entry.playlist ? "Rename playlist" : "Edit song", initialName: entry.name,
                    initialColor: entry.color, save: { name, color in
                    send(.init(project: state.project, song: state.song, action: entry.playlist ? .renamePlaylist : .editRegion,
                        target: entry.id, value: Double(color), text: name))
                }, close: { editingEntry = nil })

            } }
        }
        .overlay {
            if let id = configInitRegion, let show = localShow {
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
        .alert("Delete", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Delete", role: .destructive) { if let removal { send(removal) }; removal = nil }
        } message: { Text(removal?.action == .deletePlaylist ? "Delete playlist?" : removal?.playlist == nil ? "Delete region and its contents?" : "Remove from playlist?") }
        .onChange(of: state.project) { _ in editingEntry = nil; removal = nil; confirmingRemoval = false }
        .onChange(of: controlsEnabled) { enabled in
            if !enabled {
                navigationOpen = false; projectsOpen = false; playlistPickerOpen = false
                noticesOpen = false; timerOpen = false; settingsOpen = false; confirmSave = false
                searchFocused = false; scrubPosition = nil; pendingSeek = nil
            } else { updatePanelSubscription() }
        }
        .confirmationDialog("Tracks", isPresented: $trackActionsOpen, titleVisibility: .visible) {
            if !selectedTracks.isEmpty, let openTrackDetails {
                Button("Editar pista") { openTrackDetails(selectedTracks) }
            }
            if local, !selectedTracks.isEmpty, let openTrackIcon {
                Button("Ícone da pista") { openTrackIcon(selectedTracks) }
            }
            if !selectedTracks.isEmpty, let openSelectedPatch {
                Button("Patch") { openSelectedPatch(state.tracks.filter { selectedTracks.contains($0.id) }.map(\.id)) }
            }
            if selectedTracks.count == 1, let id = selectedTracks.first, groupableTracks.contains(id), let addTrackAudio {
                Button("Add Stems") { addTrackAudio(id) }
            }
            Button("Create group") { groupTracks?(selectedTracks) }
                .disabled(selectedTracks.count < 2 || !selectedTracks.isSubset(of: groupableTracks))
            if localShow?.current?.groupsForTrackSelection(selectedTracks).isEmpty == false {
                Button("Ungroup") { localShow?.ungroupTracks(selectedTracks) }
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
        workspaceContent
        .onChange(of: state.selectedPlaylist) { _ in selectedSetlistEntries = []; draggingSetlistEntries = []; setlistSelectionAnchor = nil }
        .onChange(of: state.project) { _ in selectedSetlistEntries = []; draggingSetlistEntries = []; setlistSelectionAnchor = nil; editingTracks = false; selectedTracks.removeAll(); regionMovePreview = nil; trackReordering.cancel(); trackScrolling.selectedItem = nil; trackScrolling.pointerReset = UUID(); deletingTracks = nil; splittingItems = nil; nativeMarker = nil; nativeNormalization = false; tempoStepPending = false; pitchStepPending = false }
        .onAppear {
            if !local && !observer { RemoteMIDIActions.shared.start() }
            if local, let localShow {
                localShow.togglePartsPanel = { [open = $nativeLeftPartsOpen] in open.wrappedValue.toggle() }
                localShow.toggleSetlistPanel = { toggleMainSetlist() }
                localShow.toggleTracksPanel = { toggleMainTrackMixer() }
                localShow.toggleTeleprompterWindow = { showPrompter(prompterPanel == .first ? nil : .first) }
            }
        }
        .onDisappear { if !local { RemoteMIDIActions.shared.stop() } }
        .onReceive(RemoteMIDIActions.shared.$event.dropFirst().compactMap { $0 }) { event in
            if !local && !observer { performRemoteMIDI(event.action) }
        }
        .onReceive(localShow?.$setlistNavigationRequest.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { request in
            guard local, let request, let localShow, let song = localShow.current else { return }
            let parts = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
            let entries: [SetlistEntry] = setlistRowsCache.entries(in: state, expanded: expandedRegions, query: search).compactMap { entry in
                guard case .region(let row) = entry, let part = localShow.playlistRegion(row.region.id) ?? parts[row.region.id] else { return nil }
                return .region(part, number: row.number ?? 0)
            }
            if !entries.isEmpty {
                trackScrolling.selectionScope = .setlist
                localShow.stepRegion(request.direction, entries: entries)
            }
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
        .onReceive(localShow?.$normalizeItemsRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            if nativeInputEnabled, !trackScrolling.itemSelection.items.isEmpty { nativeNormalization = true }
        }
        .onReceive(localShow?.$tempoMarkerRequest.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in beginNativeMarker(tempo: true) }
    }
    var body: some View {
        nativeEditingWorkspace
        .background(RemoteKeyboardDismissal(active: searchFocused) { searchFocused = false })
        .background(RemoteSidebarEdgeReveal(active:
            sidebarHidden && controlsEnabled && state.projects?.busy != true &&
                !navigationOpen && !projectsOpen && !playlistPickerOpen && !settingsOpen &&
                !timerOpen && !noticesOpen && !confirmSave,
            reveal: revealSidebar))
        .overlay(alignment: .bottomLeading) {
            // These layouts have no visible transport footer. Keep a local
            // way back without adding playback controls to Observer mode.
            if sidebarHidden && (observer || prompterFullscreen || keyboardVisible) {
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
        !confirmSave && deletingTracks == nil && splittingItems == nil && !nativeNormalization &&
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
            case 1 where command: if !event.isRepeat { Task { await show.save() } }; return true
            case 0 where command:
                if trackScrolling.selectionScope == .tracks {
                    selectedTracks = Set(visibleTracks.filter { groupableTracks.contains($0.id) }.map(\.id))
                    show.setMixerTrackSelection(selectedTracks, anchor: selectedTracks.first)
                } else if trackScrolling.selectionScope == .grid {
                    trackScrolling.itemSelection.replace(Set(visibleTracks.flatMap(\.clips).map(\.id)))
                }
                return true
            case 8 where command, 7 where command:
                guard trackScrolling.selectionScope == .grid else { return ControlMappings.shared.handleHardwareKey(event) }
                if !event.isRepeat { _ = show.copyItems(trackScrolling.itemSelection.items, moving: event.keyCode == 7) }
                return true
            case 9 where command:
                if !event.isRepeat {
                    let pasted = show.pasteItems()
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
            if !event.isRepeat { deleteNativeSelection() }
            return true
        }
        if flags.isEmpty, event.keyCode == 53 {
            if !event.isRepeat {
                trackScrolling.pointerReset = UUID()
                show.send(.escape)
                trackScrolling.itemSelection.replace([]); selectedTracks = []
                show.setMixerTrackSelection([], anchor: nil)
            }
            return true
        }
        if ControlMappings.shared.handleHardwareKey(event) { return true }
        if (flags == .shift || flags == .option), event.keyCode == 46 {
            if !event.isRepeat { beginNativeMarker(section: flags == .option) }
            return true
        }
        if flags == .shift, event.keyCode == 15 {
            if !event.isRepeat { show.regionsFromSelection(trackScrolling.itemSelection.items) }
            return true
        }
        return false
    }
    private func deleteNativeSelection() {
        guard let show = localShow, let song = show.current else { return }
        switch trackScrolling.selectionScope {
        case .grid:
            show.deleteItems(trackScrolling.itemSelection.items.intersection(visibleTracks.flatMap(\.clips).map(\.id)))
            trackScrolling.itemSelection.retain(Set(show.current?.tracks.flatMap(\.clips).map(\.id) ?? []))
        case .tracks:
            requestNativeTrackDeletion(selectedTracks)
        case .setlist:
            if let id = show.focusedRegion { requestRemoval(.deleteRegion, id: id, playlist: state.selectedPlaylist) }
        }
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
        let ids = Set(song.tracks.flatMap(\.clips).filter {
            trackScrolling.itemSelection.items.contains($0.id) && $0.startTime < time && $0.startTime + $0.duration > time
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
        withAnimation(.easeOut(duration: 0.16)) { sidebarHidden = true }
    }
    private func revealSidebar() {
        withAnimation(.easeOut(duration: 0.16)) { sidebarHidden = false }
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
    private func choosePhonePanel(_ panel: DAWRemotePhonePanel) {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let next = phonePanel.selecting(panel)
        phonePanel = observer && next == .grid ? .setlist : next
        prompterFullscreen = false
        scrubPosition = nil; pendingSeek = nil
    }
    private func phonePanelButton(_ panel: DAWRemotePhonePanel, title: String, icon: String? = nil) -> some View {
        Button { choosePhonePanel(panel) } label: {
            Group {
                if panel == .sections { SectionButtonsIcon() }
                else if let icon { Image(systemName: icon).font(.jarasSystem(size: 18, weight: .semibold)) }
                else { Text(verbatim: title).font(.jarasSystem(size: 11, weight: .bold)) }
            }.frame(width: 44, height: 44)
                .modifier(RemoteControlSurface(color: phonePanel == panel ? JarasTheme.green.opacity(0.14) : nil, radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle())
            .foregroundStyle(phonePanel == panel ? JarasTheme.green : panel == .notices ? JarasTheme.yellow : panel.subscription > 0 ? .red : JarasTheme.secondary)
            .accessibilityLabel(LocalizedStringKey(title)).accessibilityValue(phonePanel == panel ? "Shown" : "Hidden")
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
    private var phoneDirectorWorkspace: some View {
        HStack(spacing: sidebarHidden ? 0 : 1) {
            RemoteSidebarRail(hidden: sidebarHidden) {
                Menu {
                    Button("Projects") { projectsOpen = true }
                    Button("Exit Remote", action: exitRemote)
                } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Menu")
                phonePanelButton(.mixer, title: "Track Mixer", icon: "slider.horizontal.3")
                phonePanelButton(.setlist, title: "Setlist", icon: "list.bullet")
                phonePanelButton(.grid, title: "Grid", icon: "square.grid.3x3")
                phonePanelButton(.teleprompter1, title: "TP1")
                phonePanelButton(.teleprompter2, title: "TP2")
                phonePanelButton(.notices, title: "Notices", icon: "text.bubble")
                Button { timerOpen = true } label: { Image(systemName: "clock").frame(width: 44, height: 44) }
                    .foregroundStyle(Color.blue).accessibilityLabel("Timer")
            Button { confirmSave = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }
                    .foregroundStyle(JarasTheme.green).disabled(!state.pendingSave || state.saving).accessibilityLabel("Save")
                Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                phonePanelButton(.sections, title: "Parts")
                Button { if let openSettings { openSettings() } else { settingsOpen = true } } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .accessibilityLabel("Configurações")
                hideSidebarButton(width: 44)
            }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
            VStack(spacing: 1) {
                if !prompterFullscreen { phoneTransport }
                Group {
                    switch phonePanel {
                    case .mixer: trackMixer
                    case .setlist: setlist
                    case .grid:
                        RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition, local: local, localShow: localShow, timelineFocus: timelineFocus, editorEnabled: nativeInputEnabled, regionDrag: $regionMovePreview, openRegionActions: openRegionActions, openItemMenu: openItemMenu, openSelectedItemMenu: openSelectedItemMenu, openItemFX: openItemFX, openMarkerEditor: { nativeMarker = $0 }, regionCommand: { id, command in
                            if command == "bpm" { detectRegionBPM?(id) }
                            else if command == "loops" { openRegionLoops?(id) }
                            else if command == "unify" { unifyName = ""; unifyingRegion = id }
                            else if command == "init" { configInitRegion = id }
                        },
                            control: { action($0, target: $1, value: $2) }, preview: { scrubPosition = $0 }, seek: { position in
                                scrubPosition = nil
                                if local { action(.seek, value: position); return }
                                guard !state.playing, let region = selectedTimelineRegion else { return }
                                pendingSeek = position; seekSentAt = Date(); action(.seek, target: region.id, value: position)
                            })
                    case .teleprompter1, .teleprompter2:
                        RemoteNativeTeleprompterPanel(index: phonePanel.subscription, timer: timer,
                            fullscreen: prompterFullscreen, toggleFullscreen: { prompterFullscreen.toggle() }, managesSubscription: false, remote: remote)
                    case .notices:
                        RemoteNativeNoticesView(close: { choosePhonePanel(.grid) }, managesSubscription: false, remote: remote)
                    case .sections: remoteSections
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                if phonePanel == .setlist || phonePanel == .sections {
                    setlistControls.padding(.horizontal, 10)
                }
                if !keyboardVisible && !prompterFullscreen {
                    VStack(spacing: 0) {
                        SongNameDisplay(title: "Next", name: state.songDisplays?.next, bpm: state.songDisplays?.nextBPM).frame(height: 25)
                        phoneDisplayDivider
                        SongNameDisplay(title: state.subPlaying ? "Sub Play" : "Queued", name: state.songDisplays?.queued, bpm: state.songDisplays?.queuedBPM).frame(height: 25)
                        phoneDisplayDivider
                        HStack(spacing: 0) {
                            if sidebarHidden {
                                restoreSidebarButton()
                                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1, height: 25)
                            }
                            phoneInformationDisplay
                        }.frame(height: 25)
                    }.background(RemoteSurface.display)
                        .overlay(Rectangle().stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
                }
            }.frame(maxWidth: .infinity).disabled(state.projects?.busy == true)
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
                }, close: { timerOpen = false }).presentationDetents([.height(230)]).preferredColorScheme(.dark)
            }
            .sheet(isPresented: $settingsOpen) { NativeRemoteSettingsView().presentationDetents([.large]).preferredColorScheme(.dark) }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) },
                    openInNewTab: { action(.openRecentProjectInNewTab, target: $0) },
                    close: { projectsOpen = false })
            }
            .alert("Do you want to save this project?", isPresented: $confirmSave) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { action(.save) }
            }
    }
    private func phoneTransportButton(_ title: String, icon: String, active: Bool = false, color: Color = JarasTheme.green, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.jarasSystem(size: 14, weight: .semibold))
                Text(LocalizedStringKey(title)).font(.jarasSystem(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteControlSurface(color: active ? color.opacity(0.35) : nil, radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(color)
    }
    private var phoneTransport: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(state.playing ? "Now playing" : "Selected song").font(.jarasSystem(size: 10, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(verbatim: timeText).monospacedDigit().font(.jarasSystem(size: 12, weight: .semibold))
                }.foregroundStyle(JarasTheme.secondary)
                Text(verbatim: state.songDisplays?.current ?? selectedTimelineRegion?.name ?? state.songName)
                    .font(.jarasSystem(size: 13, weight: .semibold)).foregroundStyle(JarasTheme.green).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(6).background(RemoteSurface.display).cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
            HStack(spacing: 4) {
                phoneTransportButton(state.playing || state.paused ? "Stop" : "Play", icon: state.playing || state.paused ? "stop.fill" : "play.fill", active: state.playing) {
                    action(state.playing || state.paused ? .stop : .play)
                }
                phoneTransportButton(state.paused ? "Play" : "Pause", icon: state.paused ? "play.fill" : "pause.fill", active: state.paused, color: JarasTheme.yellow) {
                    action(state.paused ? .play : .pause)
                }.disabled(!state.playing && !state.paused)
                phoneTransportButton("Sub Play", icon: "play.fill", active: state.subPlaying, color: JarasTheme.yellow) { action(state.subPlaying ? .subStop : .subPlay) }.disabled(!state.playing)
                phoneTransportButton("Repeat", icon: "repeat", active: state.loop, color: state.loop ? JarasTheme.yellow : .red) { action(.toggleLoop) }
                    .modifier(JarasBlink(active: state.loop, interval: 0.55, lowOpacity: 0.45))
            }
            HStack(spacing: 6) { bpmControl; tunerControl }
        }.padding(6).background(RemoteSurface.panel)
    }
    private var phoneDisplayDivider: some View {
        Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1).allowsHitTesting(false)
    }
    private var phoneInformationDisplay: some View {
        TransportInformationMessage(message: state.loop ? "Loop Ativo" : state.footerInformation ?? "",
            beatPhase: state.loop ? state.footerLoopBeatPhase : nil, steady: !state.loop)
            .font(.jarasSystem(size: 10, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
            .multilineTextAlignment(.center).accessibilityLabel("Information")
    }
    private var observerSettingsButton: some View {
        Button { settingsOpen = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
            .accessibilityLabel("Configurações")
            .popover(isPresented: $settingsOpen) { NativeRemoteSettingsView(observer: true).preferredColorScheme(.dark) }
    }
    private var phoneRepertoire: some View {
        HStack(spacing: sidebarHidden ? 0 : 1) {
            RemoteSidebarRail(hidden: sidebarHidden) {
                Menu { Button("Exit Remote", action: exitRemote) } label: {
                    Image(systemName: "line.3.horizontal").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Menu")
                phonePanelButton(.setlist, title: "Setlist", icon: "list.bullet")
                phonePanelButton(.teleprompter1, title: "TP1")
                phonePanelButton(.teleprompter2, title: "TP2")
                Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                observerSettingsButton
                hideSidebarButton(width: 44)
            }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
            VStack(spacing: 1) {
                if !prompterFullscreen {
                    VStack(spacing: 5) {
                        phoneObserverDisplay(state.playing ? "Now playing" : "Selected song", name: state.songDisplays?.current ?? observerCurrentName, color: JarasTheme.green)
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
    private func phoneObserverDisplay(_ title: String, name: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title)).font(.jarasSystem(size: 10, weight: .bold, design: .rounded)).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: name).font(.jarasSystem(size: 13, weight: .semibold)).foregroundStyle(color).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RemoteSurface.display).cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
    }
    private var observerWorkspace: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - (sidebarHidden ? 0 : RemoteSidebarMetrics.width + 1))
            let portrait = geometry.size.height > geometry.size.width
            let headerLayout = portrait ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            HStack(spacing: sidebarHidden ? 0 : 1) {
                RemoteSidebarRail(hidden: sidebarHidden) {
                    Button { navigationOpen.toggle() } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }
                        .accessibilityLabel("Abrir barra lateral")
                    topPrompterButton(.first, title: "TP1", minimumHeight: RemoteSidebarMetrics.buttonSize)
                    topPrompterButton(.second, title: "TP2", minimumHeight: RemoteSidebarMetrics.buttonSize)
                    Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                    observerSettingsButton
                hideSidebarButton(width: 44)
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
        return ScrollView(.vertical) {
            LazyVStack(spacing: 5) {
                ForEach(setlistRowsCache.entries(in: state, expanded: expandedRegions, query: "")) { entry in
                    switch entry {
                    case .block(let block): RemoteSetlistBlockLabel(block: block, fontStyle: state.setlistFontStyle ?? 0, scale: min(2.5, max(1, observerSetlistScale))).equatable()
                    case .region(let row):
                    let region = row.region
                    setlistLabel(region.name, number: row.number, played: played.contains(region.sourceRegionId ?? region.id), selected: observerRegion(region.id, contains: state.focusedRegion),
                        active: state.playing && observerRegion(region.id, contains: state.setlistCurrentEntryId), queued: observerRegion(region.id, contains: state.setlistQueuedEntryId),
                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? 0xffffff),
                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.setlistCurrentEntryId ? state.position : region.start)))),
                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                        .modifier(RemoteRegionDrawerGesture(enabled: row.hasDrawer, toggle: { toggleDrawer(region.id) }))
                        .padding(.leading, row.child ? 20 : 0)
                    }
                }
                if !local && state.regions.isEmpty && (state.setlistBlocks?.isEmpty ?? true) {
                    ForEach(state.songs) { song in Text(verbatim: song.name).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RemoteSurface.panel).cornerRadius(5) }
                }
            }.padding(8)
        }
    }
    private func observerRegion(_ region: UUID, contains id: UUID?) -> Bool {
        guard let id else { return false }
        return id == region || state.timelineRegions.first { $0.id == id }?.parentRegion == region
    }
    private var directorWorkspace: some View {
        GeometryReader { geometry in
            let railWidth = local ? RemoteSidebarMetrics.width * 0.8 : RemoteSidebarMetrics.width
            let railButton = railWidth - 8
            let contentWidth = max(0, geometry.size.width - (sidebarHidden ? 0 : railWidth + 1))
            let panelSpace = max(1, contentWidth - (local ? 44 : 20))
            let iconExtension = panelWidths.track > 0 ? min(trackIconWidth, panelSpace * panelWidths.grid) : 0
            let baseSetlist = prompterFullscreen ? 0 : prompterPanel == nil ? panelSpace * panelWidths.setlist : max(1, contentWidth - (local ? 22 : 10)) * prompterSetlistFraction
            let freeSpace = prompterPanel == nil ? panelSpace * panelWidths.grid - iconExtension : max(0, contentWidth - (local ? 22 : 10) - baseSetlist)
            let rightPartsVisible = sectionsOpen && verticalSections && baseSetlist > 0 && !prompterFullscreen
            let nativeParts = RemoteNativePartsLayout(available: freeSpace,
                leftRequested: liveNativeLeftPartsWidth ?? nativeLeftPartsWidth,
                rightRequested: livePartsWidth ?? preferredPartsWidth,
                leftVisible: nativeLeftPartsOpen && prompterPanel == nil && !prompterFullscreen,
                rightVisible: rightPartsVisible)
            let leftParts = nativeParts.left
            let parts = nativeParts.right
            HStack(spacing: sidebarHidden ? 0 : 1) {
                RemoteSidebarRail(hidden: sidebarHidden, width: railWidth) {
                    Button { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } } label: {
                        Image(systemName: "line.3.horizontal").font(.jarasSystem(size: 17, weight: .semibold))
                            .frame(width: railButton, height: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).accessibilityLabel("Abrir barra lateral")
                    Button { withAnimation(.easeOut(duration: 0.16)) {
                        toggleMainTrackMixer()
                    } } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.jarasSystem(size: 15, weight: .semibold))
                            .foregroundStyle(prompterPanel != nil || mixerCollapsed ? Color(hex: 0xc44545) : JarasTheme.green)
                            .frame(width: railButton, height: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                        .accessibilityLabel(prompterPanel != nil || mixerCollapsed ? "Expandir Track-Mixer" : "Recolher Track-Mixer")
                        .accessibilityValue(prompterPanel != nil || mixerCollapsed ? "Hidden" : "Shown")
                    Button { showPrompter(prompterPanel == .first ? nil : .first) } label: {
                        Text(verbatim: "TP1").font(.jarasSystem(size: 10, weight: .bold)).frame(width: railButton, height: 44)
                    }.foregroundStyle(prompterPanel == .first ? JarasTheme.green : Color(hex: 0xff5555))
                        .accessibilityLabel("Teleprompter 1").accessibilityValue(prompterPanel == .first ? "On" : "Off")
                        .modifier(IpadTeleprompterRemoteHold(open: openTeleprompterRemote.map { callback in { callback(1) } }, surface: true))
                    Button { showPrompter(prompterPanel == .second ? nil : .second) } label: {
                        Text(verbatim: "TP2").font(.jarasSystem(size: 10, weight: .bold)).frame(width: railButton, height: 44)
                    }.foregroundStyle(prompterPanel == .second ? JarasTheme.green : Color(hex: 0xff5555))
                        .accessibilityLabel("Teleprompter 2").accessibilityValue(prompterPanel == .second ? "On" : "Off")
                        .modifier(IpadTeleprompterRemoteHold(open: openTeleprompterRemote.map { callback in { callback(2) } }, surface: true))
                    Button { noticesOpen = true } label: {
                        Image(systemName: "text.bubble").font(.jarasSystem(size: 15, weight: .medium)).frame(width: railButton, height: 44)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.yellow).accessibilityLabel("Notices")
                        .popover(isPresented: $noticesOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                            RemoteNativeNoticesView(close: { noticesOpen = false }, managesSubscription: false, remote: remote)
                                // An ideal size lets UIKit reduce the popover
                                // above the keyboard instead of cropping it.
                                .frame(idealWidth: 440, maxWidth: 440, idealHeight: 500, maxHeight: 500)
                                .preferredColorScheme(.dark)
                        }
                    Button { timerOpen = true } label: {
                        Image(systemName: "clock").font(.jarasSystem(size: 16, weight: .medium)).frame(width: railButton, height: 44)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(Color(hex: 0x409cff)).accessibilityLabel("Timer")
                        .popover(isPresented: $timerOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
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
                    if local, let openRemoteSettings {
                        IpadNativeRemoteToggle(openSettings: openRemoteSettings, width: railButton)
                        IpadNativePreviewButton(width: railButton)
                    } else if !local {
                        IpadPreviewButton(width: railButton, active: state.previewActive == true,
                            page: state.previewPage ?? 0,
                            toggle: { action(.togglePreview) },
                            selectPage: { action(.selectPreviewPage, value: Double($0)) })
                            .disabled(state.previewActive == nil)
                    }
                    Spacer(minLength: RemoteSidebarMetrics.groupSpacing)
                    if local, let localShow {
                        Button { nativeVinhetasOpen.toggle() } label: {
                            Image(systemName: "square.grid.4x3.fill").font(.jarasSystem(size: 17, weight: .semibold))
                                .frame(width: railButton, height: 44).contentShape(Rectangle())
                        }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                            .foregroundStyle(nativeVinhetasOpen ? JarasTheme.green : JarasTheme.secondary)
                            .accessibilityLabel("Vinhetas")
                            .contextMenu {
                                Button(nativeVinhetasDetached ? "Indexar" : "Desindexar") {
                                    nativeVinhetasDetached.toggle(); nativeVinhetasOpen = true
                                }
                            }
                    }
                    Button {
                        nativeLeftPartsOpen.toggle(); liveNativeLeftPartsWidth = nil; nativeLeftPartsDragStart = nil
                    } label: {
                        PartsListIcon().frame(width: railButton, height: 44)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                        .foregroundStyle(nativeLeftPartsOpen ? JarasTheme.green : JarasTheme.secondary)
                        .accessibilityLabel("Parts à esquerda")
                        .accessibilityValue(nativeLeftPartsOpen ? "Shown" : "Hidden")
                    Button { if let openSettings { openSettings() } else { settingsOpen = true } } label: {
                        Image(systemName: "gearshape").font(.jarasSystem(size: 17, weight: .semibold))
                            .frame(width: railButton, height: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(settingsOpen ? JarasTheme.green : JarasTheme.secondary)
                        .accessibilityLabel("Configurações")
                        .popover(isPresented: $settingsOpen) { NativeRemoteSettingsView().preferredColorScheme(.dark) }
                    hideSidebarButton(width: railButton)
                }
                VStack(spacing: 1) {
                    if !prompterFullscreen { transportBar }
                    HStack(spacing: 0) {
                        if let panel = prompterPanel {
                            let space = max(1, contentWidth - (local ? 22 : 10))
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
                                .frame(width: prompterFullscreen ? 0 : (local ? 22 : 10)).clipped()
                                .allowsHitTesting(!prompterFullscreen).accessibilityHidden(prompterFullscreen)
                        } else {
                            if leftParts.total > 0 {
                                remoteSections.frame(width: leftParts.content).clipped()
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
                            trackMixer.frame(width: panelSpace * panelWidths.track + iconExtension).clipped()
                                .allowsHitTesting(!mixerCollapsed).accessibilityHidden(mixerCollapsed)
                            resizeHandle(label: "Ajustar largura do Track-Mixer", changed: { translation in
                                let start = trackResizeStart ?? panelWidths
                                if trackResizeStart == nil { trackResizeStart = start }
                                let widths = start.resizingTrack(by: translation / panelSpace)
                                if panelWidths != widths { livePanelWidths = widths }
                            }, ended: finishPanelResize)
                        RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition, local: local, localShow: localShow, timelineFocus: timelineFocus, editorEnabled: nativeInputEnabled, regionDrag: $regionMovePreview, openRegionActions: openRegionActions, openItemMenu: openItemMenu, openSelectedItemMenu: openSelectedItemMenu, openItemFX: openItemFX, openMarkerEditor: { nativeMarker = $0 }, regionCommand: { id, command in
                            if command == "bpm" { detectRegionBPM?(id) }
                            else if command == "loops" { openRegionLoops?(id) }
                            else if command == "unify" { unifyName = ""; unifyingRegion = id }
                            else if command == "init" { configInitRegion = id }
                        },
                            control: { action($0, target: $1, value: $2) },
                            preview: { scrubPosition = $0 }, seek: { position in
                                scrubPosition = nil
                                if local { action(.seek, value: position); return }
                                guard !state.playing, let region = selectedTimelineRegion else { return }
                                pendingSeek = position; seekSentAt = Date()
                                action(.seek, target: region.id, value: position)
                            }).frame(width: max(0, panelSpace * panelWidths.grid - parts.total - leftParts.total - iconExtension)).clipped()
                                .allowsHitTesting(panelWidths.grid > 0).accessibilityHidden(panelWidths.grid == 0)
                        resizeHandle(label: "Ajustar largura do Setlist", changed: { translation in
                            let start = setlistResizeStart ?? panelWidths
                            if setlistResizeStart == nil { setlistResizeStart = start }
                            let widths = start.resizingSetlist(by: translation / panelSpace)
                            if panelWidths != widths { livePanelWidths = widths }
                        }, ended: finishPanelResize)
                        }
                        let setlistWidth = prompterFullscreen ? 0 : prompterPanel == nil ? panelSpace * panelWidths.setlist : max(1, contentWidth - (local ? 22 : 10)) * prompterSetlistFraction
                        setlist.frame(width: setlistWidth).clipped()
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
                            remoteSections.frame(width: parts.content).clipped()
                        }
                    }
                    if local, nativeVinhetasOpen, !nativeVinhetasDetached, !prompterFullscreen, let localShow {
                        IpadVinhetasPanel(touchMenusEnabled: editingTracks, createTrack: { _ = localShow.createVinhetasTrack() })
                            .frame(height: min(260, geometry.size.height * 0.42))
                    }
                    if !keyboardVisible && !prompterFullscreen { footer }


                }.frame(width: contentWidth).disabled(state.projects?.busy == true)
            }
        }.background(JarasTheme.line)
            .overlay(alignment: .topLeading) {
                if local, nativeVinhetasOpen, nativeVinhetasDetached, let localShow {
                    IpadVinhetasFloatingPanel(touchMenusEnabled: editingTracks, createTrack: { _ = localShow.createVinhetasTrack() },
                        dock: { nativeVinhetasDetached = false }, close: { nativeVinhetasOpen = false })
                }
            }
            .overlay(alignment: .topLeading) {
                if navigationOpen {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture { navigationOpen = false }
                        SidebarView(close: { navigationOpen = false }, openProjects: { if local { exitRemote() } else { projectsOpen = true } }, exit: exitRemote)
                            .frame(width: 210).frame(maxHeight: .infinity)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 4)
                    }
                }
            }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) },
                    openInNewTab: { action(.openRecentProjectInNewTab, target: $0) },
                    close: { projectsOpen = false })
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
            .alert("Do you want to save this project?", isPresented: $confirmSave) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { action(.save) }
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
                if UIDevice.current.userInterfaceIdiom == .phone {
                    choosePhonePanel(phonePanel.togglingFooterParts())
                } else {
                    let wasOpen = sectionsOpen && sectionsInList
                    sectionsInList = true
                    sectionsOpen = !wasOpen
                }
            })
    }
    private var remoteSections: some View {
        let playback = state.sectionPlayback
        let current = state.timelineRegions.first { $0.id == playback?.currentRegion }
        let queued = state.timelineRegions.first { $0.id == playback?.secondaryRegion }
        return Group {
            if verticalSections {
                VStack(spacing: 4) {
                    cancelSectionButton.padding([.top, .leading, .trailing], 4)
                    SectionListTabs(current: current?.name, queued: queued?.name, subPlaying: state.subPlaying) { secondary in
                        remoteSectionBank(secondary: secondary)
                    }
                }
            } else {
                HStack(spacing: 1) {
                    remoteSectionBank(secondary: false)
                    Rectangle().fill(JarasTheme.secondary.opacity(0.35)).frame(width: 1)
                    remoteSectionBank(secondary: true)
                }.padding(5).background(RemoteSurface.panel)
            }
        }
    }
    private func remoteSectionBank(secondary: Bool) -> some View {
        let playback = state.sectionPlayback
        let id = secondary ? playback?.secondaryRegion : playback?.currentRegion
        let region = state.timelineRegions.first { $0.id == id }
        let markers: [TimelineMarker] = (state.markers ?? []).filter { marker in
            marker.section == true && region.map { marker.position >= $0.start && marker.position <= $0.end } == true
        }.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
            .map { TimelineMarker(id: $0.id, name: $0.name.uppercased(), position: $0.position, color: $0.color, section: true) }
        let end = secondary ? region?.end ?? 0 : playback?.currentEnd ?? region?.end ?? 0
        return SmoothSeekBankView(title: secondary ? (state.subPlaying ? "Sub Play" : "Queued") : "Playing / Selected",
            name: region?.name ?? "—", markers: markers, end: end,
            position: secondary ? playback?.secondaryPosition ?? 0 : playback?.position ?? state.position,
            showsPosition: !secondary || state.subPlaying, positionRunning: secondary ? state.subPlaying : state.playing, queued: playback?.queuedMarker,
            trigger: playback?.nextTrigger, queueStartedAt: playback?.queueStartedAt, playbackPosition: state.position, playbackRunning: state.playing,
            select: { action(.queueSection, target: $0) }, verticalList: verticalSections,
            regionID: region?.id, regionStart: region?.start ?? 0)
    }
    private var footer: some View {
        let displays = state.songDisplays
        let total = displays?.playlistSeconds ?? state.regions.filter { $0.parentRegion == nil }.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let seconds = Int(min(Double(Int.max / 2), max(0, total)))
        return HStack(spacing: 10) {
            if sidebarHidden { restoreSidebarButton() }
            ResourceUsageView(memoryScope: .device)
                .font(.jarasSystem(size: 9, weight: .medium, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityElement(children: .combine)
            FooterSongDisplays(next: displays?.next, nextBPM: displays?.nextBPM,
                queued: displays?.queued, queuedBPM: displays?.queuedBPM, subPlaying: state.subPlaying,
                duration: String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
        }.padding(.horizontal, 8).padding(.vertical, 3).frame(height: 31).background(RemoteSurface.panel)
    }
    private func resizeHandle(label: String, changed: @escaping (Double) -> Void, ended: @escaping () -> Void) -> some View {
        ZStack {
            JarasTheme.panel
            RoundedRectangle(cornerRadius: 2).fill(JarasTheme.secondary).frame(width: 3, height: 36)
        }.frame(width: local ? 22 : 10).contentShape(Rectangle())
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
    private var masterStrip: some View {
        VStack(spacing: 1) {
            HStack(spacing: local ? 3 : 4) {
                Button { action(.masterMono) } label: {
                    ZStack {
                        Text("Stereo").lineLimit(1).opacity(state.masterMono ? 0 : 1)
                        if state.masterMono {
                            Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: -3.5)
                            Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: 3.5)
                        }
                    }.font(.jarasSystem(size: 10, weight: .semibold)).frame(width: 58, height: 28)
                        .foregroundStyle(state.masterMono ? JarasTheme.green : JarasTheme.text)
                        .modifier(RemoteControlSurface(radius: 3))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Master Stereo/Mono")
                    .accessibilityValue(state.masterMono ? "Mono" : "Stereo")
                if !local, let openPatch {
                    Button("Patch") { openPatch(nil) }.buttonStyle(RemoteNativeTrackButtonStyle(width: 44, touchPadding: 0, height: 28))
                }
                if let openTrackFX {
                    Button("FX") { openTrackFX(nil) }.buttonStyle(RemoteNativeTrackButtonStyle(width: local ? 28 : 32, touchPadding: 0, height: 28))
                }
                if local, let localShow { IpadMasterPanFader(show: localShow).frame(width: 80, height: 28) }
                Button { action(.mute) } label: { Text(verbatim: "M") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterMute ? .red : nil, width: local ? 28 : 32, touchPadding: 0, height: 28))
                Button { action(.solo) } label: { Text(verbatim: "S") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterSolo ? JarasTheme.yellow : nil, width: local ? 28 : 32, touchPadding: 0, height: 28))
            }.frame(maxWidth: .infinity, alignment: local ? .leading : .trailing).frame(height: 28)
            HStack {
                Text(verbatim: "Master").font(.jarasSystem(size: 11, weight: .semibold))
                    .foregroundStyle(remoteColor(state.masterNameColor ?? 0xffffff)).frame(maxWidth: .infinity)
                RemotePeakReadout(decibels: state.masterPeakDB, name: "Master", project: state.project, song: state.song, target: nil, nameColor: state.masterNameColor ?? 0xffffff, reset: { action(.resetMeterPeak) }).equatable()
            }.frame(height: 14)
            HStack(spacing: 3) {
                Text(remoteDecibelText(state.masterVolume)).font(.jarasSystem(size: 10, weight: .semibold, design: .monospaced)).frame(width: 36, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { action(.volume, value: 1) }
                RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(state.masterVolume), range: -60...12, height: 20) { action(.volume, value: DAWRemoteFaderScale.gain($0)) }
                    .accessibilityLabel("Master volume")
            }
        }.padding(.leading, local ? 19 : 6).padding(.trailing, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity).frame(height: local ? 70 : RemoteNativeGridMetrics.rulerAreaHeight, alignment: .top)
            .background(remoteColor(state.masterColor ?? 0x414141).opacity(0.5)).cornerRadius(6)
            .overlay(alignment: .leading) {
                if local { IpadMixerMeter(meter: StemAudioPlayback.shared.masterMeter).frame(width: 10).padding(.vertical, 5).padding(.leading, 2) }
            }
            .contextMenu {
                if local, let openMasterDetails { Button("Editar pista", action: openMasterDetails) }
                if local, let openPatch { Button("Patch") { openPatch(nil) } }
            }
    }
    private var transportBar: some View {
        HStack(alignment: .top, spacing: local ? 5 : 8) {
            if local {
                masterStrip.frame(width: 260)
            } else {
            VStack(spacing: 5) {
                HStack(spacing: local ? 4 : 6) {
                    topPrompterButton(.first, title: "TP1")
                    topPrompterButton(.second, title: "TP2")
                }.frame(height: 25)
                RemoteNativeTimerView(timer: timer, send: {
                    guard state.timer != nil else { return }
                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                }, close: {}, compact: true)
            }.frame(width: 176)
            }
            VStack(spacing: 5) {
                HStack(spacing: local ? 4 : 6) {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            SongNameDisplay(title: state.playing ? "Now playing" : "Selected song",
                                name: state.songDisplays?.current ?? selectedTimelineRegion?.name ?? state.songName,
                                bpm: state.songDisplays?.currentBPM, color: state.playing ? JarasTheme.green : JarasTheme.text)
                                .frame(width: max(0, (geometry.size.width - 1) * 0.75)).accessibilityLabel("Current song")
                            Rectangle().fill(JarasTheme.line).frame(width: 1)
                            TransportInformationMessage(message: state.loop ? "Loop Ativo" : state.footerInformation ?? "",
                                beatPhase: state.loop ? state.footerLoopBeatPhase : nil, steady: !state.loop)
                                .font(.jarasSystem(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: max(0, (geometry.size.width - 1) * 0.25), height: 25).clipped()
                                .accessibilityLabel("Information")
                        }
                    }.frame(height: 25).background(RemoteSurface.display).cornerRadius(5)
                    Text(verbatim: timeText).monospacedDigit().frame(width: local ? 72 : 82, height: 25)
                        .background(RemoteSurface.display).cornerRadius(5).accessibilityLabel("Tempo da agulha")
                }.font(.jarasSystem(size: 12, weight: .semibold)).lineLimit(1)
                GeometryReader { geometry in
                if local {
                    nativeTransportControls(width: geometry.size.width)
                } else {
                    remoteTransportControls(width: geometry.size.width)
                }
                }.frame(height: 32)
            }.frame(maxWidth: .infinity)
            VStack(spacing: 5) {
                HStack(spacing: 4) {
            if let openAdvanced {
                Button("Advanced", action: openAdvanced)
                    .buttonStyle(TransportButtonStyle(color: JarasTheme.panel, fontSize: 11, width: local ? 60 : 68, height: 28))
            }
            Button { confirmSave = true } label: {
                Label(state.saving ? "Salvando…" : state.pendingSave ? "Save" : "Salvo", systemImage: state.pendingSave ? "square.and.arrow.down" : "checkmark")
                    .font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: local ? 56 : 72, height: 28)
                    .foregroundStyle(state.pendingSave ? JarasTheme.green : JarasTheme.secondary)
                    .modifier(RemoteControlSurface(color: state.pendingSave ? JarasTheme.green.opacity(0.16) : nil))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.pendingSave ? JarasTheme.green.opacity(0.7) : JarasTheme.line))
            }.disabled(state.saving || (!local && !state.pendingSave))
                .modifier(RemoteProjectExportHold(export: exportProject))
            }
                HStack(spacing: 4) {
                Button {
                    guard let parent = drawerRegion?.id else { return }
                    toggleDrawer(parent)
                } label: {
                    Image(systemName: drawerExpanded ? "chevron.up" : "chevron.down")
                }.buttonStyle(TransportButtonStyle(color: JarasTheme.panel, fontSize: 13, width: local ? 32 : 72, height: 28))
                    .foregroundStyle(JarasTheme.green).disabled(drawerRegion == nil)
                    .opacity(drawerRegion == nil ? 0.45 : 1)
                    .accessibilityLabel(drawerExpanded ? "Fechar gaveta da região selecionada" : "Abrir gaveta da região selecionada")
                    .accessibilityValue(drawerExpanded ? "Expanded" : "Collapsed")
                    Button("Setlist") {
                        if prompterPanel == nil { toggleMainSetlist() } else { togglePrompterSetlist() }
                    }
                        .buttonStyle(TransportButtonStyle(color: mainSetlistVisible ? JarasTheme.green : Color(hex: 0xc44545), active: true, fontSize: 11, width: 62, height: 28))
                        .accessibilityValue(mainSetlistVisible ? "Shown" : "Hidden")
                }

            }
        }.padding(6).frame(height: 82, alignment: .top).background(RemoteSurface.panel)
    }
    private func remoteTransportControls(width: CGFloat) -> some View {
        let buttonWidth = max(30, (width - 288) / 4)
        return HStack(spacing: 4) {
            Button { action(state.playing || state.paused ? .stop : .play) } label: {
                Label { Text(verbatim: state.playing || state.paused ? JarasLocalization.string("Stop") : "Play") }
                    icon: { Image(systemName: state.playing || state.paused ? "stop.fill" : "play.fill") }
            }.buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: state.playing, fontSize: 12, width: buttonWidth, height: 28))
            Button { action(state.paused ? .play : .pause) } label: {
                Label(state.paused ? "Play" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
            }.buttonStyle(TransportButtonStyle( fontSize: 12, width: buttonWidth, height: 28)).disabled(!state.playing && !state.paused)
            Button("Sub Play") { action(state.subPlaying ? .subStop : .subPlay) }
                .buttonStyle(TransportButtonStyle(color: Color(hex: 0xffff00), active: true, activeForeground: .black, fontSize: 11, width: buttonWidth, height: 28)).disabled(!state.playing)
            Button { action(.toggleLoop) } label: { Label("Repeat", systemImage: "repeat") }
                .buttonStyle(TransportButtonStyle(color: state.loop ? JarasTheme.yellow : .red, active: state.loop, fontSize: 12, width: buttonWidth, height: 28))
                .modifier(JarasBlink(active: state.loop, interval: 0.55, lowOpacity: 0.45))
            bpmControl
            tunerControl
        }
    }
    private func nativeTransportControls(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(IpadTransportControl.visible(hidden: hiddenTransport)) { control in
                let controlWidth = IpadTransportControl.width(control, available: width, hidden: hiddenTransport)
                Group {
                    switch control {
                    case .play:
                        Button { action(state.playing || state.paused ? .stop : .play) } label: {
                            Label { Text(verbatim: state.playing || state.paused ? JarasLocalization.string("Stop") : "Play") }
                                icon: { Image(systemName: state.playing || state.paused ? "stop.fill" : "play.fill") }
                        }.buttonStyle(TransportButtonStyle(color: JarasTheme.transportPlay, active: state.playing, fontSize: 10, width: controlWidth, height: 28))
                    case .pause:
                        Button { action(state.paused ? .play : .pause) } label: {
                            Label(state.paused ? "Play" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
                        }.buttonStyle(TransportButtonStyle( fontSize: 10, width: controlWidth, height: 28)).disabled(!state.playing && !state.paused)
                    case .subPlay:
                        Button("Sub Play") { action(state.subPlaying ? .subStop : .subPlay) }
                            .buttonStyle(TransportButtonStyle(color: Color(hex: 0xffff00), active: true, activeForeground: .black, fontSize: 10, width: controlWidth, height: 28)).disabled(!state.playing)
                    case .repeatPlayback:
                        Button { action(.toggleLoop) } label: { Image(systemName: "repeat") }
                            .buttonStyle(TransportButtonStyle(color: state.loop ? JarasTheme.yellow : JarasTheme.liveOffRed, active: state.loop, inactiveOpacity: 1, fontSize: 12, width: controlWidth, height: 28))
                            .accessibilityLabel("Repeat").modifier(JarasBlink(active: state.loop, interval: 0.55, lowOpacity: 0.45))
                    case .record, .metronome:
                        if let localShow { IpadAudioTransportButtons(show: localShow, configureMetronome: openMetronome, only: control, controlWidth: controlWidth) }
                    case .bpm: nativeTransportStepper(width: controlWidth, pitch: false)
                    case .tuner: nativeTransportStepper(width: controlWidth, pitch: true)
                    }
                }.frame(width: controlWidth, height: 32)
            }
        }.frame(width: width, alignment: .leading)
    }
    private func nativeTransportStepper(width: Double, pitch: Bool) -> some View {
        let buttonWidth = min(28, max(18, width * 0.24))
        return HStack(spacing: 0) {
            Button { if pitch { stepPitch(-1) } else { stepTempo(-1) } } label: {
                Image(systemName: "minus").frame(width: buttonWidth, height: 32).contentShape(Rectangle())
            }.disabled(pitch ? state.pitchRegion == nil || (state.pitchSemitones ?? 0) <= -12 : state.bpm <= 60)
                .accessibilityLabel(pitch ? "Diminuir afinação" : "Diminuir BPM")
            VStack(spacing: 0) {
                Text(verbatim: pitch ? "Tuner" : "BPM").font(.jarasSystem(size: 8))
                Text(verbatim: pitch ? String(format: "%+dst", state.pitchSemitones ?? 0) : String(format: "%.0f", state.bpm))
                    .monospacedDigit().font(.jarasSystem(size: 12, weight: .semibold))
                    .foregroundStyle(pitch ? JarasTheme.green : state.tempoNeedsRender == true ? JarasTheme.yellow : JarasTheme.text)
            }.lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
            Button { if pitch { stepPitch(1) } else { stepTempo(1) } } label: {
                Image(systemName: "plus").frame(width: buttonWidth, height: 32).contentShape(Rectangle())
            }.disabled(pitch ? state.pitchRegion == nil || (state.pitchSemitones ?? 0) >= 12 : state.bpm >= 300)
                .accessibilityLabel(pitch ? "Aumentar afinação" : "Aumentar BPM")
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green)
            .frame(width: width, height: 32).background(RemoteSurface.display).cornerRadius(5)
            .disabled(pitch ? pitchStepPending : tempoStepPending)
    }
    private func topPrompterButton(_ panel: PrompterPanel, title: String, minimumHeight: CGFloat = 25) -> some View {
        Button { showPrompter(prompterPanel == panel ? nil : panel) } label: {
            Text(verbatim: title).font(.jarasSystem(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: minimumHeight)
                .modifier(RemoteControlSurface(radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(prompterPanel == panel ? JarasTheme.green : Color(hex: 0xff5555))
            .accessibilityLabel("Teleprompter \(panel.rawValue), controles superiores")
            .accessibilityValue(prompterPanel == panel ? "On" : "Off")
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
        guard !tempoStepPending else { return }
        let next = min(300, max(60, state.bpm + delta))
        guard next != state.bpm else { return }
        tempoStepPending = true
        action(.tempo, value: next)
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
    private var nativeRulerHeight: CGFloat {
        guard local, let song = localShow?.current else { return RemoteNativeGridMetrics.rulerAreaHeight }
        let preview = regionMovePreview.map { song.previewMovingRegion($0.id, to: $0.start) } ?? song
        return RemoteNativeGridMetrics.rulerAreaHeight(local: true, regionCount: RegionLanes(parts: preview.parts).count)
    }
    private var trackIconWidth: CGFloat {
        state.tracks.contains { $0.instrumentIcon.flatMap(TrackInstrumentIcon.init(rawValue:)) != nil } ? 40 : 0
    }
    private var trackMixer: some View {
        let hierarchy = DAWRemoteTrackHierarchy(state.tracks)
        let ancestors = Dictionary(uniqueKeysWithValues: visibleTracks.map { ($0.id, hierarchy.ancestors(of: $0.id)) })
        let folders = hierarchy.folders
        let phaseInvertedTracks = Set(localShow?.current?.tracks.filter { $0.phaseInverted == true }.map(\.id) ?? [])
        return VStack(spacing: local ? 0 : 1) {
            // Match the grid's region, marker, tempo and time lanes so both lists
            // start at the same screen Y and have identical scroll limits.
            if local {
                if let localShow {
                    IpadTimelineToolbar(show: localShow, addTrack: { addTrack?() }, editing: Binding(
                        get: { editingTracks }, set: { editingTracks = $0; if !$0 { trackReordering.cancel() } }))
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: nativeRulerHeight).padding(.trailing, trackIconWidth).background(RemoteSurface.panel)
                        .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1).allowsHitTesting(false) }
                }
            } else { masterStrip.padding(.trailing, trackIconWidth).background(RemoteSurface.panel) }
            HStack(spacing: 1) {
                RemoteTrackScrollRail(controller: trackScrolling).frame(width: 28)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { number, track in
                            let nextAncestors = number + 1 < visibleTracks.count ? ancestors[visibleTracks[number + 1].id] ?? [] : []
                            let guides = (ancestors[track.id] ?? []).map { nextAncestors.contains($0) }
                            RemoteNativeMixerRow(track: track, project: state.project, song: state.song, number: number + 1,
                                compact: DAWRemoteItemLayout.rowHeight(track, scale: trackScrolling.heightScale) < 70,
                                local: local, localShow: localShow, nativeContextMenu: local, showsInstrumentIcons: trackIconWidth > 0, nativePhaseInverted: phaseInvertedTracks.contains(track.id),
                                editing: local && editingTracks, selected: selectedTracks.contains(track.id),
                                selection: selectedTracks, groupGuides: guides, isGroup: folders.contains(track.id),
                                select: { toggleTrackSelection(track.id) }, selectionMenu: {
                                    trackScrolling.selectionScope = .tracks
                                    if !selectedTracks.contains(track.id) { selectedTracks = [track.id]; localShow?.setMixerTrackSelection(selectedTracks, anchor: track.id) }
                                    trackActionsOpen = true
                                }, openPatch: openPatch.map { callback in {
                                    if editingTracks { openSelectedPatch?(selectionTargets(track.id)) } else { callback(track.id) }
                                } }, openFX: openTrackFX.map { callback in {
                                    if editingTracks { openSelectedFX?(selectionTargets(track.id)) } else { callback(track.id) }
                                } }, addText: addTrackText.map { callback in { callback(track.id) } },
                                addMedia: addTrackMedia.map { callback in { callback(track.id) } }) { command, value in
                                action(command, target: track.id, value: value)
                            }.equatable().frame(height: DAWRemoteItemLayout.rowHeight(track, scale: trackScrolling.heightScale))
                                .modifier(IpadTrackReorderModifier(show: localShow, track: track.id,
                                    enabled: local && editingTracks, controller: trackReordering))
                                .modifier(nativeTrackMenu(track.id))
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: trackScrolling))
                    #endif
                }.background(RemoteSurface.background)
            }
        }
    }
    private func nativeTrackMenu(_ id: UUID) -> IpadTrackAudioContextMenu {
        let project = state.project, songID = state.song
        let song = localShow?.current
        let track = song?.tracks.first { $0.id == id }
        let ids = Set(selectionTargets(id))
        let standard = track?.kind == .standard
        let patchable = track.map { [.standard, .timecode, .video, .click].contains($0.kind) } ?? false
        let canGroup = standard && ids.count > 1 && ids.isSubset(of: groupableTracks)
        let folder = song?.tracks.contains { $0.parentTrackID == id } == true
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
            fx: guarded(standard ? { openSelectedFX?(selectionTargets(id)) } : nil),
            soundDesigner: guarded(track?.kind == .click ? openClickSound.map { callback in { callback(id) } } : nil),
            group: guarded(canGroup ? { groupTracks?(ids) } : nil),
            ungroup: guarded(folder ? { localShow?.ungroupTrack(id) } : nil),
            removeFromGroup: guarded(track?.parentTrackID != nil ? { localShow?.removeTrackFromGroup(id) } : nil),
            link: guarded(song?.linkableTracks(ids) != nil ? {
                guard let show = localShow, let song = show.current, let indices = song.linkableTracks(ids) else { return }
                let top = song.tracks[indices[0]]
                show.linkTracks(ids, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel,
                    color: top.color ?? JarasTheme.roleHex(top.role))
            } : nil),
            unlink: guarded(track?.stereoLink != nil ? { localShow?.unlinkTracks(id) } : nil),
            edit: guarded(openTrackDetails.map { callback in { callback(ids) } }),
            icon: guarded(openTrackIcon.map { callback in { callback(ids) } }),
            duplicate: guarded(standard && track?.role.rawValue != "vinhetas" ? { localShow?.duplicateTracks(ids) } : nil),
            remove: guarded({ requestNativeTrackDeletion(ids) }), count: ids.count)
    }
    private func toggleTrackSelection(_ id: UUID) {
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
    private func performRemoteMIDI(_ command: RemoteMIDIAction) {
        guard !local, !observer, !settingsOpen || RemoteMIDIActions.shared.learning == nil else { return }
        switch command {
        case .play: action(.play)
        case .stop: action(.stop)
        case .playStop: action(state.playing || state.paused ? .stop : .play)
        case .repeatPlayback: action(.toggleLoop)
        case .bypass: action(.toggleMultiLoopBypass)
        case .toggleParts:
            if UIDevice.current.userInterfaceIdiom == .phone { choosePhonePanel(phonePanel.togglingFooterParts()) }
            else { sectionsInList = true; sectionsOpen.toggle() }
        case .playlistUp, .playlistDown:
            let ids = (state.playlists ?? []).map(\.id)
            guard !ids.isEmpty else { return }
            let direction = command == .playlistDown ? 1 : -1
            let index = (remoteMIDIPlaylistID ?? state.selectedPlaylist).flatMap { ids.firstIndex(of: $0) }
            let next = index.map { ($0 + direction + ids.count) % ids.count } ?? (direction > 0 ? 0 : ids.count - 1)
            remoteMIDIPlaylistID = ids[next]; remoteMIDISetlistID = nil
            action(.selectPlaylist, target: ids[next])
        case .setlistUp, .setlistDown:
            let ids = setlistRowsCache.entries(in: state, expanded: [], query: "").compactMap { entry -> UUID? in
                if case .region(let row) = entry, !row.child { return row.region.id }; return nil
            }
            guard !ids.isEmpty else { return }
            let direction = command == .setlistDown ? 1 : -1
            let current = remoteMIDISetlistID ?? selectedSetlistEntries.first ?? state.focusedRegion
            let next = current.flatMap { ids.firstIndex(of: $0) }.map { min(ids.count - 1, max(0, $0 + direction)) } ?? (direction > 0 ? 0 : ids.count - 1)
            remoteMIDISetlistID = ids[next]; selectedSetlistEntries = [ids[next]]
            action(.selectRegion, target: ids[next])
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
    private func selectionTargets(_ clicked: UUID) -> [UUID] {
        let ids = selectedTracks.contains(clicked) ? selectedTracks : [clicked]
        return state.tracks.filter { ids.contains($0.id) }.map(\.id)
    }
    private func selectSetlistEntry(_ id: UUID) {
        trackScrolling.selectionScope = .setlist
        if local, hardwareModifiers.contains(.shift), let anchor = setlistSelectionAnchor {
            let ids = setlistRowsCache.entries(in: state, expanded: expandedRegions, query: search).compactMap { entry -> UUID? in
                if case .region(let row) = entry { return row.region.id }; return nil
            }
            if let first = ids.firstIndex(of: anchor), let last = ids.firstIndex(of: id) {
                selectedSetlistEntries = Set(ids[min(first, last)...max(first, last)])
            }
        } else if local, !hardwareModifiers.intersection([.command, .control]).isEmpty {
            if !selectedSetlistEntries.insert(id).inserted { selectedSetlistEntries.remove(id) }
            setlistSelectionAnchor = id
        } else {
            selectedSetlistEntries = [id]; setlistSelectionAnchor = id
            action(.selectRegion, target: id)
        }
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
                        .modifier(RemoteControlSurface(color: state.regionAuto == true ? JarasTheme.green : nil, radius: 4))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("AUTO").accessibilityValue(state.regionAuto == true ? "On" : "Off")
                    .contextMenu { if local { Button("Settings") { autoSettings = true } } }
                if let addBlock {
                    Button(action: addBlock) {
                        Text("Blocks").font(.jarasSystem(size: 9, weight: .bold))
                            .foregroundStyle(JarasTheme.text).frame(width: 40, height: 30)
                            .modifier(RemoteControlSurface(color: nil, radius: 4))
                            .contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle())
                        .disabled(state.selectedPlaylist == nil)
                        .opacity(state.selectedPlaylist == nil ? 0.35 : 1)
                }
                if let toggleRegionStop {
                    Button(action: toggleRegionStop) {
                        Text(verbatim: "STOP").font(.jarasSystem(size: 9, weight: .bold))
                            .foregroundStyle(stopsAtRegionEnd ? Color.red : JarasTheme.green)
                            .frame(width: local ? 40 : 38, height: local ? 30 : 26)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(stopsAtRegionEnd ? Color.red : JarasTheme.green))
                    }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("STOP")
                        .accessibilityValue(stopsAtRegionEnd ? "On" : "Off")
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
                            ForEach(setlistRowsCache.entries(in: state, expanded: expandedRegions, query: search)) { entry in
                                switch entry {
                                case .block(let block): RemoteSetlistBlockLabel(block: block, fontStyle: state.setlistFontStyle ?? 0).equatable()
                                case .region(let row):
                                let region = row.region
                                Button { selectSetlistEntry(region.id) } label: {
                                    setlistLabel(region.name, number: row.number, played: played.contains(region.sourceRegionId ?? region.id), selected: selectedSetlistEntries.contains(region.id) || region.id == state.focusedRegion,
                                        active: state.playing && region.id == state.setlistCurrentEntryId, queued: state.playing && region.id == (state.setlistQueuedEntryId),
                                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? (row.child ? 0xffeb3b : 0xffffff)),
                                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.setlistCurrentEntryId ? state.position : region.start)))),
                                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                                }.buttonStyle(RemoteFullAreaButtonStyle())
                                    .onDrag {
                                        guard local, state.selectedPlaylist != nil else { return NSItemProvider() }
                                        if !selectedSetlistEntries.contains(region.id) { selectedSetlistEntries = [region.id] }
                                        draggingSetlistEntries = selectedSetlistEntries
                                        return NSItemProvider(object: ("catlive-setlist:" + region.id.uuidString) as NSString)
                                    }
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.onAppear { setlistRowHeights[region.id] = geometry.size.height }
                                                .onChange(of: geometry.size.height) { setlistRowHeights[region.id] = $0 }
                                        }
                                    }
                                    .onDrop(of: [UTType.text], delegate: IpadSetlistDrop(show: localShow, target: region.id,
                                        project: state.project, playlist: state.selectedPlaylist, height: setlistRowHeights[region.id] ?? 38, moving: $draggingSetlistEntries))
                                    .contextMenu {
                                        Button("Edit song") {
                                            if local, let openRegionActions { openRegionActions(region.sourceRegionId ?? region.id) }
                                            else { editingEntry = .init(id: region.id, playlist: false, name: region.name, color: region.color) }
                                        }
                                        if let detectRegionBPM { Button("Detect BPM…") { detectRegionBPM(region.sourceRegionId ?? region.id) } }
                                        if !state.timelineRegions.contains(where: { $0.parentRegion == (region.sourceRegionId ?? region.id) }), let openRegionLoops { Button("Multiloops") { openRegionLoops(region.sourceRegionId ?? region.id) } }
                                        if let playlist = state.selectedPlaylist, region.parentRegion == nil, !selectedSetlistEntries.contains(region.id) || selectedSetlistEntries.count == 1 {
                                            Button("Duplicate region") { action(.duplicateRegion, target: region.id, playlist: playlist) }
                                        }
                                        if local { Button("Config Init") { configInitRegion = region.sourceRegionId ?? region.id } }
                                        if row.hasDrawer { Button(drawerExpanded ? "Close drawer" : "Open drawer") { toggleDrawer(region.id) } }
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
                }.onChange(of: expandedRegions) { expanded in
                    if let parent = drawerRegion?.id, expanded.contains(parent) {
                        withAnimation(.easeOut(duration: 0.16)) { scroll.scrollTo(parent, anchor: .top) }
                    }
                }
            }
            if UIDevice.current.userInterfaceIdiom != .phone { setlistControls }
        }.padding([.top, .leading, .trailing], 10).background(RemoteSurface.background)
    }
    private func editPlaylist(_ id: UUID) {
        guard let entry = state.playlists?.first(where: { $0.id == id }) else { return }
        playlistPickerOpen = false
        editingEntry = .init(id: id, playlist: true, name: entry.name, color: 0)
    }
    private func requestRemoval(_ type: DAWRemoteCommand.Action, id: UUID, playlist: UUID? = nil) {
        playlistPickerOpen = false
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

/// Playlist block headers keep their saved color, symbol and order; Observer
/// uses the same display without acquiring any playback controls.
private struct RemoteSetlistBlockLabel: View, Equatable {
    let block: DAWRemoteState.SetlistBlock
    let fontStyle: Int
    var scale = 1.0
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
                .font(fontStyle == 2 ? .system(size: 13 * scale, weight: .bold).italic() : .system(size: 13 * scale, weight: fontStyle == 0 ? .regular : .bold))
                .foregroundStyle(remoteColor(block.nameColor ?? 0x69ed91)).lineLimit(2)
        }.padding(.horizontal, 10).padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(remoteColor(block.color).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(remoteColor(block.color).opacity(0.5)))
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
            Rectangle().fill(active ? Color.red : queued ? (prepareOnly ? JarasTheme.green : .orange) : color).frame(width: 3)
            if let number { Text(String(format: "%02d", number)).font(.jarasSystem(size: 10 * scale, design: .monospaced)).foregroundStyle(JarasTheme.secondary) }
            Text(verbatim: title)
                .font(fontStyle == 2 ? .system(size: 13 * scale, weight: .bold).italic() : .system(size: 13 * scale, weight: fontStyle == 0 ? .regular : .bold))
                .foregroundStyle(nameColor).strikethrough(played, color: nameColor).lineLimit(2)
            Spacer(minLength: 0)
            if let duration { Text(String(format: "%dm %02ds", duration / 60, duration % 60)).font(.jarasSystem(size: 10 * scale, weight: .medium, design: .monospaced)).foregroundStyle(JarasTheme.text) }
            if active { Image(systemName: "play.fill").foregroundStyle(JarasTheme.green) }
            if queued { Image(systemName: "arrow.right").foregroundStyle(JarasTheme.yellow) }
        }.padding(.horizontal, 8).padding(.vertical, 7 * scale).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 38 * scale)
            .background {
                if active {
                    LinearGradient(colors: [Color(hex: 0x8b2026), Color(hex: 0x4c171c)], startPoint: .top, endPoint: .bottom)
                } else if queued {
                    LinearGradient(colors: prepareOnly ? [Color(hex: 0x19633a), Color(hex: 0x123b27)] : [Color(hex: 0xa84b13), Color(hex: 0x572808)], startPoint: .top, endPoint: .bottom)
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
    case setlistUp, setlistDown, partsUp, partsDown, toggleParts, play, stop, playStop, repeatPlayback, bypass, playlistUp, playlistDown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setlistUp: return "Setlist Up"
        case .setlistDown: return "Setlist Down"
        case .partsUp: return "Parts Up"
        case .partsDown: return "Parts Down"
        case .toggleParts: return "Parts"
        case .play: return "Play"
        case .stop: return "Stop"
        case .playStop: return "Play / Stop"
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
    struct Event { let id = UUID(); let action: RemoteMIDIAction }
    @Published private(set) var bindings: [String: RemoteMIDIBinding] = [:]
    @Published var learning: RemoteMIDIAction?
    @Published private(set) var event: Event?
    @Published private(set) var error = ""
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var sources: [MIDIEndpointRef: (Int32, String)] = [:]
    private var pressed = Set<String>()
    private init() {
        if let data = UserDefaults.standard.data(forKey: "catlive.remote.midiActions"),
           let value = try? JSONDecoder().decode([String: RemoteMIDIBinding].self, from: data) { bindings = value }
    }
    func clear(_ action: RemoteMIDIAction) { bindings.removeValue(forKey: action.rawValue); persist() }
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
        sources.removeAll(); pressed.removeAll(); learning = nil; event = nil
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }
    private func refresh() {
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
    }
    private func receive(_ endpoint: MIDIEndpointRef, _ status: UInt8, _ number: UInt8, _ value: UInt8) {
        guard let source = sources[endpoint] else { return }
        let kind = status & 0xf0
        guard [0x80, 0x90, 0xb0, 0xc0].contains(kind) else { return }
        let channel = status & 15, normalized: UInt8 = kind == 0x80 ? 0x90 : kind
        let key = "\(source.0):\(channel):\(normalized):\(number)"
        if kind == 0x80 || (kind != 0xc0 && value == 0) { pressed.remove(key); return }
        guard kind == 0xc0 || pressed.insert(key).inserted else { return }
        let input = RemoteMIDIBinding(device: source.0, channel: channel, status: normalized, number: number,
            label: "\(source.1) · CH \(channel + 1) · \(kind == 0xb0 ? "CC" : kind == 0xc0 ? "PC" : "Note") \(number)")
        if let learning {
            bindings = bindings.filter { !$0.value.matches(input) }; bindings[learning.rawValue] = input
            self.learning = nil; persist(); return
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
                if !midi.error.isEmpty { Text(verbatim: midi.error).foregroundStyle(.red) }
                ForEach(RemoteMIDIAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(LocalizedStringKey(action.title)).font(.jarasSubheadline)
                        Text(verbatim: midi.bindings[action.rawValue]?.label ?? "—").font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                        HStack {
                            Button(midi.learning == action ? "Cancel" : "Learn MIDI") { midi.learning = midi.learning == action ? nil : action }
                            Spacer()
                            Button("Clear") { midi.clear(action) }.disabled(midi.bindings[action.rawValue] == nil)
                        }.buttonStyle(.bordered)
                    }.padding(10).background(JarasTheme.display, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(.vertical, 8)
        }.onDisappear { midi.learning = nil }
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

/// The center grid renders native clip geometry from the Mac state.
private enum RemoteNativeGridMetrics {
    static let regionHeight: CGFloat = 24
    static let markerHeight: CGFloat = 20
    static let timeHeight: CGFloat = 28
    static let rulerAreaHeight = regionHeight + markerHeight + timeHeight + 2
    static func regionHeight(local: Bool) -> CGFloat { local ? 16 : regionHeight }
    static func markerHeight(local: Bool) -> CGFloat { local ? 16 : markerHeight }
    static func timeHeight(local: Bool) -> CGFloat { local ? 16 : timeHeight }
    static func regionAreaHeight(local: Bool, regionCount: Int = 1) -> CGFloat {
        regionHeight(local: local) * CGFloat(local ? max(1, regionCount) : 1)
    }
    static func rulerAreaHeight(local: Bool, regionCount: Int = 1) -> CGFloat {
        regionAreaHeight(local: local, regionCount: regionCount) + markerHeight(local: local)
            + timeHeight(local: local) + (local ? 16 : 2)
    }
    static func nativeDividers(regionCount: Int) -> [CGFloat] {
        let count = max(1, regionCount), regions = CGFloat(count) * 16
        return (0...count).map { CGFloat($0) * 16 + 0.5 }
            + [regions + 16.5, regions + 32.5, regions + 48 - 0.5]
    }
}
private struct RemoteNativeTimeline: View {
    @Environment(\.displayScale) private var displayScale
    let state: DAWRemoteState
    let tracks: [DAWRemoteState.Track]
    @ObservedObject var scrolling: RemoteTrackScrollController
    let region: DAWRemoteState.Region?
    let position: Double
    var local = false
    var localShow: ShowController? = nil
    var timelineFocus: IpadTimelineFocus? = nil
    var editorEnabled = true
    @Binding var regionDrag: IpadRegionMovePreview?
    var openRegionActions: ((UUID) -> Void)? = nil
    @State private var selectedRegionID: UUID?
    var openItemMenu: ((UUID) -> Void)? = nil
    var openSelectedItemMenu: ((UUID, Set<UUID>) -> Void)? = nil
    var openItemFX: ((UUID) -> Void)? = nil
    @State private var viewport = IpadTimelineViewport()
    @State private var rulerDrag = IpadTimelineRulerDrag()
    @ObservedObject private var timeSelection = TimelineAreaSelection.shared
    @State private var rulerPointerViewport: IpadTimelineViewport?
    @State private var rulerSelectionAnchor: Double?
    @State private var rulerSelectionEnd: Double?
    @State private var selectionResizeFixedEdge: Double?
    @State private var gestureControl = IpadTimelineGestureControl()
    @State private var followsPlayback = true
    @State private var pointerStart: (project: UUID, song: Song, item: UUID?, time: Double, point: CGPoint, selection: TimelinePointerSelection)?
    @State private var pointerDragged = false
    @State private var drawingMIDI = false
    @State private var selectionRectangle: CGRect?
    var openMarkerEditor: ((TimelineMarker) -> Void)? = nil
    var regionCommand: ((UUID, String) -> Void)? = nil
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    let preview: (Double) -> Void
    let seek: (Double) -> Void
    private var start: Double { local ? viewport.start : region?.start ?? 0 }
    private var end: Double { local ? viewport.end : region?.end ?? start }
    private var span: Double { local ? viewport.span : max(0.001, end - start) }
    private var zoomCursor: Double {
        if let transport = localShow?.snapshot.transport {
            if followsPlayback && transport.subPlay.playing { return transport.subPlay.position }
            if followsPlayback && transport.playing { return transport.position }
            return transport.editPosition ?? transport.position
        }
        if followsPlayback && state.subPlaying { return state.subPlayPosition ?? position }
        if followsPlayback && state.playing { return position }
        return state.editPosition ?? position
    }
    private var presentationSong: Song? {
        guard let song = localShow?.current else { return nil }
        var preview = regionDrag.map { song.previewMovingRegion($0.id, to: $0.start) } ?? song
        if let move = scrolling.itemMove {
            preview = preview.movingItems(move.items, anchor: move.anchor, start: move.start, track: move.track) ?? preview
        }
        return scrolling.itemMix?.applying(to: preview) ?? preview
    }
    private var regionLaneCount: Int { RegionLanes(parts: presentationSong?.parts ?? []).count }
    private var regionAreaHeight: CGFloat { RemoteNativeGridMetrics.regionAreaHeight(local: local, regionCount: regionLaneCount) }
    private var rulerHeight: CGFloat { RemoteNativeGridMetrics.rulerAreaHeight(local: local, regionCount: regionLaneCount) }
    private var gridTop: CGFloat { rulerHeight + (local ? 0 : 1) }
    private func visibleMarkers(song: Song?) -> [TimelineMarker] {
        let markers = song?.markers ?? (state.markers ?? []).map {
            TimelineMarker(id: $0.id, name: $0.name, position: $0.position, color: $0.color,
                unifiedRegionID: $0.unifiedRegionID, sourceRegionID: $0.sourceRegionID, section: $0.section)
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
    private func pauseFollowing() { gestureControl.cancelMotion(); followsPlayback = false }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let song = presentationSong
            let markers = visibleMarkers(song: song)
            let marks = gridMarks(width: width, preview: regionDrag == nil ? nil : song)
            VStack(spacing: local ? 0 : 1) {
                regionLane(width: width, song: song)
                markerLane(width: width, markers: markers, song: song)
                if local { tempoLane(width: width, song: song) }
                ruler(width: width, marks: marks, song: song)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(tracks) { track in
                            timelineRow(track, width: width, marks: marks, nativeSong: song).frame(height: DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale))
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1 / displayScale).allowsHitTesting(false)
                    }
                    .frame(minHeight: max(0, geometry.size.height - gridTop), alignment: .top)
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
                                reset: scrolling.pointerReset, accepts: { point in
                                    return true
                                }, wantsAutoScroll: { point in
                                    guard pointerDragged else { return false }
                                    if point.x < 20 || point.x > width - 20 { return true }
                                    guard let scroll = scrolling.gridScrollView else { return false }
                                    let y = point.y - scroll.contentOffset.y
                                    return y < 24 || y > scroll.bounds.height - 24
                                }, event: { handlePointer($0, width: width) }, wheel: { delta, modifiers in
                                    handleWheel(delta, modifiers: modifiers, width: width)
                                })
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: scrolling, isGrid: true, gridTap: { fraction in
                        guard local || (!state.playing && region != nil) else { return }
                        let time = start + fraction * span
                        if local, let song {
                            seek(TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
                                enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
                                includeHiddenDivisions: true, includeItemEdges: true))
                        } else { seek(time) }
                    }))
                    #endif
                }.background {
                    if state.gridLines != false {
                        Canvas { context, size in
                            var primary = Path(), secondary = Path()
                            for mark in marks {
                                let x = gridX(mark.time, width: size.width)
                                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                                if mark.primary { primary.addPath(line) } else { secondary.addPath(line) }
                            }
                            context.stroke(primary, with: .color(remoteColor(state.gridPrimaryColor ?? UInt32(TimelineAppearanceDefaults.primaryGrid))), lineWidth: 1 / displayScale)
                            context.stroke(secondary, with: .color(remoteColor(state.gridSecondaryColor ?? UInt32(TimelineAppearanceDefaults.secondaryGrid))), lineWidth: 1 / displayScale)
                        }.allowsHitTesting(false)
                    }
                }
            }.overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let selectionTop = rulerHeight - RemoteNativeGridMetrics.timeHeight(local: local)
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
                        if local, let song {
                            let lanes = RegionLanes(parts: song.parts)
                            for region in song.parts where region.parentRegionID == nil {
                                var borders = Path()
                                let headerBottom = CGFloat((lanes.lanes[region.id] ?? 0) + 1) * RemoteNativeGridMetrics.regionHeight(local: local)
                                for time in [region.startTime, region.endTime] where time >= start && time <= end {
                                    let x = (time - start) / span * size.width
                                    borders.move(to: CGPoint(x: x, y: headerBottom))
                                    borders.addLine(to: CGPoint(x: x, y: size.height))
                                }
                                context.stroke(borders, with: .color(remoteColor(region.color ?? 0x705264)), lineWidth: 1)
                            }
                        }
                        if local, let song {
                            var tempoStems = Path()
                            for marker in song.markers ?? [] where marker.isTempo && marker.position >= start && marker.position <= end {
                                let x = (marker.position - start) / span * size.width
                                tempoStems.move(to: CGPoint(x: x, y: regionAreaHeight + 32))
                                tempoStems.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            context.stroke(tempoStems, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1 / displayScale, dash: [2, 3]))
                        }
                        for marker in markers {
                            let x = (marker.position - start) / span * size.width
                            var stem = Path()
                            stem.move(to: CGPoint(x: x, y: regionAreaHeight + RemoteNativeGridMetrics.markerHeight(local: local) + (local ? 0 : 1)))
                            stem.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(stem, with: .color(remoteColor(marker.color).opacity(marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)), lineWidth: 1)
                        }
                    }
                    if local {
                        Canvas { context, size in
                            var boundaries = Path()
                            for y in RemoteNativeGridMetrics.nativeDividers(regionCount: regionLaneCount) {
                                boundaries.move(to: CGPoint(x: 0, y: y))
                                boundaries.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            context.stroke(boundaries, with: .color(JarasTheme.line), lineWidth: 1)
                        }.frame(height: rulerHeight)
                    }
                    // Needles stay above coincident marker stems, as on the Mac.
                    cursor(width: width)
                        .frame(width: width, height: max(0, geometry.size.height - gridTop), alignment: .topLeading)
                        .offset(y: gridTop)
                }.clipped().allowsHitTesting(false)
            }
            .frame(width: width, height: max(0, geometry.size.height), alignment: .topLeading)
            .clipped()
        }.clipped().background(remoteColor(state.gridBackgroundColor ?? UInt32(TimelineAppearanceDefaults.background)))
            .background {
                if local {
                    IpadTimelineGestureProbe(control: gestureControl, pan: { translation, width in
                        followsPlayback = false; viewport.pan(pixels: translation, width: width)
                    }, zoom: { scale, anchor in
                        viewport.zoom(factor: scale, centeredOn: zoomCursor)
                    })
                }
            }
            .onAppear {
                scrolling.pointerEditing = local
                if local { viewport.reset(duration: state.duration); viewport.center(on: zoomCursor) }
            }
            .onDisappear { scrolling.pointerEditing = false; cancelPointer(); cancelItemMix() }
            .onChange(of: scrolling.pointerReset) { _ in cancelPointer(); cancelItemMix() }
            .onChange(of: state.project) { _ in cancelPointer(); cancelItemMix() }
            .onChange(of: localShow?.timelineMovementLocked) { locked in if locked == true { cancelPointer() } }
            .onChange(of: timelineFocus) { request in
                if local, let request { gestureControl.cancelMotion(); followsPlayback = true; viewport.center(on: request.position) }
            }
            .onChange(of: state.song) { _ in
                cancelPointer(); cancelItemMix(); scrolling.pointerReset = UUID()
                if local { gestureControl.cancelMotion(); viewport.reset(duration: state.duration); followsPlayback = true; viewport.center(on: timelineFocus?.position ?? zoomCursor) }
            }
            .onChange(of: region?.id) { _ in
                // Stopped selection is driven by the explicit focus request, not
                // by a region/state refresh that may still contain the old cursor.
                if local && (state.playing || state.subPlaying) {
                    followsPlayback = true; viewport.center(on: state.subPlaying ? state.subPlayPosition ?? position : position)
                }
            }
            .onChange(of: state.playing) { playing in
                if local && playing { followsPlayback = true; viewport.follow(position) }
            }
            .onChange(of: position) { time in
                if local && followsPlayback && state.playing && !state.subPlaying { viewport.follow(time) }
            }
            .onChange(of: state.subPlayPosition) { time in
                if local && followsPlayback && state.subPlaying, let time { viewport.follow(time) }
            }
            .accessibilityAction(named: Text("Zoom in")) { if local { viewport.zoom(factor: 1.5, anchor: 0.5) } }
            .accessibilityAction(named: Text("Zoom out")) { if local { viewport.zoom(factor: 1 / 1.5, anchor: 0.5) } }
    }
    private func pointerItems(width: CGFloat) -> [(id: UUID, track: UUID, rect: CGRect)] {
        var rows: [(UUID, UUID, CGRect)] = []
        var y: CGFloat = 0
        let song = presentationSong
        for track in tracks {
            let geometry = IpadNativeItemGeometry(track: local ? song?.tracks.first(where: { $0.id == track.id }) : nil,
                remoteTrack: track, scale: scrolling.heightScale)
            for clip in track.clips where clip.start < end && clip.start + clip.duration > start {
                let left = max(start, clip.start), right = min(end, clip.start + clip.duration)
                rows.append((clip.id, track.id, CGRect(x: (left - start) / span * width,
                    y: y + geometry.offset(clip.id, fallbackLane: clip.lane ?? 0), width: (right - left) / span * width, height: geometry.height(clip.id))))
            }
            y += DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale) + 1
        }
        return rows
    }
    private func pointerTrack(at y: CGFloat) -> UUID? {
        var top: CGFloat = 0
        for track in tracks {
            let height = DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale)
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
        let hits = pointerItems(width: width)
        let time = max(0, start + Double(event.position.x / max(1, width)) * span)
        if event.phase == .began {
            pauseFollowing(); scrolling.selectionScope = .grid
            let item = hits.first { $0.rect.contains(event.position) }?.id
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
        if pointerDragged, event.secondary {
            let firstX = (initial.time - start) / span * width
            let rectangle = CGRect(x: min(firstX, event.position.x), y: min(initial.point.y, event.position.y),
                width: abs(firstX - event.position.x), height: abs(initial.point.y - event.position.y))
            selectionRectangle = rectangle
            var ids = Set(hits.filter { $0.rect.intersects(rectangle) }.map(\.id))
            if !event.modifiers.intersection([.command, .control, .shift]).isEmpty { ids.formUnion(initial.selection.items) }
            if scrolling.itemSelection.items != ids { scrolling.itemSelection.replace(ids) }
        } else if pointerDragged, drawingMIDI, !show.timelineMovementLocked {
            selectionRectangle = CGRect(x: min((initial.time - start) / span * width, event.position.x), y: initial.point.y - 10,
                width: abs((initial.time - time) / span * width), height: 20)
        } else if pointerDragged, let anchor = initial.item, !show.timelineMovementLocked,
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
                includeItemEdges: true, excludingItems: ids)
            if initial.song.movingItems(ids, anchor: anchor, start: snapped, track: target) != nil {
                let move = IpadNativeItemMove(items: ids, anchor: anchor, start: snapped, track: target)
                if scrolling.itemMove != move { scrolling.itemMove = move }
            } else { scrolling.itemMove = nil }
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
                if drawingMIDI, pointerDragged, !show.timelineMovementLocked, let track = pointerTrack(at: initial.point.y) {
                    let enabled = TimelineSnapPreference.enabled && !event.modifiers.contains(.shift)
                    let from = TimelineTempo.snap(min(initial.time, time), song: song, pixelsPerSecond: width / span,
                        enabled: enabled, includeHiddenDivisions: true, includeItemEdges: true)
                    let to = TimelineTempo.snap(max(initial.time, time), song: song, pixelsPerSecond: width / span,
                        enabled: enabled, includeHiddenDivisions: true, includeItemEdges: true)
                    if to > from, let created = show.addMIDIItem(track: track, start: from, duration: to - from) {
                        scrolling.itemSelection.replace([created])
                    }
                }
                if !pointerDragged {
                    if let track = pointerTrack(at: initial.point.y) {
                        show.setMixerTrackSelection([track], anchor: track)
                    }
                    let snapped = TimelineTempo.snap(time, song: song, pixelsPerSecond: width / span,
                        enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift),
                        includeHiddenDivisions: true, includeItemEdges: true)
                    seek(snapped)
                }
            }
            cancelPointer()
        } else if pointerDragged {
            if event.position.x < 20 { viewport.pan(pixels: 8, width: width) }
            else if event.position.x > width - 20 { viewport.pan(pixels: -8, width: width) }
            if let scroll = scrolling.gridScrollView {
                let visibleY = event.position.y - scroll.contentOffset.y
                if visibleY < 24 { scrolling.pointerScroll(-8) }
                else if visibleY > scroll.bounds.height - 24 { scrolling.pointerScroll(8) }
            }
        }
    }
    private func gridMarks(width: CGFloat, preview: Song? = nil) -> [TimelineTimeRuler.Tick] {
        var sections = (state.gridTempo ?? []).map {
            TimelineTempoSection(start: $0.start, end: $0.end, bpm: $0.bpm, beats: $0.beats, unit: $0.unit, timebase: .free)
        }
        if let preview { sections = preview.tempoSections(until: max(end, preview.duration)) }
        if local, let last = sections.last, end > last.end {
            sections[sections.count - 1] = TimelineTempoSection(start: last.start, end: end, bpm: last.bpm, beats: last.beats, unit: last.unit, timebase: last.timebase)
        }
        return TimelineTimeRuler.ticks(in: sections, from: start, to: end,
                                       pixelsPerSecond: width / span, divisions: state.gridDivisions ?? 4)
    }
    private func gridX(_ time: Double, width: CGFloat) -> CGFloat {
        floor((time - start) / span * width * displayScale) / displayScale + 0.5 / displayScale
    }
    private func handleWheel(_ delta: CGPoint, modifiers: HardwareKeyboardModifiers, width: CGFloat) {
        if modifiers.contains(.command) || modifiers.contains(.control) {
            scrolling.resizeTracks(exp(Double(delta.y) * 0.006)); scrolling.finishResizingTracks()
        } else if modifiers.contains(.shift) || abs(delta.x) > abs(delta.y) {
            pauseFollowing(); viewport.pan(pixels: Double(delta.x == 0 ? delta.y : delta.x), width: width)
        } else { viewport.zoom(factor: exp(Double(delta.y) * 0.009), centeredOn: zoomCursor) }
    }
    private func ruler(width: CGFloat, marks: [TimelineTimeRuler.Tick], song: Song?) -> some View {
        ZStack(alignment: .leading) {
            (local ? JarasTheme.panel : JarasTheme.display)
            Canvas { context, size in
                for mark in marks {
                    let x = gridX(mark.time, width: size.width)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: local ? 1 : mark.primary ? 20 : 24))
                    tick.addLine(to: CGPoint(x: x, y: local ? (mark.primary ? 7 : 4) : size.height))
                    context.stroke(tick, with: .color(TimelineStaticText.rulerColor), lineWidth: 1 / displayScale)
                    if !mark.label.isEmpty {
                        TimelineStaticText.label(mark.label, style: .barNumber, displayScale: displayScale)?
                            .draw(at: CGPoint(x: x + 3, y: local ? 2 : 5), context: &context)
                    }
                }

            }
        }.frame(height: RemoteNativeGridMetrics.timeHeight(local: local)).contentShape(Rectangle())
            .overlay(IpadRulerTouchInput(enabled: local ? editorEnabled : !state.playing && region != nil,
                drag: { translation, location, ended, cancelled in
                    if cancelled { rulerDrag.reset(); selectionResizeFixedEdge = nil; return }
                    if local {
                        if resizeRulerSelection(origin: location - translation, x: location, width: width, ended: ended) { return }
                        pauseFollowing(); rulerDrag.update(translation: translation, width: width, viewport: &viewport)
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
                }, tap: { x in seek(start + min(1, max(0, x / width)) * span) }))
            .background {
                if local {
                    IpadTimelinePointerProbe(enabled: editorEnabled, capturesPointer: true,
                        reset: scrolling.pointerReset, accepts: { _ in true }, wantsAutoScroll: { _ in false },
                        event: { rulerPointer($0, width: width) }, wheel: { handleWheel($0, modifiers: $1, width: width) })
                }
            }
            .onChange(of: scrolling.pointerReset) { _ in rulerDrag.reset() }
            .accessibilityLabel(local ? "Time ruler: drag to scroll" : "Régua de tempo: arraste com o transporte parado")
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
            pixelsPerSecond: width / span, enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift), includeItemEdges: true)
        timeSelection.update(song: song.id, from: fixed, to: time)
        show.updateActiveLoopArea()
        if ended { selectionResizeFixedEdge = nil }
        return true
    }
    private func rulerPointer(_ event: IpadTimelinePointerEvent, width: CGFloat) {
        guard local, editorEnabled, let show = localShow, let song = show.current else { return }
        switch event.phase {
        case .began:
            pauseFollowing(); rulerPointerViewport = viewport
            if event.secondary {
                rulerSelectionAnchor = TimelineTempo.snap(max(0, viewport.start + Double(event.origin.x / max(1, width)) * viewport.span), song: song,
                    pixelsPerSecond: width / viewport.span, enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift), includeItemEdges: true)
                rulerSelectionEnd = nil
            }
        case .moved, .ended:
            guard let original = rulerPointerViewport else { return }
            if event.secondary {
                func time(_ x: CGFloat) -> Double {
                    TimelineTempo.snap(max(0, original.start + Double(x / max(1, width)) * original.span), song: song,
                        pixelsPerSecond: width / original.span,
                        enabled: TimelineSnapPreference.enabled && !event.modifiers.contains(.shift), includeItemEdges: true)
                }
                rulerSelectionEnd = time(event.position.x)
                timeSelection.update(song: song.id, from: time(event.origin.x), to: time(event.position.x))
                show.updateActiveLoopArea()
            } else if resizeRulerSelection(origin: event.origin.x, x: event.position.x, width: width, ended: event.phase == .ended) {
                if event.phase == .ended { rulerPointerViewport = nil }
                return
            } else if event.distance >= 3 {
                var moved = original
                moved.pan(pixels: Double(event.position.x - event.origin.x), width: width)
                viewport = moved
            } else if event.phase == .ended {
                seek(max(0, original.start + Double(event.position.x / max(1, width)) * original.span))
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
                    let text = TimelineStaticText.label(song.markerLabel(marker), style: .regionIdentifier, displayScale: displayScale)
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
                    markerTarget(marker, width: (TimelineStaticText.label(song.markerLabel(marker), style: .regionIdentifier, displayScale: displayScale)?.width ?? 24) + 6, height: 16)
                        .offset(x: gridX(marker.position, width: width))
                }
            }
        }.frame(height: 16).clipped().contentShape(Rectangle())
            .contextMenu { if local { Button("Tempo marker") { createMarker(tempo: true) } } }
            .onTapGesture { pauseFollowing(); selectedRegionID = nil }.accessibilityLabel("BPM / Compasso")
    }
    private func regionDestination(_ id: UUID, original: Double, translation: Double, width: Double) -> Double {
        guard let song = localShow?.current else { return original }
        return TimelineTempo.snap(original + translation / max(1, width) * span, song: song,
            pixelsPerSecond: width / span, cursor: localShow?.snapshot.transport.editPosition ?? position,
            enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
            excludingRegion: id, includeItemEdges: true)
    }
    @ViewBuilder private func nativeRegionMenu(_ part: Part, song: Song) -> some View {

                            Button("Edit song") { pauseFollowing(); openRegionActions?(part.id) }
                            Button("Detect BPM…") { regionCommand?(part.id, "bpm") }
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
                        .foregroundStyle(remoteColor(state.timelineRegions.first(where: { $0.id == part.id })?.nameColor ?? 0xffffff)).padding(.horizontal, 4)
                        .frame(width: max(0, (right - left) / span * width), height: RemoteNativeGridMetrics.regionHeight(local: local), alignment: .leading)
                        .background(remoteColor(part.color ?? 0x705264)).clipped()
                        .overlay(IpadRegionHeaderGesture(singleTap: { pauseFollowing(); selectedRegionID = part.id }, doubleTap: {
                            pauseFollowing(); openRegionActions?(part.id)
                        }, moved: { translation in
                            // Use original document coordinates throughout the gesture.
                            guard localShow?.timelineMovementLocked == false,
                                  let original = localShow?.current?.parts.first(where: { $0.id == part.id }) else { return }
                            pauseFollowing()
                            regionDrag = IpadRegionMovePreview(id: part.id, start: regionDestination(part.id, original: original.startTime, translation: translation, width: width))
                        }, ended: { cancelled in
                            let move = regionDrag; regionDrag = nil
                            if !cancelled, let move, let show = localShow, show.snapshot.project.id == state.project {
                                show.moveRegion(move.id, start: move.start)
                            }
                        }))
                        .overlay(Rectangle().stroke(selectedRegionID == part.id ? JarasTheme.green : .clear, lineWidth: 2).allowsHitTesting(false))
                        .contextMenu { nativeRegionMenu(part, song: song) }
                        .offset(x: (left - start) / span * width, y: CGFloat(lane) * RemoteNativeGridMetrics.regionHeight(local: local))
    }
    private func regionLane(width: CGFloat, song: Song?) -> some View {
        ZStack(alignment: .topLeading) {
            (local ? JarasTheme.panel : JarasTheme.display).contentShape(Rectangle()).onTapGesture { if local { pauseFollowing(); selectedRegionID = nil } }
            if local, let song {
                let lanes = RegionLanes(parts: song.parts)
                ForEach(song.parts.filter { $0.parentRegionID == nil && $0.startTime < end && $0.endTime > start }) { part in
                    nativeRegionHeader(part, song: song, width: width, lane: lanes.lanes[part.id] ?? 0)

                }
            } else if let region {
                Text(verbatim: region.name).font(.jarasSystem(size: 10, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(remoteColor(region.nameColor ?? 0xffffff)).padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(remoteColor(region.color).opacity(0.6))
            }
        }.frame(height: regionAreaHeight).clipped().accessibilityLabel("Faixa da região " + (region?.name ?? ""))
    }
    private func markerLane(width: CGFloat, markers: [TimelineMarker], song: Song?) -> some View {
        let regionEnds = song?.markerRegionEnds ?? [:]
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
                    markerTarget(marker, width: flags[marker.id] ?? 12, height: RemoteNativeGridMetrics.markerHeight(local: local))
                        .offset(x: gridX(marker.position, width: width))
                }
            }
        }.frame(height: RemoteNativeGridMetrics.markerHeight(local: local)).clipped().contentShape(Rectangle())
            .contextMenu {
                if local {
                    Button("Editar marcador") { createMarker() }
                    Button("Section marker") { createMarker(section: true) }
                    Button("Tempo marker") { createMarker(tempo: true) }
                }
            }
            .onTapGesture { if local { pauseFollowing() } }.accessibilityLabel("Marcadores da música")
    }
    private func markerTarget(_ marker: TimelineMarker, width: CGFloat, height: CGFloat) -> some View {
        Color.clear.frame(width: max(1, width), height: height).contentShape(Rectangle())
            .onTapGesture(count: 2) { pauseFollowing(); openMarkerEditor?(marker) }
            .contextMenu {
                Button("Editar marcador") { pauseFollowing(); openMarkerEditor?(marker) }
                Button("Delete", role: .destructive) { localShow?.deleteManualMarker(marker.id) }
            }.accessibilityLabel(marker.name)
    }
    private func createMarker(section: Bool = false, tempo: Bool = false) {
        guard let show = localShow, let song = show.current else { return }
        let time = show.snapshot.transport.editPosition ?? position
        guard show.canCreateMarker(at: time, tempo: tempo), !section || show.canCreateSectionMarker(at: time) else { return }
        let settings = song.tempoSection(at: time)
        openMarkerEditor?(TimelineMarker(id: UUID(), name: tempo ? "TEMPO" : "", position: time, color: 0x51ef93,
            tempoBPM: tempo ? settings.bpm : nil, tempoBeats: tempo ? settings.beats : nil,
            tempoUnit: tempo ? settings.unit : nil, tempoTimebase: tempo ? .global : nil, section: section ? true : nil))
    }
    private func cursor(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            needle(state.playing ? state.editPosition : position,
                   color: state.editCursorColor ?? UInt32(TimelineAppearanceDefaults.editCursor), width: width)
            if state.playing {
                needle(localShow?.snapshot.transport.position ?? position, color: state.playCursorColor ?? UInt32(TimelineAppearanceDefaults.playCursor), width: width, glowing: true)
            }
            if state.subPlaying {
                needle(localShow?.snapshot.transport.subPlay.position ?? state.subPlayPosition ?? state.sectionPlayback?.secondaryPosition, color: state.subPlayCursorColor ?? UInt32(TimelineAppearanceDefaults.subPlayCursor), width: width, glowing: true)
            }
        }.frame(width: width, alignment: .leading).frame(maxHeight: .infinity)
            .clipped().allowsHitTesting(false)
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
                Path { head in
                    head.move(to: .zero)
                    head.addLine(to: CGPoint(x: 14, y: 0))
                    head.addLine(to: CGPoint(x: 7, y: 9))
                    head.closeSubpath()
                }.fill(displayColor).frame(width: 14, height: 9)
                    .shadow(color: displayColor.opacity(glowing ? 0.9 : 0.4), radius: glowing ? 4 : 2)
                    .offset(x: x + (glowing ? 1.5 : 1) - 7)
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
    private func timelineRow(_ track: DAWRemoteState.Track, width: CGFloat, marks: [TimelineTimeRuler.Tick], nativeSong: Song?) -> some View {
        RemoteTimelineTrackRow(track: track, width: width, marks: marks, displayScale: displayScale,
            start: start, end: end, span: span, hasRegion: local || region != nil, heightScale: scrolling.heightScale,
            backgroundColor: state.gridBackgroundColor ?? UInt32(TimelineAppearanceDefaults.background),
            primaryColor: state.gridPrimaryColor ?? UInt32(TimelineAppearanceDefaults.primaryGrid),
            secondaryColor: state.gridSecondaryColor ?? UInt32(TimelineAppearanceDefaults.secondaryGrid),
            gridLines: state.gridLines != false, project: state.project, song: state.song,
            scrolling: scrolling, local: local, nativeTrack: nativeSong?.tracks.first(where: { $0.id == track.id }), nativeSong: nativeSong,
            nativeDirectory: local ? DAWRemoteHostBridge.documents?.currentURL?.deletingLastPathComponent() : nil,
            nativeRevision: localShow?.projectRevision ?? 0, mixPreview: scrolling.itemMix, selectedItem: scrolling.selectedItem,
            selectedItems: scrolling.itemSelection.items, movementLocked: localShow?.timelineMovementLocked ?? false,
            resizeEnabled: editorEnabled && localShow?.canControl() == true, interactionID: scrolling.pointerReset,
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
            },
            openItemMenu: { id in
                let ids = scrolling.itemSelection.items.contains(id) ? scrolling.itemSelection.items : [id]
                if let openSelectedItemMenu { openSelectedItemMenu(id, ids) } else { openItemMenu?(id) }
            }, openItemFX: openItemFX,
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
    }

}

/// Use the desktop overlap components for item drawing and pointer hit testing.
/// Unrelated overlaps elsewhere in the track do not shrink isolated items.
private struct IpadNativeItemGeometry {
    let rowHeight: Double
    let fallbackLaneHeight: Double
    let lanes: TrackLanes?
    init(track: Track?, remoteTrack: DAWRemoteState.Track, scale: Double) {
        rowHeight = DAWRemoteItemLayout.rowHeight(remoteTrack, scale: scale)
        fallbackLaneHeight = DAWRemoteItemLayout.laneHeight(remoteTrack, scale: scale)
        lanes = track.map { source in
            var layout = TrackLanes(track: source)
            if (remoteTrack.laneCount ?? 1) > layout.count {
                layout.reserveRecordingLanes(count: remoteTrack.laneCount ?? 1)
            }
            return layout
        }
    }
    func height(_ id: UUID) -> Double {
        lanes.map { rowHeight / Double(max(1, $0.localCount(for: id))) } ?? fallbackLaneHeight
    }
    func offset(_ id: UUID, fallbackLane: Int = 0) -> Double {
        Double(lanes?.localLane(for: id) ?? fallbackLane) * height(id)
    }
}

/// Clip drawing is independent of the playhead. The needle can advance without
/// rebuilding waveform paths or item touch targets in every visible row.
private struct RemoteTimelineTrackRow: View, Equatable {
    let track: DAWRemoteState.Track
    let width: CGFloat
    let marks: [TimelineTimeRuler.Tick]
    let displayScale: CGFloat
    let start: Double
    let end: Double
    let span: Double
    let hasRegion: Bool
    let heightScale: Double
    let backgroundColor: UInt32
    let primaryColor: UInt32
    let secondaryColor: UInt32
    let gridLines: Bool
    let project: UUID
    let song: UUID?
    let scrolling: RemoteTrackScrollController
    var local = false
    var nativeTrack: Track? = nil
    var nativeSong: Song? = nil
    var nativeDirectory: URL? = nil
    var nativeRevision: UInt64 = 0
    var mixPreview: IpadNativeItemMix?
    var selectedItem: UUID? = nil
    var selectedItems: Set<UUID> = []
    var movementLocked = false
    var resizeEnabled = false
    let interactionID: UUID
    var cursorPosition: () -> Double? = { nil }
    var selectTrack: (() -> Void)? = nil
    var itemFade: ((UUID, Bool, Double, Bool) -> Void)? = nil
    var beginResize: (() -> Void)? = nil
    var resizeItem: ((UUID, Double, Double) -> Void)? = nil
    @State private var resizing: IpadItemResizePreview?
    @State private var fadePreview: (id: UUID, fadeIn: Bool, value: Double)?
    var openItemMenu: ((UUID) -> Void)? = nil
    var openItemFX: ((UUID) -> Void)? = nil
    var itemMix: ((UUID, IpadItemMixParameter, Double, Bool, Bool) -> Void)? = nil
    var itemPhase: ((UUID) -> Void)? = nil
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.song == rhs.song && lhs.scrolling === rhs.scrolling &&
            lhs.track.id == rhs.track.id && lhs.track.name == rhs.track.name && lhs.track.color == rhs.track.color &&
            lhs.track.nameColor == rhs.track.nameColor && lhs.track.clips == rhs.track.clips &&
            lhs.track.silenced == rhs.track.silenced &&
            lhs.track.laneCount == rhs.track.laneCount && lhs.track.heightScale == rhs.track.heightScale && lhs.track.emphasized == rhs.track.emphasized &&
            lhs.width == rhs.width && lhs.displayScale == rhs.displayScale && lhs.heightScale == rhs.heightScale &&
            lhs.selectedItem == rhs.selectedItem && lhs.selectedItems == rhs.selectedItems && lhs.movementLocked == rhs.movementLocked && lhs.resizeEnabled == rhs.resizeEnabled && lhs.interactionID == rhs.interactionID && lhs.start == rhs.start && lhs.end == rhs.end && lhs.span == rhs.span && lhs.nativeRevision == rhs.nativeRevision && lhs.mixPreview == rhs.mixPreview && lhs.nativeDirectory == rhs.nativeDirectory && lhs.hasRegion == rhs.hasRegion && lhs.local == rhs.local &&
            lhs.backgroundColor == rhs.backgroundColor && lhs.primaryColor == rhs.primaryColor &&
            lhs.secondaryColor == rhs.secondaryColor && lhs.gridLines == rhs.gridLines &&
            lhs.marks.elementsEqual(rhs.marks) { $0.time == $1.time && $0.primary == $1.primary }
    }
    private func gridX(_ time: Double, width: CGFloat) -> CGFloat {
        floor((time - start) / span * width * displayScale) / displayScale + 0.5 / displayScale
    }
    private var previewTrack: Track? {
        guard var result = nativeTrack, let resizing,
              let index = result.clips.firstIndex(where: { $0.id == resizing.original.id }) else { return nativeTrack }
        result.clips[index] = resizing.candidate
        return result
    }
    private var previewClips: [DAWRemoteState.Clip] {
        guard let resizing else { return track.clips }
        return track.clips.map { source in
            guard source.id == resizing.original.id else { return source }
            var result = source; result.start = resizing.candidate.startTime; result.duration = resizing.candidate.duration
            return result
        }
    }
    private func resize(_ id: UUID, left: Bool, translation: Double, finished: Bool, cancelled: Bool) {
        if cancelled { resizing = nil; return }
        guard local, resizeEnabled, !movementLocked, let nativeSong, let nativeTrack,
              let clip = nativeTrack.clips.first(where: { $0.id == id }) else { resizing = nil; return }
        if let preview = resizing, preview.original != clip { resizing = nil; return }
        if resizing == nil { beginResize?(); resizing = IpadItemResizePreview(original: clip, candidate: clip, secondsPerPoint: span / max(1, width)) }
        guard var preview = resizing else { return }
        let original = preview.original
        let edge = left ? original.startTime : original.startTime + original.duration
        let target = TimelineTempo.snap(max(0, edge + translation * preview.secondsPerPoint), song: nativeSong,
                                       pixelsPerSecond: 1 / preview.secondsPerPoint, cursor: cursorPosition(),
                                       enabled: TimelineSnapPreference.enabled && !scrolling.modifiers.contains(.shift),
                                       includeItemEdges: true, excludingItems: [id])
        let lower = left ? min(target, original.startTime + original.duration - 0.01) : original.startTime
        let upper = left ? original.startTime + original.duration : max(original.startTime + 0.01, target)
        let unchanged = lower == original.startTime && upper == original.startTime + original.duration
        let candidate = unchanged ? original : original.resized(start: lower, end: upper)
        if nativeTrack.canPlaceItem(start: candidate.startTime, duration: candidate.duration, excluding: id) {
            preview.candidate = candidate; resizing = preview
        }
        if finished {
            resizing = nil
            if preview.candidate != original { resizeItem?(id, preview.candidate.startTime, preview.candidate.startTime + preview.candidate.duration) }
        }
    }
    private func gridItem(_ clip: DAWRemoteState.Clip, width itemWidth: Double, height itemHeight: Double, left: Double, right: Double) -> RemoteNativeGridItem {
        return
                RemoteNativeGridItem(clip: clip, width: itemWidth, height: itemHeight, color: track.color, nameColor: track.nameColor ?? 0xffffff,
                    scrolling: scrolling,
                    sourceFraction: (left - clip.start) / max(0.001, clip.duration),
                    visibleFraction: (right - left) / max(0.001, clip.duration),
                    mute: { control(.clipMute, clip.id, 0) },
                    setGain: { control(.clipGain, clip.id, $0) }, local: local, trackSilenced: track.silenced == true,
                    nativeClip: previewTrack?.clips.first(where: { $0.id == clip.id }), nativeKind: nativeTrack?.kind,
                    itemMix: { parameter, value, finished, cancelled in itemMix?(clip.id, parameter, value, finished, cancelled) },
                    itemPhase: { itemPhase?(clip.id) },
                    nativeWaveform: nativeDirectory != nil && nativeTrack?.clips.contains(where: { $0.id == clip.id && !$0.isImage && ($0.audioFile ?? nativeTrack?.audioFile) != nil }) == true,
                    select: local ? { scrolling.selectedItem = clip.id; selectTrack?() } : nil,
                    openMenu: openItemMenu.map { callback in { callback(clip.id) } }, openFX: openItemFX.map { callback in { callback(clip.id) } })
    }
    var body: some View {
        let itemGeometry = IpadNativeItemGeometry(track: local ? previewTrack : nil, remoteTrack: track, scale: heightScale)
        ZStack(alignment: .topLeading) {
            remoteColor(backgroundColor).opacity(local ? 0 : 1)
            if local && track.emphasized == true {
                remoteColor(track.color).opacity(0.16).saturation(track.silenced == true ? 0 : 1).allowsHitTesting(false)
            }
            Canvas { context, size in
                if gridLines && !local {
                    var primary = Path(), secondary = Path()
                    for mark in marks {
                        let x = gridX(mark.time, width: size.width)
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                        if mark.primary { primary.addPath(line) } else { secondary.addPath(line) }
                    }
                    context.stroke(primary, with: .color(remoteColor(primaryColor)), lineWidth: 1 / displayScale)
                    context.stroke(secondary, with: .color(remoteColor(secondaryColor).opacity(0.85)), lineWidth: 1 / displayScale)
                }
            }.allowsHitTesting(false)
            ForEach(previewClips.filter { hasRegion && $0.start < end && $0.start + $0.duration > start && (!local || RecordingLaneLayout.shared.items[$0.id] == nil) }) { clip in
                let left = max(start, clip.start), right = min(end, clip.start + clip.duration)
                let itemWidth = max(0, (right - left) / span * width)
                gridItem(clip, width: itemWidth, height: itemGeometry.height(clip.id), left: left, right: right)
                    .equatable()
                    .overlay {
                        if local && selectedItems.contains(clip.id) {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 1.5).allowsHitTesting(false)
                        }
                    }
                    .frame(width: itemWidth, height: itemGeometry.height(clip.id))
                    .offset(x: (left - start) / span * width, y: itemGeometry.offset(clip.id, fallbackLane: clip.lane ?? 0))
            }
            if local, let nativeTrack = previewTrack, let nativeSong, let nativeDirectory {
                IpadNativeWaveformRow(track: nativeTrack, song: nativeSong, remoteTrack: track, directory: nativeDirectory,
                    start: start, end: end, span: span, width: width, heightScale: heightScale, revision: nativeRevision)
                    .allowsHitTesting(false)
            }
            if local, let nativeTrack {
                let rowHeight = DAWRemoteItemLayout.rowHeight(track, scale: heightScale)
                let scale = width / max(0.001, span)
                RecordingGridOverlay(visibleRect: CGRect(x: start * scale, y: 0, width: width, height: rowHeight),
                    tracks: [nativeTrack], offsets: [0], heights: [rowHeight], rulerHeight: 0,
                    scale: scale, alignsToViewport: true).allowsHitTesting(false)
            }
            if local, resizeEnabled, let nativeTrack {
                ForEach(nativeTrack.clips.filter { selectedItems.contains($0.id) && $0.startTime < end && $0.startTime + $0.duration > start }) { item in
                    ForEach([true, false], id: \.self) { fadeIn in
                        let duration = (fadeIn ? item.fadeIn : item.fadeOut) ?? 0
                        let displayedFade = fadePreview?.id == item.id && fadePreview?.fadeIn == fadeIn ? fadePreview!.value : duration
                        let edge = item.startTime + (fadeIn ? displayedFade : item.duration - displayedFade)
                        if edge >= start && edge <= end {
                            IpadItemResizeHandle(left: fadeIn, interactionID: interactionID, changed: { delta, finished, cancelled in
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
                    if (edge >= start && edge <= end) || resizing?.original.id == clip.id {
                        IpadItemResizeHandle(left: left, interactionID: interactionID, changed: { delta, finished, cancelled in
                            resize(clip.id, left: left, translation: delta, finished: finished, cancelled: cancelled)
                        }).id(clip.id).frame(width: 28, height: max(0, laneHeight - GridSelectionItem.headerHeight - 2))
                            .offset(x: min(width - 28, max(0, (edge - start) / span * width - 14)),
                                    y: itemGeometry.offset(clip.id, fallbackLane: clip.lane ?? 0) + GridSelectionItem.headerHeight + 1)
                    }
                }
            }
        }.frame(width: width, height: DAWRemoteItemLayout.rowHeight(track, scale: heightScale), alignment: .topLeading)
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
    let track: Track
    let song: Song
    let remoteTrack: DAWRemoteState.Track
    let directory: URL
    let start: Double
    let end: Double
    let span: Double
    let width: CGFloat
    let heightScale: Double
    let revision: UInt64
    @ObservedObject private var cache = TimelineAudioWaveform.shared
    @State private var owner = TimelineWaveformVertexOwner()
    @State private var sources = IpadWaveformRowSources()
    var body: some View {
        let scale = width / max(0.001, span)
        let itemGeometry = IpadNativeItemGeometry(track: track, remoteTrack: remoteTrack, scale: heightScale)
        let viewport = CGRect(x: start * scale, y: 0, width: width, height: DAWRemoteItemLayout.rowHeight(remoteTrack, scale: heightScale))
        let lanes = Dictionary(uniqueKeysWithValues: remoteTrack.clips.map { ($0.id, $0.lane ?? 0) })
        let rgb = TrackNameContrast.components(track.color ?? 0x705264, emphasized: false)
        let luminance = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
        let gray: Float = luminance > 0.68 ? 0.52 : luminance > 0.42 ? 0.9 : 0.8
        let items = sources.entries(track: track, song: song, directory: directory, revision: revision)
            .filter { $0.clip.startTime < end && $0.clip.startTime + $0.clip.duration > start }
            .map { source in
                TimelineWaveformItem(clip: source.clip, fragments: source.fragments, url: source.url,
                    rect: CGRect(x: source.clip.startTime * scale, y: itemGeometry.offset(source.clip.id, fallbackLane: lanes[source.clip.id] ?? 0),
                                 width: source.clip.duration * scale, height: itemGeometry.height(source.clip.id)),
                    gray: remoteTrack.silenced == true || source.clip.muted == true ? 0.78 : gray, sourcePath: source.path)
            }
        MetalWaveformView(frame: TimelineMetalWaveformFrameBuilder.make(items: items, viewport: viewport,
            scale: scale, cache: cache, owner: owner, contentRevision: Int(truncatingIfNeeded: revision)))
            .frame(width: width, height: viewport.height).clipped()
            .allowsHitTesting(false)
    }
}
private final class IpadWaveformRowSources {
    struct Entry { let clip: AudioClip; let fragments: [AudioClip]; let url: URL; let path: String }
    private var revision: UInt64?
    private var directory: URL?
    private var track: Track?
    private var markers: [TimelineMarker]?
    private var retained: [Entry] = []
    func entries(track: Track, song: Song, directory: URL, revision: UInt64) -> [Entry] {
        if self.revision == revision, self.directory == directory, self.track == track, markers == song.markers { return retained }
        self.revision = revision; self.directory = directory; self.track = track; markers = song.markers
        let sections = song.tempoSections(until: song.duration)
        retained = track.clips.compactMap { clip in
            guard !clip.isImage, let file = clip.audioFile ?? track.audioFile else { return nil }
            let url = directory.appendingPathComponent(file.path, isDirectory: false)
            return Entry(clip: clip, fragments: song.tempoAudioSegments(clip, sections: sections), url: url, path: url.path)
        }
        return retained
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
    let setGain: (Double) -> Void
    var local = false
    var trackSilenced = false
    var nativeClip: AudioClip? = nil
    var nativeKind: TrackKind? = nil
    var itemMix: ((IpadItemMixParameter, Double, Bool, Bool) -> Void)? = nil
    var itemPhase: (() -> Void)? = nil
    var nativeWaveform = false
    var select: (() -> Void)? = nil
    var openMenu: (() -> Void)? = nil
    var openFX: (() -> Void)? = nil
    @Environment(\.isEnabled) private var controlsEnabled
    @State private var editorOpen = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.clip == rhs.clip && lhs.width == rhs.width && lhs.height == rhs.height && lhs.color == rhs.color &&
            lhs.nameColor == rhs.nameColor && lhs.scrolling === rhs.scrolling &&
            lhs.sourceFraction == rhs.sourceFraction && lhs.visibleFraction == rhs.visibleFraction &&
            lhs.local == rhs.local && lhs.trackSilenced == rhs.trackSilenced && lhs.nativeClip == rhs.nativeClip && lhs.nativeKind == rhs.nativeKind && lhs.nativeWaveform == rhs.nativeWaveform && (lhs.openMenu != nil) == (rhs.openMenu != nil) &&
            (lhs.openFX != nil) == (rhs.openFX != nil)
    }
    var body: some View {
        let headerHeight = min(local ? GridSelectionItem.headerHeight : 28 * GridSelectionItem.headerScale, height)
        let silenced = trackSilenced || clip.muted == true
        let itemColor = silenced ? Color(white: 0.55) : remoteColor(color)
        VStack(spacing: 0) {
            if local, let nativeClip {
                IpadItemHeader(clip: nativeClip, editable: nativeKind == .standard || nativeClip.isProjectionMedia,
                    textEditable: nativeKind?.isText == true && !nativeClip.isProjectionMedia,
                    interactionID: scrolling.pointerReset,
                    mix: { itemMix?($0, $1, $2, $3) }, mute: mute, phase: { itemPhase?() },
                    fx: { openFX?() }, menu: { openMenu?() })
                    .frame(width: width, height: headerHeight)
            } else {
            HStack(spacing: 4) {
                Button(action: mute) { Text(verbatim: "M").font(.jarasSystem(size: local ? GridSelectionItem.headerFontSize : 11 * GridSelectionItem.headerScale, weight: .bold)).frame(width: (local ? 17 : 28) * GridSelectionItem.headerScale, height: headerHeight) }
                    .buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(clip.muted == true ? Color.black : Color.white)
                    .background(clip.muted == true ? Color.red : Color.black.opacity(0.28)).cornerRadius(2)
                    .accessibilityLabel("Mute do item " + clip.name)
                if let openFX {
                    Button("FX", action: openFX).font(.jarasSystem(size: 10, weight: .semibold))
                        .frame(width: local ? 20 * GridSelectionItem.headerScale : 32, height: headerHeight).contentShape(Rectangle()).buttonStyle(.plain)
                }
                Text(verbatim: clip.name).font(.jarasSystem(size: local ? GridSelectionItem.headerFontSize : 10 * GridSelectionItem.headerScale, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(remoteColor(nameColor)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 3).frame(width: width, height: headerHeight, alignment: .leading).clipped()
                .background(Color.black.opacity(0.16))
            }
            Canvas { context, size in
                guard !nativeWaveform else { return }
                var wave = Path()
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
                        let phase = fraction * 300 + Double(seed)
                        amplitude = 0.12 + 0.78 * abs(sin(phase * 0.37) * cos(phase * 0.13))
                    }
                    let height = size.height * amplitude
                    wave.addRect(CGRect(x: CGFloat(index) * 3, y: (size.height - height) / 2, width: 1.5, height: height))
                }
                context.fill(wave, with: .color(silenced ? .gray : remoteColor(nameColor).opacity(0.75)))
            }.frame(height: max(0, height - headerHeight)).allowsHitTesting(false)
        }.frame(width: width, height: height, alignment: .topLeading).clipped()
            .background(LinearGradient(colors: [itemColor.opacity(silenced ? 0.55 : 1), itemColor.opacity(silenced ? 0.25 : 0.78)], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(itemColor.opacity(0.75), lineWidth: 0.6).allowsHitTesting(false))
            .modifier(RemoteItemMenuGesture(local: local, item: clip.id, selection: scrolling.itemSelection.items,
                openVolume: { editorOpen = true }))
            .background {
                if local {
                    IpadItemMenuAnchor(id: clip.id).allowsHitTesting(false)
                    RemoteGridItemHoldProbe(controller: scrolling, tap: select, hold: { openMenu?() })
                }
            }
            .popover(isPresented: $editorOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                RemoteNativeItemEditor(clip: clip, color: color, setGain: setGain, mute: mute, close: { editorOpen = false })
                    .preferredColorScheme(.dark)
            }
            .onChange(of: controlsEnabled) { if !$0 { editorOpen = false } }
            .accessibilityLabel(clip.name).accessibilityAction(named: "Editar item") { if let openMenu { openMenu() } else { editorOpen = true } }
    }
}
private struct RemoteItemMenuGesture: ViewModifier {
    let local: Bool
    let item: UUID
    let selection: Set<UUID>
    let openVolume: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if local {
            content.contextMenu {
                ForEach(IpadItemContextMenu.commands(item, selection)) { command in
                    Button(command.title, role: command.destructive ? .destructive : nil, action: command.action)
                }
            }
        } else {
            content.contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 8, perform: openVolume)
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
                Text(verbatim: (clip.gain == 0 ? "−∞" : String(format: "%+.1f", decibels)) + " dB")
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
/// Native rectangular fader with desktop travel and a local thumb during touch.
/// Observe mixer changes directly: master pan is a local engine control, not a
/// track command sent through the remote protocol (which requires a track ID).
@MainActor private struct IpadMasterPanFader: View {
    let show: ShowController
    @ObservedObject private var updates: ShowProjectPresentation
    init(show: ShowController) {
        self.show = show
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }
    var body: some View {
        let pan = show.snapshot.project.masterPan ?? 0
        VStack(spacing: 0) {
            RemoteNativeSlider(value: pan, range: -1...1, height: 16) { show.send(.pan, value: $0) }
                .accessibilityLabel("Master pan")
            Text(verbatim: abs(pan) < 0.005 ? "Center" : String(format: "%@-%d%%", pan < 0 ? "L" : "R", Int((abs(pan) * 100).rounded())))
                .font(.jarasSystem(size: 7, weight: .medium, design: .monospaced)).lineLimit(1)
                .foregroundStyle(JarasTheme.text).frame(height: 9)
        }
    }
}

private struct RemoteNativeSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 28
    var linked = false
    let change: (Double) -> Void
    @State private var editing = false
    @State private var draft = 0.0
    @State private var pending = false
    @State private var commitID = UUID()
    @State private var lastSentAt = 0.0
    private var displayed: Double { editing || pending ? draft : value }
    private func commit(_ next: Double) {
        draft = next; editing = false
        pending = abs(value - next) > 0.000001
        commitID = UUID()
        change(next)
    }
    private func update(_ x: CGFloat, width: CGFloat) {
        let fraction = min(1, max(0, Double((x - 6) / max(1, width - 12))))
        draft = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        if !editing { lastSentAt = 0 }
        editing = true
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSentAt >= 0.05 { lastSentAt = now; change(draft) }
    }
    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, (displayed - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(linked ? JarasTheme.yellow : Color.white.opacity(0.22)).frame(height: 6).padding(.horizontal, 6)
                RemoteSurface.fill(linked ? JarasTheme.green : Color(white: 0.88))
                    .clipShape(RoundedRectangle(cornerRadius: 2)).frame(width: 12, height: 18)
                    .overlay(Rectangle().fill(Color(white: 0.33)).frame(width: 1, height: 12))
                    .offset(x: CGFloat(fraction) * max(1, geometry.size.width - 12))
            }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .overlay(RemoteSliderTouchInput(
                    changed: { update($0, width: geometry.size.width) },
                    ended: { update($0, width: geometry.size.width); commit(draft) },
                    reset: { commit(0) }))
        }.frame(height: height)
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
private struct RemoteSliderTouchInput: UIViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let reset: () -> Void
    func makeUIView(context: Context) -> RemoteSliderTouchView { RemoteSliderTouchView() }
    func updateUIView(_ view: RemoteSliderTouchView, context: Context) {
        view.changed = changed; view.ended = ended; view.reset = reset
        view.isUserInteractionEnabled = enabled
    }
}
private final class RemoteSliderTouchView: UIView, UIGestureRecognizerDelegate {
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat) -> Void)?
    var reset: (() -> Void)?
    private var lastDragX: CGFloat?
    override init(frame: CGRect) {
        super.init(frame: frame)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(pan); addGestureRecognizer(doubleTap); addGestureRecognizer(tap)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func resetTapped() { reset?() }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) { ended?(gesture.location(in: self).x) }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            lastDragX = gesture.location(in: self).x; changed?(lastDragX!)
        case .ended:
            lastDragX = nil; ended?(gesture.location(in: self).x)
        case .cancelled, .failed:
            if let x = lastDragX { lastDragX = nil; ended?(x) }
        default: break
        }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) >= abs(velocity.y)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.jarasSystem(size: 10, weight: .semibold))
            .foregroundStyle(activeColor == nil ? Color.white : Color.black)
            .frame(width: width, height: height)
            .modifier(RemoteControlSurface(color: activeColor?.opacity(configuration.isPressed ? 0.75 : 1), radius: 3))
            .frame(width: width + touchPadding, height: max(28, height)).contentShape(Rectangle())
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
/// grip and folder gutter. Compact rows have no pan, so they can retain Patch
/// and FX at a narrower width than the full-height row.
private struct RemoteNativeTrackControlLayout {
    let patch: Bool
    let fx: Bool
    let pan: Bool
    init(width: CGFloat, compact: Bool, editing: Bool, hierarchyWidth: CGFloat,
         isGroup: Bool, hasVolume: Bool, hasRecord: Bool, hasPatch: Bool, hasFX: Bool) {
        let available = width - hierarchyWidth - (editing ? 36 : 6) - (hasVolume ? 19 : 6)
            - (compact || !hasVolume ? 70 : 0) - (isGroup ? 14 : 0)
        // M/S are always present. Each extra control contributes its real
        // touch width and one 3-point gap.
        let base: CGFloat = 32 + 3 + 32 + (hasRecord ? 28 + 3 : 0)
        let panWidth: CGFloat = compact ? 0 : 52.5 + 3
        let fxWidth: CGFloat = hasFX ? 32 + 3 : 0
        pan = !compact && available >= base + panWidth
        fx = hasFX && available >= base + panWidth + fxWidth
        patch = hasPatch && available >= base + panWidth + fxWidth + 50 + 3
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
    @State private var selected: Set<UUID> = []
    var body: some View {
        VStack(spacing: 0) {
            IpadModalHeader(title: adding ? "Add regions" : "Create playlist", close: close)
            if !adding { TextField("Name", text: $name).textFieldStyle(.roundedBorder).padding(16) }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(regions) { region in
                        Button {
                            if !selected.insert(region.id).inserted { selected.remove(region.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(region.id) ? "checkmark.square.fill" : "square").foregroundStyle(JarasTheme.green)
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
                    if create(name, regions.filter { selected.contains($0.id) }.map(\.id)) { close() }
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
            Text(colored ? "Edit song" : "Rename playlist").font(.jarasTitle3.bold())
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
private struct RemoteProjectExportHold: ViewModifier {
    let export: (() -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if let export {
            content.buttonStyle(IpadTapHoldButtonStyle(hold: export))
                .accessibilityAction(named: Text("Export CatLive project"), export)
        } else { content.buttonStyle(RemoteFullAreaButtonStyle()) }
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
                .foregroundStyle(nativePalette && (decibels ?? -.infinity) >= 0 ? Color.red : remoteColor(nameColor))
                .padding(.horizontal, 2)
                .background(nativePalette && (decibels ?? -.infinity) >= 0 ? Color.black : Color.clear)
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
    var duplicate: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    var count = 1
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
        append("Add Stems", addAudio); append("Create group", group); append("Ungroup", ungroup)
        append("Remove from group", removeFromGroup); append("Link tracks", link); append("Unlink tracks", unlink)
        append("Editar pista", edit); append("Ícone da pista", icon)
        append(count > 1 ? "Duplicate tracks" : "Duplicate track", duplicate)
        append(count > 1 ? "Delete tracks" : "Delete track", remove, destructive: true)
        return actions
    }
}

private struct IpadTrackMenuAction {
    let title: String
    let destructive: Bool
    let action: () -> Void
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
            backgroundColor = .clear; isAccessibilityElement = false
            addInteraction(UIContextMenuInteraction(delegate: self))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard point(inside: location, with: nil), !actions.isEmpty else { return nil }
            let actions = actions
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                var items: [UIMenuElement] = []
                for action in actions {
                    let item = UIAction(title: action.title, attributes: action.destructive ? .destructive : []) { _ in action.action() }
                    if action.destructive { items.append(UIMenu(options: .displayInline, children: [item])) }
                    else { items.append(item) }
                }
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

private struct RemoteNativeMixerRow: View, Equatable {
    let track: DAWRemoteState.Track
    let project: UUID
    let song: UUID?
    let number: Int
    var compact = false
    var local = false
    var localShow: ShowController? = nil
    var nativeContextMenu = false
    var showsInstrumentIcons = false
    var nativePhaseInverted = false
    var editing = false
    var selected = false
    var selection: Set<UUID> = []
    var groupGuides: [Bool] = []
    var isGroup = false
    var select: (() -> Void)? = nil
    var selectionMenu: (() -> Void)? = nil
    var openPatch: (() -> Void)? = nil
    var openFX: (() -> Void)? = nil
    var addText: (() -> Void)? = nil
    var addMedia: (() -> Void)? = nil
    let send: (DAWRemoteCommand.Action, Double) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.song == rhs.song && lhs.number == rhs.number &&
            lhs.compact == rhs.compact && lhs.local == rhs.local && lhs.nativeContextMenu == rhs.nativeContextMenu && lhs.nativePhaseInverted == rhs.nativePhaseInverted &&
            lhs.editing == rhs.editing && lhs.selected == rhs.selected && lhs.showsInstrumentIcons == rhs.showsInstrumentIcons &&
            lhs.selection == rhs.selection && lhs.groupGuides == rhs.groupGuides && lhs.isGroup == rhs.isGroup && lhs.track.hasSameMixerControls(as: rhs.track)
    }
    var body: some View {
        GeometryReader { geometry in
        let iconWidth: CGFloat = showsInstrumentIcons ? 40 : 0
        let nativeTrack = localShow?.current?.tracks.first { $0.id == track.id }
        let kind = nativeTrack?.kind ?? .standard
        let vinhetas = nativeTrack?.role.rawValue == "vinhetas"
        let hasVolume = !local || !kind.isText
        let hierarchyWidth: CGFloat = !groupGuides.isEmpty ? 16 + CGFloat(min(4, groupGuides.count - 1)) * 8 : 0
        let controlLayout = RemoteNativeTrackControlLayout(width: max(0, geometry.size.width - iconWidth), compact: compact,
            editing: editing, hierarchyWidth: hierarchyWidth, isGroup: isGroup, hasVolume: hasVolume,
            hasRecord: localShow != nil && kind == .standard, hasPatch: openPatch != nil, hasFX: openFX != nil)
        let patchVisible = !local || controlLayout.patch
        let fxVisible = !local || controlLayout.fx
        // Compact rows keep only the button strip beside the name. Removing
        // the whole pan stack also removes its width and inter-control gap.
        let panVisible = !vinhetas && !compact && (!local || controlLayout.pan)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if compact || !hasVolume {
                    if isGroup, let localShow, let nativeTrack {
                        TrackGroupButton(show: localShow, project: project, track: track.id, parent: nativeTrack.parentTrackID)
                            .disabled(!editing)
                            .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                    }
                    Text(String(format: "%02d  %@", number, track.name)).font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(remoteColor(track.nameColor ?? 0xffffff)).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !compact && hasVolume { Spacer(minLength: 0) }
                HStack(spacing: 3) {
                if !local || kind == .standard {

                if patchVisible, let openPatch { Button("Patch", action: openPatch).buttonStyle(RemoteNativeTrackButtonStyle(activeColor: nil, width: 44)) }
                if fxVisible, let openFX { Button("FX", action: openFX).buttonStyle(RemoteNativeTrackButtonStyle(activeColor: nil)) }
                if let localShow, let row = localShow.current?.tracks.first(where: { $0.id == track.id }), row.kind == .standard {
                    TrackRecordButton(show: localShow, track: row).frame(width: 28, height: 28)
                }
                if panVisible {
                    VStack(spacing: 0) {
                        RemoteNativeSlider(value: track.pan, range: -1...1, height: 16) { send(.pan, $0) }
                            .accessibilityLabel("Pan " + track.name)
                        Text(verbatim: abs(track.pan) < 0.005 ? "Center" : String(format: "%@-%d%%", track.pan < 0 ? "L" : "R", Int((abs(track.pan) * 100).rounded())))
                            .font(.jarasSystem(size: 7, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(JarasTheme.text).frame(height: 9)
                    }.frame(width: local ? 52.5 : 42, height: 28)
                }
                } else if kind == .click, let localShow {
                    Button("Insert") { localShow.insertClickItems(track: track.id) }
                        .buttonStyle(RemoteNativeTrackButtonStyle(width: 52))
                } else if kind.isText, let addText {
                    Button("Add text", action: addText).buttonStyle(RemoteNativeTrackButtonStyle(width: 82))
                }
                Button { send(.mute, 0) } label: { Text(verbatim: "M") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.mute ? .red : nil))
                Button { send(.solo, 0) } label: { Text(verbatim: "S") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
                }.anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
            }
            if !compact {
            if local && kind.isTeleprompter, let addMedia {
                HStack { Spacer(minLength: 0); Button("Add media", action: addMedia).buttonStyle(RemoteNativeTrackButtonStyle(width: 82))
                        .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] } }
            }
            if hasVolume {
            HStack(spacing: 3) {
                if hasVolume && track.canMeter != false {
                    RemotePeakReadout(decibels: track.peakDB, name: track.name, project: project, song: song, target: track.id, nameColor: track.nameColor ?? 0xffffff, reset: { send(.resetMeterPeak, 0) }).equatable()
                        .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                }
                Text(remoteDecibelText(track.volume)).font(.jarasSystem(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JarasTheme.text).frame(width: 36, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { send(.volume, 1) }
                RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(track.volume), range: -60...12, height: 22, linked: track.linkedTrack != nil) { send(.volume, DAWRemoteFaderScale.gain($0)) }
                    .accessibilityLabel("Volume " + track.name)
                if local, !vinhetas, let localShow {
                    RemoteNativePhaseButton(inverted: nativePhaseInverted) { localShow.send(.phase, target: track.id) }
                }
            }.frame(height: 23)
                .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
            }
            if hasVolume {
            HStack(spacing: 4) {
                if isGroup, let localShow, let nativeTrack {
                    TrackGroupButton(show: localShow, project: project, track: track.id, parent: nativeTrack.parentTrackID)
                            .disabled(!editing)
                        .anchorPreference(key: IpadTrackControlsBoundsKey.self, value: .bounds) { [$0] }
                }
                Text(String(format: "%02d  %@", number, track.name)).font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(remoteColor(track.nameColor ?? 0xffffff)).frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            }
        }.padding(.leading, local && hasVolume ? (kind == .standard && !vinhetas && !compact ? 26 : 19) : 6).padding(.trailing, editing ? 36 : 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    if local && hasVolume && track.canMeter != false {
                        IpadMixerMeter(meter: StemAudioPlayback.shared.meter(for: track.id)).frame(width: 10)
                            .padding(.vertical, 5).padding(.leading, 3)
                    }
                    if local, kind == .standard, !vinhetas, !compact {
                        TrackMIDIIndicator(state: InstrumentKeyboardState.shared.activity(track.id))
                            .frame(width: 3).padding(.vertical, 5).padding(.leading, 17)
                    }
                }
            }
            .background {
                let components = TrackNameContrast.components(track.color, emphasized: track.emphasized == true)
                Color(red: components.red, green: components.green, blue: components.blue)
                    .opacity(track.emphasized == true ? 0.65 : 0.50).saturation(track.silenced == true ? 0 : 1)
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
                        .stroke(JarasTheme.green.opacity(0.7), lineWidth: 1)
                        .frame(width: 12)
                        .padding(.leading, hierarchyWidth - 16)
                        .allowsHitTesting(false)
                }
            }
            .padding(.trailing, iconWidth)
            .overlay(alignment: .trailing) {
                if showsInstrumentIcons {
                    ZStack {
                        JarasTheme.mixer
                        if let raw = track.instrumentIcon, let icon = TrackInstrumentIcon(rawValue: raw) {
                            TrackInstrumentIconView(icon: icon).foregroundStyle(.white)
                                .frame(width: min(32, max(0, geometry.size.height - 4)),
                                       height: min(32, max(0, geometry.size.height - 4)))
                        }
                    }.frame(width: iconWidth)
                        .overlay(alignment: .leading) { Color.white.opacity(0.14).frame(width: 1) }
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Shared by the iPad master and track rows: independent L/R channels with
/// pixel-aligned, equal widths and a transparent gutter between their wells.
private final class IpadStereoMeterLayers {
    let layer = CALayer()
    private let wells = [CALayer(), CALayer()]
    private let bars = [CAGradientLayer(), CAGradientLayer()]
    private let masks = [CALayer(), CALayer()]
    private var size = CGSize.zero
    private var scale: CGFloat = 0
    init() {
        for index in 0..<2 {
            wells[index].backgroundColor = CGColor(gray: 0, alpha: 0.55)
            bars[index].colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                                  CGColor(red: 1, green: 1, blue: 0, alpha: 1),
                                  CGColor(red: 0, green: 1, blue: 0, alpha: 1)]
            bars[index].locations = [0, 0.5, 1]
            masks[index].backgroundColor = CGColor(gray: 1, alpha: 1)
            bars[index].mask = masks[index]
            wells[index].addSublayer(bars[index])
            layer.addSublayer(wells[index])
        }
    }
    func update(size nextSize: CGSize, scale nextScale: CGFloat, levels: SIMD2<Double>) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if size != nextSize || scale != nextScale {
            size = nextSize; scale = max(1, nextScale)
            layer.frame = CGRect(origin: .zero, size: size)
            let pixels = max(0, floor(size.width * scale))
            let gap = min(pixels, ceil(2 * scale))
            let width = max(0, floor((pixels - gap) / 2)) / scale
            for index in 0..<2 {
                // Anchor the right well to the right edge; any spare pixel
                // belongs to the gutter, never to just one audio channel.
                wells[index].frame = CGRect(x: index == 0 ? 0 : pixels / scale - width,
                    y: 0, width: width, height: max(0, size.height))
                bars[index].frame = wells[index].bounds
            }
        }
        for index in 0..<2 {
            let value = levels[index]
            let fraction = value > 0 && value.isFinite ? min(1, max(0, (20 * log10(value) + 60) / 60)) : 0
            let height = max(0, size.height) * fraction
            masks[index].frame = CGRect(x: 0, y: max(0, size.height) - height,
                width: bars[index].bounds.width, height: height)
        }
        CATransaction.commit()
    }
}

/// Meter samples update two layer masks, not SwiftUI layout inside each row.
/// Detached rows stop observing; only meters on screen consume display work.
private struct IpadMixerMeter: UIViewRepresentable {
    let meter: TrackMeterLevel
    func makeUIView(context: Context) -> IpadMixerMeterView { IpadMixerMeterView() }
    func updateUIView(_ view: IpadMixerMeterView, context: Context) { view.bind(meter) }
    static func dismantleUIView(_ view: IpadMixerMeterView, coordinator: ()) { view.unbind() }
}
private final class IpadMixerMeterView: UIView {
    private var meter: TrackMeterLevel?
    private var subscription: AnyCancellable?
    private let drawing = IpadStereoMeterLayers()
    private var levels = SIMD2<Double>(repeating: 0)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(drawing.layer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func bind(_ next: TrackMeterLevel) {
        guard meter !== next else { return }
        subscription = nil; meter = next; observe()
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
        // Lazy rows may remain mounted just outside the scroll viewport.
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds && !convert(bounds, to: view).intersects(view.bounds) { return }
            ancestor = view.superview
        }
        drawing.update(size: bounds.size, scale: window?.screen.scale ?? contentScaleFactor, levels: levels)
    }
}

@MainActor private struct NativeRemoteProjectsView: View {
    let state: DAWRemoteState
    let computerName: String
    let open: (UUID) -> Void
    let openInNewTab: (UUID) -> Void
    let close: () -> Void
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
    func resizeTracks(_ scale: CGFloat) {
        if pinchStartScale == nil {
            pinchStartScale = heightScale
            #if os(iOS)
            momentum?.cancel(); momentum = nil; velocity = 0
            #endif
        }
        let next = DAWRemoteItemLayout.heightScale((pinchStartScale ?? heightScale) * Double(scale))
        if abs(next - heightScale) > 0.0001 { heightScale = next }
    }
    func finishResizingTracks() {
        guard pinchStartScale != nil else { return }
        pinchStartScale = nil
        UserDefaults.standard.set(heightScale, forKey: "jaras.remote.trackHeightScale")
    }
    #if os(iOS)
    weak var scrollView: UIScrollView? {
        didSet {
            guard oldValue !== scrollView else { return }
            trackObservation = scrollView?.observe(\.contentOffset, options: [.new]) { [weak self] source, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.synchronize(source, to: self.gridScrollView)
                }
            }
        }
    }
    weak var gridScrollView: UIScrollView? {
        didSet {
            guard oldValue !== gridScrollView else { return }
            oldValue?.removeGestureRecognizer(itemHold)
            oldValue?.removeGestureRecognizer(gridTapRecognizer)
            gridScrollView?.addGestureRecognizer(itemHold)
            gridScrollView?.addGestureRecognizer(gridTapRecognizer)
            gridObservation = gridScrollView?.observe(\.contentOffset, options: [.new]) { [weak self] source, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.synchronize(source, to: self.scrollView)
                }
            }
        }
    }
    private var trackObservation: NSKeyValueObservation?
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
            if candidate is UIControl { return false }
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
    private func synchronize(_ source: UIScrollView, to target: UIScrollView?) {
        guard let target, source.window != nil, target.window != nil else { return }
        if source === gridScrollView {
            guard source.isDragging || source.isDecelerating else { return }
        } else if gridScrollView?.isDragging == true || gridScrollView?.isDecelerating == true { return }
        let offset = DAWRemoteScrollRange.clamp(Double(source.contentOffset.y), content: Double(target.contentSize.height), viewport: Double(target.bounds.height), topInset: Double(target.adjustedContentInset.top), bottomInset: Double(target.adjustedContentInset.bottom))
        if abs(target.contentOffset.y - offset) > 0.5 {
            target.setContentOffset(CGPoint(x: target.contentOffset.x, y: offset), animated: false)
        }
    }
    private var gestureStart: CGFloat = 0
    private var momentum: Task<Void, Never>?
    private var lastTime: CFTimeInterval = 0
    private var lastTranslation: CGFloat = 0
    private var velocity: CGFloat = 0
    func begin() {
        guard pinchStartScale == nil else { return }
        momentum?.cancel(); momentum = nil
        gestureStart = scrollView?.contentOffset.y ?? 0
        lastTime = CACurrentMediaTime(); lastTranslation = 0; velocity = 0
    }
    func drag(_ translation: CGFloat) {
        guard pinchStartScale == nil else { return }
        let now = CACurrentMediaTime(), elapsed = now - lastTime
        if elapsed > 0.005 { velocity = -(translation - lastTranslation) / elapsed }
        lastTime = now; lastTranslation = translation
        move(to: gestureStart - translation, animated: false)
    }
    func end() {
        guard pinchStartScale == nil else { return }
        guard CACurrentMediaTime() - lastTime < 0.1, abs(velocity) > 30 else { return }
        let initialVelocity = min(5000, max(-5000, velocity))
        momentum = Task { @MainActor [weak self] in
            var speed = initialVelocity
            var timestamp = CACurrentMediaTime()
            while !Task.isCancelled, abs(speed) > 10 {
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
                guard let self, let scroll = self.scrollView, scroll.window != nil,
                      !scroll.isDragging, !scroll.isDecelerating, self.gridScrollView?.isDragging != true, self.gridScrollView?.isDecelerating != true else { return }
                let now = CACurrentMediaTime(), delta = min(0.05, now - timestamp)
                timestamp = now
                let before = scroll.contentOffset.y
                self.move(to: before + speed * delta, animated: false)
                if abs(scroll.contentOffset.y - before) < 0.1 { return }
                speed *= pow(CGFloat(UIScrollView.DecelerationRate.normal.rawValue), delta * 1000)
            }
        }
    }
    func pointerScroll(_ delta: CGFloat) {
        guard let grid = gridScrollView else { return }
        let offset = DAWRemoteScrollRange.clamp(Double(grid.contentOffset.y + delta), content: Double(grid.contentSize.height),
            viewport: Double(grid.bounds.height), topInset: Double(grid.adjustedContentInset.top), bottomInset: Double(grid.adjustedContentInset.bottom))
        grid.setContentOffset(CGPoint(x: grid.contentOffset.x, y: offset), animated: false)
        scrollView?.setContentOffset(CGPoint(x: scrollView?.contentOffset.x ?? 0, y: offset), animated: false)
    }
    func step(_ direction: Int) {
        momentum?.cancel(); momentum = nil
        guard let scrollView else { return }
        move(to: scrollView.contentOffset.y + CGFloat(direction) * max(86, scrollView.bounds.height * 0.5), animated: true)
    }
    private func move(to offset: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let limited = DAWRemoteScrollRange.clamp(Double(offset), content: Double(scrollView.contentSize.height),
            viewport: Double(scrollView.bounds.height), topInset: Double(scrollView.adjustedContentInset.top), bottomInset: Double(scrollView.adjustedContentInset.bottom))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: CGFloat(limited)), animated: animated)
    }
    #else
    func end() {}
    func begin() {}
    func drag(_ translation: CGFloat) {}
    func step(_ direction: Int) {}
    #endif
}
@MainActor private struct RemoteTrackScrollRail: View {
    let controller: RemoteTrackScrollController
    @State private var dragging = false
    @GestureState private var pinching = false
    var body: some View {
        VStack(spacing: 0) {
            Button { controller.step(-1) } label: {
                Image(systemName: "chevron.up").frame(width: 28, height: 36)
            }.accessibilityLabel("Rolar pistas para cima")
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1).fill(JarasTheme.line).frame(width: 2, height: 44)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
            Button { controller.step(1) } label: {
                Image(systemName: "chevron.down").frame(width: 28, height: 36)
            }.accessibilityLabel("Rolar pistas para baixo")
        }.font(.jarasSystem(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.green)
            .buttonStyle(RemoteFullAreaButtonStyle()).frame(maxHeight: .infinity).background(RemoteSurface.display)
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 3)
                .onChanged {
                    if !dragging { controller.begin(); dragging = true }
                    controller.drag($0.translation.height)
                }
                .onEnded { _ in controller.end(); dragging = false })
            .simultaneousGesture(MagnificationGesture()
                .updating($pinching) { _, active, _ in active = true }
                .onChanged { controller.resizeTracks($0) }
                .onEnded { _ in controller.finishResizingTracks(); dragging = false })
            .onChange(of: pinching) { active in
                if !active { controller.finishResizingTracks(); dragging = false }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Área de rolagem do Track-Mixer")
            .accessibilityHint("Use dois dedos em pinça nesta barra para ajustar a altura das pistas")
    }
}
#if os(iOS)
extension RemoteTrackScrollController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        gestureRecognizer === gridTapRecognizer ? receiveGridTap(touch) : receiveItemHold(touch)
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
    var isGrid = false
    var gridTap: ((Double) -> Void)? = nil
    func makeUIView(context: Context) -> RemoteTrackScrollProbeView {
        let view = RemoteTrackScrollProbeView()
        view.isUserInteractionEnabled = false; view.controller = controller; view.isGrid = isGrid
        if isGrid { controller.gridTap = gridTap }
        return view
    }
    func updateUIView(_ view: RemoteTrackScrollProbeView, context: Context) {
        view.controller = controller; view.isGrid = isGrid
        if isGrid { controller.gridTap = gridTap }
        view.resolve()
    }
}
private final class RemoteTrackScrollProbeView: UIView {
    var controller: RemoteTrackScrollController?
    var isGrid = false
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
                    if self.isGrid { self.controller?.gridScrollView = scroll }
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
        TeleprompterProjectionLayout(content: content, fullscreen: fullscreen,
            timerValue: { (timer.displayText().replacingOccurrences(of: ":", with: " : "), timer.displayOpacity(), timer.expired()) },
            media: {
                if remote.isLocalWorkspace {
                    ProjectionMediaSurface(controller: index == 1 ? .teleprompter : .teleprompter2)
                } else if let image = content.imageID {
                    RemoteNativeProjectionImage(id: image, project: state.project, stretch: content.resolvedSettings.stretchesMedia, remote: remote)
                }
            })
            .overlay {
                if !content.resolvedSettings.displaysPreview(content.preview) && !content.resolvedSettings.isClear, let notices = state.notices, notices.active && (index == 1 ? notices.window1 : notices.window2) {
                    RemoteNativeNoticeOverlay(notice: notices, project: state.project, remote: remote)
                }
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
            }.padding(24).frame(maxWidth: .infinity, maxHeight: notice.cleanDisplay ? .infinity : nil)
                .background(remoteColor(flash ? notice.flashColor : notice.backgroundColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                HStack(spacing: 8) {
                    Button { sendNotice() } label: {
                        NoticeSendButtonLabel(phase: sendFeedback.phase)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(NoticeSendButtonStyle(phase: sendFeedback.phase))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (slot < 0 || !notices.imageSlots[slot]))
                    Button { command(.noticeClear) } label: {
                        Text("Withdraw message").frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteNoticeActionStyle()).disabled(!notices.active)
                    Button { command(.noticePin, value: notices.pinned ? 0 : 1) } label: {
                        Label("Pin", systemImage: notices.pinned ? "pin.fill" : "pin")
                            .frame(minWidth: 60, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(RemoteNoticeActionStyle())
                        .foregroundStyle(notices.pinned ? JarasTheme.yellow : JarasTheme.text)
                    Spacer(minLength: 0)
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
                    .frame(height: 150).padding(5).background(RemoteSurface.display).cornerRadius(6)
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
                HStack(spacing: 16) {
                    Toggle("TP-1", isOn: Binding(get: { notices.window1 }, set: { command(.noticeDestination, value: 1, enabled: $0) }))
                    Toggle("TP-2", isOn: Binding(get: { notices.window2 }, set: { command(.noticeDestination, value: 2, enabled: $0) }))
                }.toggleStyle(.button).tint(JarasTheme.green)
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
        if let command = presentation.dismiss(project: remote.remoteState?.project, song: remote.remoteState?.song),
           remote.connected && !remote.reconnecting {
            // The notices-only close action disconnects. Complete the write
            // first so disconnect cannot cancel the withdrawal behind it.
            remote.sendNoticeClear(command, completion: close)
        } else { close() }
    }
    private func withdrawPresentedNotice() {
        guard let command = presentation.dismiss(project: remote.remoteState?.project, song: remote.remoteState?.song),
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
    mutating func dismiss(project: UUID?, song: UUID?) -> DAWRemoteCommand? {
        guard !dismissed else { return nil }
        dismissed = true
        guard let captured = self.project, project == captured else { return nil }
        return .init(project: captured, song: song, action: .noticeClear)
    }
}

/// Only the editor body scrolls. Header and actions retain their touch targets
/// when the keyboard reduces either a popover or a phone panel's height.
struct RemoteNoticePanel<Header: View, Actions: View, Content: View>: View {
    @ViewBuilder let header: () -> Header
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            header().frame(minHeight: 44).padding(.horizontal, 16).padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            actions().padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: 10) { content() }.frame(maxWidth: .infinity)
                    .padding(16)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    private static let brightness: Double = {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 0.72 : 1
        #else
        return 1
        #endif
    }()
    private static func neutral(_ top: Double, _ bottom: Double) -> LinearGradient {
        LinearGradient(colors: [Color(white: top * brightness), Color(white: bottom * brightness)], startPoint: .top, endPoint: .bottom)
    }
    static var background: some View { JarasNativePaletteSurface(color: JarasTheme.background, remote: neutral(0.18, 0.115)) }
    static var panel: some View { JarasNativePaletteSurface(color: JarasTheme.panel, remote: neutral(0.235, 0.155)) }
    static var display: some View { JarasNativePaletteSurface(color: JarasTheme.display, remote: neutral(0.115, 0.075)) }
    static let edge = LinearGradient(colors: [Color.white.opacity(0.16), Color.black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
    static let shading = LinearGradient(colors: [Color.white.opacity(0.10), .clear, Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
    static func fill(_ color: Color) -> some View {
        JarasNativePaletteSurface(color: color, remote: color.overlay(shading)).allowsHitTesting(false)
    }
}

private struct RemoteControlSurface: ViewModifier {
    var color: Color? = nil
    var radius: CGFloat = 6
    func body(content: Content) -> some View {
        content.background {
            if let color { RemoteSurface.fill(color) }
            else { RemoteSurface.panel }
        }.clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(RemoteSurface.edge, lineWidth: 0.5).allowsHitTesting(false))
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
        anchor = Anchor(targetSeconds: snapshot.targetSeconds, running: snapshot.running,
                        remainingSeconds: snapshot.remainingSeconds, uptime: timestamp)
    }
    /// Use when reconnecting to a host so its latest remaining time is sampled.
    func resetSynchronization() { hostRevision = nil; pendingCommand = nil; runID = UUID() }
    @discardableResult func start(seconds: Int) -> UUID? {
        guard !running else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let target = min(TeleprompterTimer.maximumTargetSeconds, max(0, seconds))
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        runID = UUID()
        anchor = Anchor(targetSeconds: target, running: true, remainingSeconds: Double(target), uptime: timestamp)
        return id
    }
    @discardableResult func stop() -> UUID? {
        guard running else { return nil }
        let timestamp = now()
        guard timestamp.isFinite else { return nil }
        let id = UUID(); pendingCommand = (id, timestamp + 3)
        runID = UUID()
        anchor = Anchor(targetSeconds: targetSeconds, running: false, remainingSeconds: 0, uptime: timestamp)
        return id
    }
    @discardableResult func stop(ifRunID id: UUID) -> UUID? {
        guard running, runID == id else { return nil }
        return stop()
    }
    func displaySeconds() -> Double {
        let timestamp = now()
        guard running, timestamp.isFinite else { return anchor.remainingSeconds }
        return anchor.remainingSeconds - max(0, timestamp - anchor.uptime)
    }
    func displayText() -> String {
        let safe = max(-Double(Int.max / 2), min(Double(Int.max / 2), displaySeconds()))
        return TeleprompterTimer.formatted(Int(ceil(safe)))
    }
    func expired() -> Bool { running && displaySeconds() <= 0 }
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
                if timer.running {
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
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    VStack(spacing: 5) {
                        Text(LocalizedStringKey(["Hours", "Minutes", "Seconds"][index]))
                            .font(.jarasSystem(size: 11)).foregroundStyle(JarasTheme.secondary)
                        durationField(index)
                    }.frame(maxWidth: .infinity)
                }
            }.disabled(timer.running)
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
                    if let id = timer.start(seconds: seconds) { synchronizeDigits(); send(.timerStart, Double(seconds), id) }
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
    @ObservedObject private var preview = TeleprompterWindow.shared
    var body: some View {
        IpadPreviewButton(width: width, active: preview.previewActive, page: preview.previewPage,
            toggle: { preview.togglePreview() }, selectPage: { preview.selectPreviewPage($0) })
    }
}
private struct IpadPreviewButton: View {
    let width: CGFloat
    let active: Bool
    let page: Int
    let toggle: () -> Void
    let selectPage: (Int) -> Void
    var body: some View {
        Button(action: toggle) {
            Text(verbatim: "P\nR\nE\nV\nI\nE\nW")
                .font(.jarasSystem(size: 10, weight: .heavy)).multilineTextAlignment(.center)
                .foregroundStyle(Color.black).frame(width: width, height: 108)
                .modifier(RemoteControlSurface(color: active ? JarasTheme.green : JarasTheme.liveOffRed, radius: 5))
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
