import SwiftUI
#if os(macOS)
import UniformTypeIdentifiers
import Combine
struct DAWRemoteHostView: View {
    @ObservedObject private var remote = DAWRemoteSession.shared
    @State private var pin = ""
    @State private var saved = false
    @State private var noticesPIN = ""
    @State private var noticesSaved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Remote").font(.headline)
            Text("Open Remote on the iPad and choose this computer.").font(.callout)
            Text(LocalizedStringKey(remote.status)).font(.caption).foregroundStyle(remote.connected ? JarasTheme.green : JarasTheme.secondary)
            if !remote.peerName.isEmpty { Text(verbatim: remote.peerName).font(.caption) }
            Text("Audio continues on the PC. Direct connection via Wi-Fi and Bluetooth is available only on macOS.").font(.caption).foregroundStyle(JarasTheme.secondary)
            Divider()
            Text("Senha do modo Diretor").font(.headline)
            Text(remote.directorRequiresPIN ? "O Diretor está protegido por senha." : "O Diretor está liberado sem senha.")
                .font(.caption).foregroundStyle(JarasTheme.secondary)
            TextField("4 dígitos · vazio para remover", text: $pin)
                .textFieldStyle(.roundedBorder)
                .onChange(of: pin) { value in pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)); saved = false }
            Text("Deixe vazio e salve para entrar sem senha. Observadores entram sem senha e não controlam o PC.")
                .font(.caption).foregroundStyle(JarasTheme.secondary)
            Button("Salvar senha") { saved = remote.setDirectorPIN(pin) }
                .disabled(!pin.isEmpty && pin.count != 4)
            if saved { Text("Configuração salva.").font(.caption).foregroundStyle(JarasTheme.green) }
            Divider()
            Text("Senha do modo Recados").font(.headline)
            TextField("4 dígitos · vazio para remover", text: $noticesPIN)
                .textFieldStyle(.roundedBorder)
                .onChange(of: noticesPIN) { value in noticesPIN = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)); noticesSaved = false }
            Text("Acesso apenas aos recados. Deixe vazio para entrar sem senha.")
                .font(.caption).foregroundStyle(JarasTheme.secondary)
            Button("Salvar senha de Recados") { noticesSaved = remote.setNoticesPIN(noticesPIN) }
                .disabled(!noticesPIN.isEmpty && noticesPIN.count != 4)
            if noticesSaved { Text("Configuração salva.").font(.caption).foregroundStyle(JarasTheme.green) }
            if remote.enabled { Button("Disable Remote") { remote.setHostEnabled(false) } }
        }.padding(20).frame(width: 320).background(JarasTheme.panel).foregroundStyle(JarasTheme.text)
            .onAppear { pin = remote.savedDirectorPIN; noticesPIN = remote.savedNoticesPIN }
    }
}
#else
import UIKit
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
                    Text("Remote").font(.title2.bold()).foregroundStyle(JarasTheme.green)
                    Text("Control or follow your PC’s session.").multilineTextAlignment(.center).foregroundStyle(JarasTheme.secondary)
                    Button { entering = true } label: {
                        Text("Connect to PC").font(.headline)
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
struct DAWRemoteClientView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var remote = DAWRemoteSession.shared
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
                            Text("Waiting for reconnection").font(.title3.bold())
                            Text(verbatim: remote.peerName).foregroundStyle(JarasTheme.green)
                            Text("Open CatLive and enable Remote on your PC.")
                                .font(.callout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
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
            .onAppear { remote.browse() }.onDisappear { remote.stop() }
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
            .onChange(of: scenePhase) { phase in if phase == .active && !remote.enabled { remote.browse() } }
    }

    private var accessPicker: some View {
        ScrollView {
        VStack(spacing: 20) {
            Text(verbatim: remote.peerName).font(.title2.bold())
            Text(verbatim: "Escolha como acompanhar esta sessão\nChoose how to join this session").foregroundStyle(JarasTheme.secondary)
            let layout = UIDevice.current.userInterfaceIdiom == .phone ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                Button {
                    directorPIN = ""
                    if remote.directorRequiresPIN { enteringMode = .director }
                    else { remote.requestAccess(.director) }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3").font(.largeTitle)
                        Text(verbatim: "Diretor · Director").font(.title3.bold())
                        Text(verbatim: "Controle o CatLive no PC\nControl CatLive on your PC").font(.caption)
                    }.frame(width: 220, height: 140).modifier(RemoteControlSurface(radius: 12))
                }
                Button { directorPIN = ""; remote.requestAccess(.observer) } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "eye").font(.largeTitle)
                        Text(verbatim: "Observador · Observer").font(.title3.bold())
                        Text(verbatim: UIDevice.current.userInterfaceIdiom == .phone ? "Repertório e teleprompters\nRepertoire and teleprompters" : "Acompanhe Setlist e teleprompters\nFollow the setlist and teleprompters").font(.caption)
                    }.frame(width: 220, height: 140).modifier(RemoteControlSurface(radius: 12))
                }
                Button {
                    directorPIN = ""
                    if remote.noticesRequiresPIN { enteringMode = .notices }
                    else { remote.requestAccess(.notices) }
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble").font(.largeTitle)
                        Text(verbatim: "Recados · Notices").font(.title3.bold())
                        Text(verbatim: "Envie recados aos teleprompters\nSend notices to the teleprompters").font(.caption)
                    }.frame(width: 220, height: 140).modifier(RemoteControlSurface(radius: 12))
                }
            }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green).disabled(remote.authorizing)
            if let enteringMode {
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(JarasTheme.green)
                    Text(verbatim: enteringMode == .notices ? "Acesso Recados · Notices access" : "Acesso Diretor · Director access").font(.headline)
                    Text(verbatim: remote.peerName).font(.subheadline).foregroundStyle(JarasTheme.secondary)
                    SecureField("", text: $directorPIN, prompt: Text(verbatim: "••••"))
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center).padding(12).frame(width: 180)
                        .background(RemoteSurface.background).clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Senha de quatro dígitos · Four-digit PIN")
                        .onChange(of: directorPIN) { value in directorPIN = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4)) }
                    Button { remote.requestAccess(enteringMode, pin: directorPIN) } label: {
                        HStack { if remote.authorizing { ProgressView() }; Text(verbatim: "Conectar · Connect"); Image(systemName: "arrow.right") }
                            .font(.headline).padding(.vertical, 12).frame(maxWidth: .infinity)
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
                        Label { Text(verbatim: "Voltar · Back") } icon: { Image(systemName: "chevron.left") }.font(.system(size: 14, weight: .semibold))
                    }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary)
                    Spacer()
                }.padding(24)
                Spacer(minLength: 12)
                VStack(spacing: 22) {
                    Image(systemName: "desktopcomputer").font(.system(size: 38, weight: .light))
                        .foregroundStyle(JarasTheme.green).frame(width: 80, height: 80)
                        .background(JarasTheme.green.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 8) {
                        Text(verbatim: "Conectar ao PC · Connect to PC").font(.system(size: 23, weight: .semibold))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: "Conecte o PC e este aparelho à mesma rede. Ative Remote no CatLive do PC e escolha-o abaixo.\n\nConnect your PC and this device to the same network. Enable Remote in CatLive on your PC, then choose it below.")
                            .font(.system(size: 14)).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Label { Text(verbatim: "Somente macOS: conexão direta por Wi-Fi e Bluetooth, sem roteador. Deixe ambos ligados nos dois aparelhos.\nmacOS only: direct connection via Wi-Fi and Bluetooth, without a router. Keep both enabled on both devices.") } icon: { Image(systemName: "wifi") }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(JarasTheme.green)
                    }
                    VStack(spacing: 10) {
                        HStack {
                            Text(verbatim: "PCs disponíveis · Available PCs").font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary)
                            Spacer()
                            Button { remote.browse() } label: {
                                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 30)
                            }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green).disabled(remote.connecting)
                                .accessibilityLabel(Text(verbatim: "Buscar PCs novamente · Refresh PCs"))
                        }
                        if remote.peers.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().tint(JarasTheme.green)
                                Text(verbatim: "Procurando PCs… · Searching for PCs…").font(.system(size: 14)).foregroundStyle(JarasTheme.secondary)
                            }.frame(maxWidth: .infinity).frame(height: 76).background(RemoteSurface.background).cornerRadius(10)
                        } else {
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(remote.peers, id: \.self) { peer in
                                        Button { remote.connect(peer) } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: "desktopcomputer").font(.system(size: 22)).foregroundStyle(JarasTheme.green)
                                                Text(verbatim: peer.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                                Spacer()
                                                if remote.connecting && remote.peerName == peer.displayName { ProgressView().tint(JarasTheme.green) }
                                                else { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.secondary) }
                                            }.padding(16).background(RemoteSurface.background).cornerRadius(10)
                                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(remote.connecting && remote.peerName == peer.displayName ? JarasTheme.green : JarasTheme.line))
                                        }.buttonStyle(RemoteFullAreaButtonStyle()).disabled(remote.connecting)
                                    }
                                }
                            }.frame(height: min(220, CGFloat(remote.peers.count) * 68))
                        }
                        if remote.status.hasPrefix("Connection failed") {
                            Text(verbatim: "Não foi possível conectar. Aproxime os aparelhos e confira o Remote no PC.\nCould not connect. Bring the devices closer and check Remote on your PC.")
                                .font(.system(size: 12)).foregroundStyle(JarasTheme.yellow)
                        } else if remote.status == "Disconnected" {
                            Text(verbatim: "Conexão encerrada. Escolha o PC para reconectar.\nDisconnected. Choose your PC to reconnect.")
                                .font(.system(size: 12)).foregroundStyle(JarasTheme.secondary)
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

#if os(macOS)
@MainActor enum DAWRemoteHostBridge {
    static weak var documents: ProjectDocuments?
    private static var noticeImageDate = Date.distantPast
    private static var noticeImageData: Data?
    private static var lastTimerState: TeleprompterTimer?
    private static var timerRevision = UUID()
    private static var lastTimerCommandID: UUID?
    private static var cachedProject: UUID?, cachedSong: UUID?, cachedRevision: UInt64?
    private static var cachedGridTempo: [DAWRemoteState.GridTempo] = []
    private static var cachedItems: [UUID: (clips: [DAWRemoteState.Clip], lanes: Int)] = [:]
    static func bind(_ show: ShowController) {
        cachedProject = nil; cachedSong = nil; cachedRevision = nil; cachedItems.removeAll()

        let session = DAWRemoteSession.shared
        session.stateProviderForSession = { [weak show] remote in
            guard let show, remote.connected else { return nil }
            let requestedPanel = remote.requestedPanel
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            let snapshot = show.snapshot, song = show.current, transport = snapshot.transport
            let playedLiveIDs = show.playedLiveRegionIDs
            let sendsPeaks = remote.accessMode == .director
            // Geometry and item metadata change with project edits, not transport ticks.
            if cachedProject != snapshot.project.id || cachedSong != song?.id || cachedRevision != show.projectRevision {
                cachedProject = snapshot.project.id; cachedSong = song?.id; cachedRevision = show.projectRevision
                cachedGridTempo = (song?.tempoSections(until: max(song?.duration ?? 0, song?.parts.map(\.endTime).max() ?? 0)) ?? []).map {
                    .init(start: $0.start, end: $0.end, bpm: $0.bpm, beats: $0.beats, unit: $0.unit)
                }
                cachedItems = Dictionary(uniqueKeysWithValues: (song?.tracks ?? []).filter { $0.kind == .standard }.map { track in
                    let lanes = TrackLanes(track: track)
                    let clips = track.clips.map { DAWRemoteState.Clip(id: $0.id, name: $0.name, start: $0.startTime, duration: $0.duration,
                        gain: $0.gain ?? 1, muted: $0.muted ?? false, lane: lanes.lanes[$0.id] ?? 0) }
                    return (track.id, (clips: clips, lanes: lanes.count))
                })
            }
            let selectedPlaylist = show.selectedRegionPlaylist
            let regionTextColor = UInt32(AppearanceColor.shared(selectedPlaylist == nil ? "jaras.setlist.allRegionsTextColor" : "jaras.setlist.playlistTextColor",
                default: selectedPlaylist == nil ? 0xffffff : 0x00ff9a).value)
            let unifiedTextColor = UInt32(AppearanceColor.shared("jaras.setlist.unifiedTextColor", default: 0xffeb3b).value)
            @MainActor func region(_ part: Part) -> DAWRemoteState.Region {
                .init(id: part.id, name: part.displayName, start: part.startTime, end: part.endTime, color: part.color ?? 0x705264,
                      nameColor: part.parentRegionID != nil ? unifiedTextColor : regionTextColor, parentRegion: part.parentRegionID)
            }
            let selected = transport.playing ? show.pitchRegion : song?.parts.first { $0.id == (show.focusedRegion ?? transport.regionId) }
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
                : song?.parts.first(where: { $0.id == show.focusedRegion }) ?? song?.sectionRegion(at: transport.editPosition ?? transport.position)
            let secondarySectionRegion = transport.subPlay.playing ? song?.sectionRegion(at: transport.subPlay.position)
                : song?.parts.first(where: { $0.id == transport.queuedRegionId })
            let displays = TransportSongDisplays(song: song, transport: transport, focusedRegion: show.focusedRegion)
            let nextSection = transport.queuedSectionMarkerId == nil ? nil : song?.nextSectionTrigger(for: transport)
            return DAWRemoteState(project: snapshot.project.id, projectName: snapshot.project.name,
                song: song?.id, songName: song?.name ?? "—",
                songs: snapshot.project.songs.map { .init(id: $0.id, name: $0.name) },
                tracks: (song?.tracks ?? []).filter { $0.kind == .standard }.map { track in
                    let items = cachedItems[track.id]
                    return .init(id: track.id, name: track.name, color: track.color ?? JarasTheme.roleHex(track.role),
                          volume: track.volume, pan: track.pan, mute: track.mute, solo: track.solo,
                          clips: items?.clips ?? [],
                          nameColor: JarasTheme.trackNameHex(track, emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute),
                          emphasized: show.mixerTrackSelection.contains(track.id), silenced: song?.isSilenced(track) ?? track.mute, laneCount: items?.lanes ?? 1, linkedTrack: track.stereoLink?.partner, heightScale: track.heightScale,
                          peakDB: sendsPeaks && !track.kind.isText && track.kind != .timecode ? StemAudioPlayback.shared.meter(for: track.id).peakHold.decibels : nil,
                          canMeter: !track.kind.isText && track.kind != .timecode)
                }, regions: show.listedRegions.map(region), timelineRegions: (song?.parts ?? []).map(region),
                currentRegion: transport.regionId, queuedRegion: transport.queuedRegionId, focusedRegion: show.focusedRegion,
                position: transport.position, duration: song?.duration ?? 0,
                bpm: show.tempoControlBPM,
                playing: transport.playing, paused: transport.paused ?? false,
                subPlaying: transport.subPlay.playing, loop: transport.loop.enabled,
                masterVolume: snapshot.project.masterVolume ?? 1, masterMute: snapshot.project.masterMute ?? false,
                masterSolo: snapshot.project.masterSolo ?? false, masterMono: snapshot.project.masterMono ?? false,
                pendingSave: show.hasUnsavedChanges, saving: show.saving, message: show.message,
                multiLoopsBypassed: transport.multiLoopsBypassed == true,
                setlistLiveEnabled: show.setlistLiveEnabled,
                playedLiveRegionIDs: (song?.parts ?? []).filter { playedLiveIDs.contains($0.id) }.map(\.id),
                masterPeakDB: sendsPeaks ? StemAudioPlayback.shared.masterMeter.peakHold.decibels : nil,
                pitchRegion: show.pitchRegion?.id, pitchSemitones: show.pitchRegion?.semitones,
                setlistFontStyle: UserDefaults.standard.integer(forKey: "jaras.setlist.fontStyle"),
                prepareOnly: show.regionSetlist.preparesWithoutPlayback,
                masterColor: snapshot.project.masterColor ?? 0xffdc52,
                masterNameColor: JarasTheme.masterNameHex(snapshot.project.masterColor ?? 0xffdc52),
                regionAuto: show.regionSetlist.autoAdvance, queueStartedAt: transport.queueStartedAt,
                playbackEnd: transport.ignoreNextEnd ?? song?.parts.first(where: { $0.id == transport.regionId })?.endTime,
                projectSavedAt: show.lastSavedAt ?? snapshot.project.updatedAt, footerInformation: information,
                footerLoopBeatPhase: FooterInformationDisplay.loopBeatPhase(transport: transport, song: song),
                upcomingName: (internalNext ?? queued)?.displayName,
                upcomingKind: internalNext != nil ? "Next song" : transport.subPlay.playing ? "Sub Play" : "Queued song",
                playlists: show.regionSetlist.playlists.filter { $0.songId == song?.id }.map { .init(id: $0.id, name: $0.name) },
                selectedPlaylist: selectedPlaylist?.id,
                gridRegion: transport.playing ? song?.playingSetlistRegion(transport.regionId, position: transport.position, expanded: [])?.id : (show.focusedRegion ?? transport.regionId),
                markers: (song?.markers ?? []).filter { !$0.isTempo }.map { .init(id: $0.id, name: song?.markerLabel($0) ?? $0.name, position: $0.position, color: $0.color, section: $0.isSection, unifiedRegionID: $0.unifiedRegionID, sourceRegionID: $0.sourceRegionID) },
                projects: documents?.remoteProjectBrowser,
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
                    playlistSeconds: show.listedRegions.reduce(0) { $0 + max(0, $1.endTime - $1.startTime) }))
        }
        session.commandHandler = { [weak show] command in
            guard command.valid else { return }
            if command.action == .timerStart || command.action == .timerStop {
                lastTimerCommandID = command.id; timerRevision = UUID()
            }
            guard let show, command.project == show.snapshot.project.id else { return }
            let documents = Self.documents.flatMap { $0.show === show ? $0 : nil }
            if command.action == .remotePanel { return }
            if handleNotice(command) { return }
            if command.action == .timerStart {
                let timer = TeleprompterTimerController.shared, seconds = Int(command.value)
                timer.stopAndReset()
                if timer.setTargetText(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)) { timer.start() }
                return
            }
            if command.action == .timerStop { TeleprompterTimerController.shared.stopAndReset(); return }
            if command.action == .openRecentProject {
                if let target = command.target { documents?.openRemoteProject(target) }
                return
            }
            guard documents?.busy != true, command.song == show.current?.id else { return }
            if [.volume, .pan, .mute, .solo, .resetMeterPeak].contains(command.action), let target = command.target {
                guard show.current?.tracks.contains(where: { $0.id == target }) == true else { return }
            }
            if [.clipGain, .clipMute].contains(command.action) {
                guard let target = command.target, show.current?.tracks.contains(where: { track in
                    track.kind == .standard && track.clips.contains { $0.id == target }
                }) == true else { return }
            }
            switch command.action {
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
                guard let target = command.target, show.current?.parts.contains(where: { $0.id == target }) == true else { return }
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
                guard !show.isPlaying, let song = show.current,
                      let target = command.target, target == (show.focusedRegion ?? show.snapshot.transport.regionId),
                      let region = song.parts.first(where: { $0.id == target }) else { return }
                show.send(.seek, value: min(region.endTime, max(region.startTime, command.value)))
            default:
                guard let action = ShowCommand(rawValue: command.action.rawValue) else { return }
                show.send(action, target: command.target, value: command.value)
            }
        }
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
        case .noticeSend:
            model.select(Int(command.value)); model.draft = command.text ?? ""; model.send()
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
    private static func teleprompter(index: Int, snapshot: ShowSnapshot, directory: URL?, remote: DAWRemoteSession) -> DAWRemoteTeleprompter {
        let settings = (index == 1 ? TeleprompterPreferences.shared : .second).settings
        let controller = index == 1 ? TeleprompterWindow.shared : .second
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
            style: style, preview: settings.displaysPreview(controller.previewActive), settings: settings)
        if result.preview, let song {
            let setlist = snapshot.project.regionSetlist ?? RegionSetlist()
            let playlist = setlist.playlists.first { $0.id == setlist.selectedId && $0.songId == song.id }
            let lookup = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
            let regions = playlist.map { $0.regionIds.compactMap { lookup[$0] } } ?? song.parts.filter { $0.parentRegionID == nil }.sorted { $0.startTime < $1.startTime }
            let headers = Dictionary(grouping: (setlist.blocks ?? []).filter { $0.songId == song.id && $0.playlistId == playlist?.id }, by: \.beforeRegionId)
            var blocks = [DAWRemoteTeleprompter.Block(id: song.id, name: "", color: 0xffea00, rows: [])]
            for part in regions {
                for header in headers[part.id] ?? [] {
                    blocks.append(.init(id: header.id, name: settings.display(header.name), color: header.color, rows: []))
                }
                let last = blocks.count - 1
                blocks[last].rows.append(.init(id: part.id, name: settings.display(part.displayName),
                    color: part.id == region?.id ? settings.highlightColor : part.id == queued?.id ? settings.queueNameColor : part.color ?? blocks[last].color,
                    duration: max(0, part.endTime - part.startTime)))
            }
            blocks += (headers[nil] ?? []).map { .init(id: $0.id, name: settings.display($0.name), color: $0.color, rows: []) }
            result.blocks = Array(blocks.filter { !$0.name.isEmpty || !$0.rows.isEmpty }.dropFirst(controller.previewPage * 4).prefix(4))
        }
        if !result.preview || settings.isClear, let media, let file = media.audioFile, let directory,
           UTType(filenameExtension: URL(fileURLWithPath: file.path).pathExtension)?.conforms(to: .image) == true {
            result.imageID = remote.imageID(for: directory.appendingPathComponent(file.path), project: snapshot.project.id)
            result.mediaName = media.name
        }
        return result
    }
}
#else
@MainActor private struct NativeRemoteWorkspace: View {
    @Environment(\.isEnabled) private var controlsEnabled
    let state: DAWRemoteState
    let computerName: String
    let timer: RemoteLocalTimer
    let send: (DAWRemoteCommand) -> Void
    let exitRemote: () -> Void
    var observer = false
    @State private var phonePanel: DAWRemotePhonePanel = .setlist
    @State private var navigationOpen = false
    @State private var sidebarHidden = false
    @State private var projectsOpen = false
    @State private var playlistPickerOpen = false
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
    private var verticalSections: Bool { UIDevice.current.userInterfaceIdiom == .phone || sectionsInList }
    @State private var settingsOpen = false
    @State private var confirmSave = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var keyboardVisible = false
    @State private var expandedRegions: Set<UUID> = []
    @State private var itemLayoutCache = DAWRemoteItemLayoutCache()
    @State private var setlistRowsCache = DAWRemoteSetlistRowsCache()
    @StateObject private var trackScrolling = RemoteTrackScrollController()
    @AppStorage("jaras.remote.mixerHidden") private var mixerHidden = false
    @AppStorage("jaras.remote.trackWidth") private var savedTrackFraction = 0.30
    @AppStorage("jaras.remote.setlistWidth") private var savedSetlistFraction = 0.32
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
        if abs(savedSetlistFraction - widths.setlist) > 0.0001 { savedSetlistFraction = widths.setlist }
        if mixerHidden != (widths.track == 0) { mixerHidden = widths.track == 0 }
    }
    private func finishPanelResize() {
        if let livePanelWidths { persistPanelWidths(livePanelWidths) }
        livePanelWidths = nil; trackResizeStart = nil; setlistResizeStart = nil
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
    private var visibleTracks: [DAWRemoteState.Track] { itemLayoutCache.tracks(state.tracks, within: gridRegion) }
    private var drawerRegion: DAWRemoteState.Region? { DAWRemoteSetlistPresentation.drawer(in: state) }
    private var drawerExpanded: Bool { drawerRegion.map { expandedRegions.contains($0.id) } ?? false }
    private func toggleDrawer(_ id: UUID) {
        guard DAWRemoteSetlistPresentation.canToggleDrawer(id, in: state) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            if !expandedRegions.insert(id).inserted { expandedRegions.remove(id) }
        }
    }
    private func action(_ action: DAWRemoteCommand.Action, target: UUID? = nil, value: Double = 0) {
        send(.init(project: state.project, song: state.song, action: action, target: target, value: value))
    }
    private func updatePanelSubscription() {
        guard state.timer != nil else { return }
        let panel = UIDevice.current.userInterfaceIdiom == .phone ? (observer && phonePanel.subscription > 2 ? 0 : phonePanel.subscription) : (prompterPanel?.rawValue ?? (noticesOpen ? 3 : 0))
        action(.remotePanel, value: Double(panel))
    }
    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone {
                if observer { phoneRepertoire } else { phoneDirectorWorkspace }
            }
            else if observer { observerWorkspace }
            else { directorWorkspace }
        }
        .onChange(of: controlsEnabled) { enabled in
            if !enabled {
                navigationOpen = false; projectsOpen = false; playlistPickerOpen = false
                noticesOpen = false; timerOpen = false; settingsOpen = false; confirmSave = false
                searchFocused = false; scrubPosition = nil; pendingSeek = nil
            } else { updatePanelSubscription() }
        }
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
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                .frame(width: width, height: 30).contentShape(Rectangle())
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green).accessibilityLabel("Hide sidebar")
    }
    private func restoreSidebarButton(height: CGFloat = 25) -> some View {
        Button(action: revealSidebar) {
            Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold))
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
                else if let icon { Image(systemName: icon).font(.system(size: 18, weight: .semibold)) }
                else { Text(verbatim: title).font(.system(size: 11, weight: .bold)) }
            }.frame(width: 44, height: 44)
                .modifier(RemoteControlSurface(color: phonePanel == panel ? JarasTheme.green.opacity(0.14) : nil, radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle())
            .foregroundStyle(phonePanel == panel ? JarasTheme.green : panel == .notices ? JarasTheme.yellow : panel.subscription > 0 ? .red : JarasTheme.secondary)
            .accessibilityLabel(LocalizedStringKey(title)).accessibilityValue(phonePanel == panel ? "Shown" : "Hidden")
    }
    private var cancelSectionButton: some View {
        Button { action(.cancelSection) } label: {
            Text("Cancel").font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 28)
                .contentShape(Rectangle())
        }.buttonStyle(RemoteCancelSectionButtonStyle())
            .disabled(state.sectionPlayback?.queuedMarker == nil)
            .accessibilityLabel("Cancel queued section")
    }
    private var phoneDirectorWorkspace: some View {
        HStack(spacing: sidebarHidden ? 0 : 1) {
            GeometryReader { rail in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
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
                    Spacer(minLength: 12)
                    phonePanelButton(.sections, title: "Section manager")
                    Button { settingsOpen = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel("Configurações")
                    hideSidebarButton(width: 44)
                }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).frame(minHeight: max(0, rail.size.height - 8)).padding(.vertical, 4)
            }
            }.frame(width: sidebarHidden ? 0 : 44).clipped().allowsHitTesting(!sidebarHidden).accessibilityHidden(sidebarHidden).background(RemoteSurface.panel)
            VStack(spacing: 1) {
                if !prompterFullscreen { phoneTransport }
                Group {
                    switch phonePanel {
                    case .mixer: trackMixer
                    case .setlist: setlist
                    case .grid:
                        RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition,
                            control: { action($0, target: $1, value: $2) }, preview: { scrubPosition = $0 }, seek: { position in
                                scrubPosition = nil
                                guard !state.playing, let region = selectedTimelineRegion else { return }
                                pendingSeek = position; seekSentAt = Date(); action(.seek, target: region.id, value: position)
                            })
                    case .teleprompter1, .teleprompter2:
                        RemoteNativeTeleprompterPanel(index: phonePanel.subscription, timer: timer,
                            fullscreen: prompterFullscreen, toggleFullscreen: { prompterFullscreen.toggle() }, managesSubscription: false)
                    case .notices:
                        RemoteNativeNoticesView(close: { choosePhonePanel(.grid) }, managesSubscription: false)
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
            .sheet(isPresented: $settingsOpen) { NativeRemoteSettingsView().presentationDetents([.height(220)]).preferredColorScheme(.dark) }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) }, close: { projectsOpen = false })
            }
            .alert("Do you want to save this project?", isPresented: $confirmSave) {
                Button("Cancel", role: .cancel) {}
                Button("Save") { action(.save) }
            }
    }
    private func phoneTransportButton(_ title: String, icon: String, active: Bool = false, color: Color = JarasTheme.green, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(title)).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteControlSurface(color: active ? color.opacity(0.35) : nil, radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(color)
    }
    private var phoneTransport: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(state.playing ? "Now playing" : "Selected song").font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(verbatim: timeText).monospacedDigit().font(.system(size: 12, weight: .semibold))
                }.foregroundStyle(JarasTheme.secondary)
                Text(verbatim: state.songDisplays?.current ?? selectedTimelineRegion?.name ?? state.songName)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(JarasTheme.green).lineLimit(2)
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
            .font(.system(size: 10, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
            .multilineTextAlignment(.center).accessibilityLabel("Information")
    }
    private var phoneRepertoire: some View {
        HStack(spacing: sidebarHidden ? 0 : 1) {
            VStack(spacing: 2) {
                Menu { Button("Exit Remote", action: exitRemote) } label: {
                    Image(systemName: "line.3.horizontal").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Menu")
                phonePanelButton(.setlist, title: "Setlist", icon: "list.bullet")
                phonePanelButton(.teleprompter1, title: "TP1")
                phonePanelButton(.teleprompter2, title: "TP2")
                Spacer(minLength: 0)
                hideSidebarButton(width: 44)
            }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).frame(width: sidebarHidden ? 0 : 44).clipped().allowsHitTesting(!sidebarHidden).accessibilityHidden(sidebarHidden).background(RemoteSurface.panel)
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
                        fullscreen: prompterFullscreen, toggleFullscreen: { prompterFullscreen.toggle() }, managesSubscription: false)
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
            Text(LocalizedStringKey(title)).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RemoteSurface.display).cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false))
    }
    private var observerWorkspace: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - (sidebarHidden ? 0 : 37))
            HStack(spacing: sidebarHidden ? 0 : 1) {
                VStack(spacing: 2) {
                    Button { navigationOpen.toggle() } label: { Image(systemName: "line.3.horizontal").frame(width: 36, height: 36) }
                        .accessibilityLabel("Abrir barra lateral")
                    topPrompterButton(.first, title: "TP1")
                    topPrompterButton(.second, title: "TP2")
                    Spacer()
                    hideSidebarButton(width: 36)
                }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).frame(width: sidebarHidden ? 0 : 36).clipped().allowsHitTesting(!sidebarHidden).accessibilityHidden(sidebarHidden).padding(.top, 6).background(RemoteSurface.panel)
                VStack(spacing: 8) {
                    if !prompterFullscreen {
                        HStack(spacing: 8) {
                            observerDisplay(state.playing ? "Tocando" : "Selecionada", value: observerCurrentName, color: JarasTheme.green)
                            observerDisplay("Fila de espera", value: observerQueuedName, color: JarasTheme.yellow)
                            topPrompterButton(.first, title: "TP1").frame(width: 52)
                            topPrompterButton(.second, title: "TP2").frame(width: 52)
                        }.padding(8).background(RemoteSurface.panel)
                    }
                    HStack(spacing: 8) {
                        if let panel = prompterPanel {
                            RemoteNativeTeleprompterPanel(index: panel.rawValue, timer: timer,
                                fullscreen: prompterFullscreen, toggleFullscreen: togglePrompterFullscreen,
                                toggleSetlist: togglePrompterSetlist, setlistVisible: prompterSetlistFraction > 0, managesSubscription: false)
                                .frame(width: prompterFullscreen || prompterSetlistFraction == 0 ? width : width * 0.70).clipped()
                        }
                        if !prompterFullscreen && (prompterPanel == nil || prompterSetlistFraction > 0) { observerSetlist }
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
            Text(verbatim: title).font(.caption2).foregroundStyle(JarasTheme.secondary)
            Text(verbatim: value).font(.system(size: 15, weight: .semibold)).foregroundStyle(color).lineLimit(1)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RemoteSurface.display).cornerRadius(5)
    }
    private var observerSetlist: some View {
        let played = Set(state.playedLiveRegionIDs ?? [])
        return ScrollView(.vertical) {
            LazyVStack(spacing: 5) {
                ForEach(setlistRowsCache.rows(in: state, expanded: expandedRegions, query: "")) { row in
                    let region = row.region
                    setlistLabel(region.name, number: row.number, played: played.contains(region.id), selected: observerRegion(region.id, contains: state.focusedRegion),
                        active: state.playing && observerRegion(region.id, contains: state.currentRegion), queued: observerRegion(region.id, contains: state.queuedRegion),
                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? 0xffffff),
                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.currentRegion ? state.position : region.start)))),
                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                        .modifier(RemoteRegionDrawerGesture(enabled: row.hasDrawer, toggle: { toggleDrawer(region.id) }))
                        .padding(.leading, row.child ? 20 : 0)
                }
                if state.regions.isEmpty {
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
            let contentWidth = max(0, geometry.size.width - (sidebarHidden ? 0 : 37))
            let panelSpace = max(1, contentWidth - 20)
            HStack(spacing: sidebarHidden ? 0 : 1) {
                VStack(spacing: 0) {
                    Button { withAnimation(.easeOut(duration: 0.16)) { navigationOpen.toggle() } } label: {
                        Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).accessibilityLabel("Abrir barra lateral")
                    Button { withAnimation(.easeOut(duration: 0.16)) {
                        let current = panelWidths
                        let restored = savedTrackFraction.isFinite && savedTrackFraction > 0 ? savedTrackFraction : 0.30
                        let expand = prompterPanel != nil || mixerCollapsed
                        showPrompter(nil)
                        persistPanelWidths(.init(track: expand ? restored : 0, setlist: current.setlist))
                        livePanelWidths = nil; trackResizeStart = nil; setlistResizeStart = nil
                    } } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(prompterPanel != nil || mixerCollapsed ? Color(hex: 0xc44545) : JarasTheme.green)
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true))
                        .accessibilityLabel(prompterPanel != nil || mixerCollapsed ? "Expandir Track-Mixer" : "Recolher Track-Mixer")
                        .accessibilityValue(prompterPanel != nil || mixerCollapsed ? "Hidden" : "Shown")
                    Button { showPrompter(prompterPanel == .first ? nil : .first) } label: {
                        Text(verbatim: "TP1").font(.system(size: 10, weight: .bold)).frame(width: 36, height: 36)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(prompterPanel == .first ? JarasTheme.green : Color(hex: 0xff5555))
                        .accessibilityLabel("Teleprompter 1").accessibilityValue(prompterPanel == .first ? "On" : "Off")
                    Button { showPrompter(prompterPanel == .second ? nil : .second) } label: {
                        Text(verbatim: "TP2").font(.system(size: 10, weight: .bold)).frame(width: 36, height: 36)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(prompterPanel == .second ? JarasTheme.green : Color(hex: 0xff5555))
                        .accessibilityLabel("Teleprompter 2").accessibilityValue(prompterPanel == .second ? "On" : "Off")
                    Button { noticesOpen = true } label: {
                        Image(systemName: "text.bubble").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 36)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(JarasTheme.yellow).accessibilityLabel("Notices")
                        .popover(isPresented: $noticesOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                            RemoteNativeNoticesView(close: { noticesOpen = false }, managesSubscription: false)
                                .frame(width: 440, height: 430).preferredColorScheme(.dark)
                        }
                    Button { timerOpen = true } label: {
                        Image(systemName: "clock").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(Color(hex: 0x409cff)).accessibilityLabel("Timer")
                        .popover(isPresented: $timerOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .leading) {
                            VStack(spacing: 0) {
                                RemoteNativeTimerView(timer: timer, send: {
                                    guard state.timer != nil else { return }
                                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                                }, close: { timerOpen = false })
                                if state.timer == nil {
                                    Text("Atualize o CatLive no PC para sincronizar o cronômetro.")
                                        .font(.caption).foregroundStyle(JarasTheme.secondary).padding(12).frame(width: 300)
                                }
                            }.background(RemoteSurface.panel).preferredColorScheme(.dark)
                        }
                    Spacer(minLength: 0)
                    Button {
                        let wasOpen = sectionsOpen && !sectionsInList
                        sectionsInList = false
                        sectionsOpen = !wasOpen
                    } label: {
                        SectionButtonsIcon().frame(width: 36, height: 36)
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(sectionsOpen && !sectionsInList ? JarasTheme.green : JarasTheme.secondary)
                        .accessibilityLabel("Section manager").accessibilityValue(sectionsOpen && !sectionsInList ? "Shown" : "Hidden")
                    Button { settingsOpen = true } label: {
                        Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(RemoteFullAreaButtonStyle(surface: true)).foregroundStyle(settingsOpen ? JarasTheme.green : JarasTheme.secondary)
                        .accessibilityLabel("Configurações")
                        .popover(isPresented: $settingsOpen) { NativeRemoteSettingsView().preferredColorScheme(.dark) }
                        .padding(.bottom, 6)
                    hideSidebarButton(width: 36).padding(.bottom, 4)
                }.padding(.top, 6).frame(width: sidebarHidden ? 0 : 36).clipped().allowsHitTesting(!sidebarHidden).accessibilityHidden(sidebarHidden).background(RemoteSurface.panel)
                VStack(spacing: 1) {
                    if !prompterFullscreen { transportBar }
                    HStack(spacing: 0) {
                        if let panel = prompterPanel {
                            let space = max(1, contentWidth - 10)
                            RemoteNativeTeleprompterPanel(index: panel.rawValue, timer: timer,
                                fullscreen: prompterFullscreen, toggleFullscreen: togglePrompterFullscreen,
                                toggleSetlist: togglePrompterSetlist, setlistVisible: prompterSetlistFraction > 0, managesSubscription: false)
                                .frame(width: prompterFullscreen ? contentWidth : space * (1 - prompterSetlistFraction)).clipped()
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
                            trackMixer.frame(width: panelSpace * panelWidths.track).clipped()
                                .allowsHitTesting(!mixerCollapsed).accessibilityHidden(mixerCollapsed)
                            resizeHandle(label: "Ajustar largura do Track-Mixer", changed: { translation in
                                let start = trackResizeStart ?? panelWidths
                                if trackResizeStart == nil { trackResizeStart = start }
                                let widths = start.resizingTrack(by: translation / panelSpace)
                                if panelWidths != widths { livePanelWidths = widths }
                            }, ended: finishPanelResize)
                        RemoteNativeTimeline(state: state, tracks: visibleTracks, scrolling: trackScrolling, region: gridRegion, position: displayedPosition,
                            control: { action($0, target: $1, value: $2) },
                            preview: { scrubPosition = $0 }, seek: { position in
                                scrubPosition = nil
                                guard !state.playing, let region = selectedTimelineRegion else { return }
                                pendingSeek = position; seekSentAt = Date()
                                action(.seek, target: region.id, value: position)
                            }).frame(width: panelSpace * panelWidths.grid).clipped()
                                .allowsHitTesting(panelWidths.grid > 0).accessibilityHidden(panelWidths.grid == 0)
                        resizeHandle(label: "Ajustar largura do Setlist", changed: { translation in
                            let start = setlistResizeStart ?? panelWidths
                            if setlistResizeStart == nil { setlistResizeStart = start }
                            let widths = start.resizingSetlist(by: translation / panelSpace)
                            if panelWidths != widths { livePanelWidths = widths }
                        }, ended: finishPanelResize)
                        }
                        let setlistWidth = prompterFullscreen ? 0 : prompterPanel == nil ? panelSpace * panelWidths.setlist : max(1, contentWidth - 10) * prompterSetlistFraction
                        setlistWithSections.frame(width: setlistWidth).clipped()
                            .allowsHitTesting(setlistWidth > 0).accessibilityHidden(setlistWidth == 0)
                    }
                    if sectionsOpen && !verticalSections && !keyboardVisible && !prompterFullscreen &&
                        (prompterPanel == nil ? panelWidths.setlist > 0 : prompterSetlistFraction > 0) {
                        remoteSections.frame(height: SmoothSeekPanelLayout.height)
                    }
                    if !keyboardVisible && !prompterFullscreen { footer }


                }.frame(width: contentWidth).disabled(state.projects?.busy == true)
            }
        }.background(JarasTheme.line)
            .overlay(alignment: .topLeading) {
                if navigationOpen {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture { navigationOpen = false }
                        SidebarView(close: { navigationOpen = false }, openProjects: { projectsOpen = true }, exit: exitRemote)
                            .frame(width: 210).frame(maxHeight: .infinity)
                            .shadow(color: .black.opacity(0.3), radius: 10, x: 4)
                    }
                }
            }
            .sheet(isPresented: $projectsOpen) {
                NativeRemoteProjectsView(state: state, computerName: computerName,
                    open: { action(.openRecentProject, target: $0) }, close: { projectsOpen = false })
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
    private var setlistWithSections: some View {
        SectionListDock(visible: sectionsOpen && verticalSections, storageKey: "catlive.remote.sections.width") {
            setlist
        } sections: { remoteSections }
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
    private var projectFooterText: String {
        let iso = ISO8601DateFormatter()
        let timestamp = state.projectSavedAt ?? ""
        var date = iso.date(from: timestamp)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: timestamp)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return "Sessão - " + state.projectName + " - " + (date.map { formatter.string(from: $0) } ?? "—")
    }
    private var footer: some View {
        let displays = state.songDisplays
        let total = displays?.playlistSeconds ?? state.regions.filter { $0.parentRegion == nil }.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let seconds = Int(min(Double(Int.max / 2), max(0, total)))
        return HStack(spacing: 10) {
            if sidebarHidden { restoreSidebarButton() }
            ResourceUsageView(memoryScope: .device)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
        }.frame(width: 10).contentShape(Rectangle())
            // The divider moves as the panel grows. Local coordinates would
            // change the translation again during layout, feeding the width
            // update back into the gesture even with a stationary finger.
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { changed(Double($0.translation.width)) }.onEnded { _ in ended() })
            .accessibilityLabel(label)
    }
    private var masterStrip: some View {
        VStack(spacing: 2) {
                HStack(spacing: 4) {
                    RemotePeakReadout(decibels: state.masterPeakDB, name: "Master", project: state.project, song: state.song, target: nil, nameColor: state.masterNameColor ?? 0xffffff, reset: { action(.resetMeterPeak) }).equatable()
                    Button { action(.masterMono) } label: {
                        Text(state.masterMono ? "Mono" : "Stereo")
                            .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).frame(height: 24)
                            .foregroundStyle(state.masterMono ? JarasTheme.green : JarasTheme.text)
                            .modifier(RemoteControlSurface(radius: 3))
                    }.buttonStyle(RemoteFullAreaButtonStyle())
                    Spacer(minLength: 0)
                    Button { action(.mute) } label: { Text(verbatim: "M") }
                        .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterMute ? .red : nil))
                    Button { action(.solo) } label: { Text(verbatim: "S") }
                        .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: state.masterSolo ? JarasTheme.yellow : nil))
                }.frame(height: 24)
                Text(verbatim: "Master").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(remoteColor(state.masterNameColor ?? 0xffffff))
                    .frame(maxWidth: .infinity)
                HStack(spacing: 3) {
                    Text(remoteDecibelText(state.masterVolume)).font(.system(size: 10, weight: .semibold, design: .monospaced)).frame(width: 36, alignment: .leading)
                        .contentShape(Rectangle()).onTapGesture(count: 2) { action(.volume, value: 1) }
                    RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(state.masterVolume), range: -60...12, height: 20) { action(.volume, value: DAWRemoteFaderScale.gain($0)) }
                        .accessibilityLabel("Master volume")
                }
            }.padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .frame(height: RemoteNativeGridMetrics.rulerAreaHeight)
                .background(remoteColor(state.masterColor ?? 0x414141).opacity(0.5)).cornerRadius(6)
    }
    private var transportBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    topPrompterButton(.first, title: "TP1")
                    topPrompterButton(.second, title: "TP2")
                }.frame(height: 25)
                RemoteNativeTimerView(timer: timer, send: {
                    guard state.timer != nil else { return }
                    send(.init(id: $2, project: state.project, song: state.song, action: $0, value: $1))
                }, close: {}, compact: true)
            }.frame(width: 176)
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            SongNameDisplay(title: state.playing ? "Now playing" : "Selected song",
                                name: state.songDisplays?.current ?? selectedTimelineRegion?.name ?? state.songName,
                                bpm: state.songDisplays?.currentBPM, color: state.playing ? JarasTheme.green : JarasTheme.text)
                                .frame(width: max(0, (geometry.size.width - 1) * 0.75)).accessibilityLabel("Current song")
                            Rectangle().fill(JarasTheme.line).frame(width: 1)
                            TransportInformationMessage(message: state.loop ? "Loop Ativo" : state.footerInformation ?? "",
                                beatPhase: state.loop ? state.footerLoopBeatPhase : nil, steady: !state.loop)
                                .font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: max(0, (geometry.size.width - 1) * 0.25), height: 25).clipped()
                                .accessibilityLabel("Information")
                        }
                    }.frame(height: 25).background(RemoteSurface.display).cornerRadius(5)
                    Text(verbatim: timeText).monospacedDigit().frame(width: 82, height: 25)
                        .background(RemoteSurface.display).cornerRadius(5).accessibilityLabel("Tempo da agulha")
                }.font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Button { action(state.playing || state.paused ? .stop : .play) } label: {
                        Label(state.playing || state.paused ? "Stop" : "Play", systemImage: state.playing || state.paused ? "stop.fill" : "play.fill")
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: state.playing, fontSize: 12, width: 72, height: 28))
                    Button { action(state.paused ? .play : .pause) } label: {
                        Label(state.paused ? "Play" : "Pause", systemImage: state.paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(TransportButtonStyle(color: JarasTheme.yellow, active: state.paused, fontSize: 12, width: 72, height: 28))
                        .disabled(!state.playing && !state.paused)
                    smallButton("Sub Play", active: state.subPlaying) { action(state.subPlaying ? .subStop : .subPlay) }.disabled(!state.playing)
                    Button { action(.toggleLoop) } label: {
                        Label("Repeat", systemImage: "repeat")
                    }.buttonStyle(TransportButtonStyle(color: state.loop ? JarasTheme.yellow : .red, active: state.loop, fontSize: 12, width: 72, height: 28))
                        .modifier(JarasBlink(active: state.loop, interval: 0.55, lowOpacity: 0.45))
                    bpmControl
                    tunerControl
                }
            }.frame(maxWidth: .infinity)
            VStack(spacing: 5) {
            Button { confirmSave = true } label: {
                Label(state.saving ? "Salvando…" : state.pendingSave ? "Save" : "Salvo", systemImage: state.pendingSave ? "square.and.arrow.down" : "checkmark")
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: 72, height: 28)
                    .foregroundStyle(state.pendingSave ? JarasTheme.green : JarasTheme.secondary)
                    .modifier(RemoteControlSurface(color: state.pendingSave ? JarasTheme.green.opacity(0.16) : nil))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(state.pendingSave ? JarasTheme.green.opacity(0.7) : JarasTheme.line))
            }.buttonStyle(RemoteFullAreaButtonStyle()).disabled(!state.pendingSave || state.saving)
                Button {
                    guard let parent = drawerRegion?.id else { return }
                    toggleDrawer(parent)
                } label: {
                    Image(systemName: drawerExpanded ? "chevron.up" : "chevron.down")
                }.buttonStyle(TransportButtonStyle(color: JarasTheme.panel, fontSize: 13, width: 72, height: 28))
                    .foregroundStyle(JarasTheme.green).disabled(drawerRegion == nil)
                    .opacity(drawerRegion == nil ? 0.45 : 1)
                    .accessibilityLabel(drawerExpanded ? "Fechar gaveta da região selecionada" : "Abrir gaveta da região selecionada")
                    .accessibilityValue(drawerExpanded ? "Expanded" : "Collapsed")
            }
        }.padding(6).frame(height: 82, alignment: .top).background(RemoteSurface.panel)
    }
    private func topPrompterButton(_ panel: PrompterPanel, title: String) -> some View {
        Button { showPrompter(prompterPanel == panel ? nil : panel) } label: {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 25)
                .modifier(RemoteControlSurface(radius: 5))
        }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(prompterPanel == panel ? JarasTheme.green : Color(hex: 0xff5555))
            .accessibilityLabel("Teleprompter \(panel.rawValue), controles superiores")
            .accessibilityValue(prompterPanel == panel ? "On" : "Off")
    }
    private var tunerControl: some View {
                HStack(spacing: 6) {
                    Button { action(.pitch, target: state.pitchRegion, value: Double((state.pitchSemitones ?? 0) - 1)) } label: { Image(systemName: "minus").frame(width: 28, height: 32) }
                        .disabled(state.pitchRegion == nil || (state.pitchSemitones ?? 0) <= -12)
                    VStack(spacing: 0) {
                        Text(verbatim: "Tuner").font(.system(size: 10))
                        Text(String(format: "%+dst", state.pitchSemitones ?? 0)).monospacedDigit()
                    }.frame(minWidth: 70, maxWidth: .infinity)
                    Button { action(.pitch, target: state.pitchRegion, value: Double((state.pitchSemitones ?? 0) + 1)) } label: { Image(systemName: "plus").frame(width: 28, height: 32) }
                        .disabled(state.pitchRegion == nil || (state.pitchSemitones ?? 0) >= 12)
                }.font(.system(size: 14, weight: .semibold)).buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.green)
                .padding(.horizontal, 4).frame(minWidth: 134, maxWidth: .infinity, minHeight: 32).background(RemoteSurface.display).cornerRadius(5)
    }
    private var bpmControl: some View {
        HStack(spacing: 2) {
            Button { action(.tempo, value: max(60, state.bpm - 1)) } label: {
                Image(systemName: "minus").frame(width: 28, height: 32)
            }.accessibilityLabel("Diminuir BPM")
            Text(String(format: "%.0f BPM", state.bpm)).monospacedDigit().frame(minWidth: 70, maxWidth: .infinity)
            Button { action(.tempo, value: min(300, state.bpm + 1)) } label: {
                Image(systemName: "plus").frame(width: 28, height: 32)
            }.accessibilityLabel("Aumentar BPM")
        }.font(.system(size: 14, weight: .semibold)).buttonStyle(RemoteFullAreaButtonStyle())
            .frame(minWidth: 134, maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(JarasTheme.green).background(RemoteSurface.display).cornerRadius(5)
    }
    private var timeText: String {
        let seconds = max(0, Int(displayedPosition))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func smallButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }
            .buttonStyle(TransportButtonStyle(color: JarasTheme.green, active: active, fontSize: 12, width: 72, height: 28))
    }
    private var trackMixer: some View {
        VStack(spacing: 1) {
            // Match the grid's region, marker and time lanes so both lists
            // start at the same screen Y and have identical scroll limits.
            masterStrip
            HStack(spacing: 1) {
                RemoteTrackScrollRail(controller: trackScrolling).frame(width: 28)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { number, track in
                            RemoteNativeMixerRow(track: track, project: state.project, song: state.song, number: number + 1, compact: DAWRemoteItemLayout.rowHeight(track, scale: trackScrolling.heightScale) < 70) { command, value in
                                action(command, target: track.id, value: value)
                            }.equatable().frame(height: DAWRemoteItemLayout.rowHeight(track, scale: trackScrolling.heightScale))
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: trackScrolling))
                    #endif
                }.background(RemoteSurface.background)
            }
        }
    }
    private var setlist: some View {
        let played = Set(state.playedLiveRegionIDs ?? [])
        return VStack(spacing: 8) {
            Button { searchFocused = false; playlistPickerOpen = true } label: {
                HStack(spacing: 8) {
                    if let playlist = state.playlists?.first(where: { $0.id == state.selectedPlaylist }) {
                        Text(verbatim: playlist.name).lineLimit(1)
                    } else { Text("All regions").lineLimit(1) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }.font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.text)
                    .padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: 30)
                    .background(RemoteSurface.panel)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.45)))
                    .contentShape(Rectangle())
            }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Selecionar playlist")
                .popover(isPresented: $playlistPickerOpen, arrowEdge: .top) {
                    RemoteNativePlaylistPicker(playlists: state.playlists ?? [], selected: state.selectedPlaylist,
                        choose: { id in action(.selectPlaylist, target: id); playlistPickerOpen = false },
                        close: { playlistPickerOpen = false }).equatable()
                }
            HStack(spacing: 6) {
                TextField("Pesquisar músicas", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                Button { action(.toggleRegionAuto) } label: {
                    Text(verbatim: "AUTO").font(.system(size: 9, weight: .bold)).frame(width: 34, height: 26)
                        .foregroundStyle(state.regionAuto == true ? Color.black : JarasTheme.secondary)
                        .modifier(RemoteControlSurface(color: state.regionAuto == true ? JarasTheme.green : nil, radius: 4))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("AUTO").accessibilityValue(state.regionAuto == true ? "On" : "Off")
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if state.regions.isEmpty {
                            ForEach(state.songs.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { song in
                                Button { action(.selectSong, target: song.id) } label: {
                                    setlistLabel(song.name, selected: song.id == state.song, active: state.playing && song.id == state.song, queued: false, color: JarasTheme.panel)
                                }.buttonStyle(RemoteFullAreaButtonStyle())
                            }
                        } else {
                            ForEach(setlistRowsCache.rows(in: state, expanded: expandedRegions, query: search)) { row in
                                let region = row.region
                                Button { action(.selectRegion, target: region.id) } label: {
                                    setlistLabel(region.name, number: row.number, played: played.contains(region.id), selected: region.id == state.focusedRegion,
                                        active: state.playing && region.id == state.currentRegion, queued: state.playing && region.id == state.queuedRegion,
                                        color: remoteColor(region.color), nameColor: remoteColor(region.nameColor ?? (row.child ? 0xffeb3b : 0xffffff)),
                                        duration: max(0, Int(ceil(region.end - (state.playing && region.id == state.currentRegion ? state.position : region.start)))),
                                        progress: min(1, max(0, (state.position - region.start) / max(0.001, region.end - region.start))),
                                        queueProgress: min(1, max(0, ((state.playbackEnd ?? state.position) - state.position) / max(0.001, (state.playbackEnd ?? state.position) - (state.queueStartedAt ?? state.position)))))
                                }.buttonStyle(RemoteFullAreaButtonStyle())
                                    .modifier(RemoteRegionDrawerGesture(enabled: row.hasDrawer, toggle: { toggleDrawer(region.id) }))
                                    .padding(.leading, row.child ? 20 : 0).id(row.id)
                            }
                        }
                    }
                }.onChange(of: expandedRegions) { expanded in
                    if let parent = drawerRegion?.id, expanded.contains(parent) {
                        withAnimation(.easeOut(duration: 0.16)) { scroll.scrollTo(parent, anchor: .top) }
                    }
                }
            }
            if UIDevice.current.userInterfaceIdiom != .phone { setlistControls }
        }.padding([.top, .leading, .trailing], 10).background(RemoteSurface.background)
    }
    private func setlistLabel(_ title: String, number: Int? = nil, played: Bool = false, selected: Bool = false, active: Bool, queued: Bool, color: Color, nameColor: Color = JarasTheme.text, duration: Int? = nil, progress: Double = 0, queueProgress: Double = 0) -> some View {
        RemoteSetlistRowLabel(title: title, number: number, played: played, selected: selected,
            active: active, queued: queued, color: color, nameColor: nameColor, duration: duration,
            progress: active ? progress : 0, queueProgress: queued ? queueProgress : 0,
            fontStyle: state.setlistFontStyle ?? 0, prepareOnly: state.prepareOnly == true).equatable()
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
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(active ? Color.red : queued ? (prepareOnly ? JarasTheme.green : .orange) : color).frame(width: 3)
            if let number { Text(String(format: "%02d", number)).font(.system(size: 10, design: .monospaced)).foregroundStyle(JarasTheme.secondary) }
            Text(verbatim: title)
                .font(fontStyle == 2 ? .system(size: 13, weight: .bold).italic() : .system(size: 13, weight: fontStyle == 0 ? .regular : .bold))
                .foregroundStyle(nameColor).strikethrough(played, color: nameColor).lineLimit(2)
            Spacer(minLength: 0)
            if let duration { Text(String(format: "%dm %02ds", duration / 60, duration % 60)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(JarasTheme.text) }
            if active { Image(systemName: "play.fill").foregroundStyle(JarasTheme.green) }
            if queued { Image(systemName: "arrow.right").foregroundStyle(JarasTheme.yellow) }
        }.padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 38)
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
private struct NativeRemoteSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Configurações", systemImage: "gearshape").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Close")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Language").font(.subheadline.weight(.semibold))
                Picker("Language", selection: $language) {
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Português").tag("pt-BR")
                }.pickerStyle(.segmented).labelsHidden()
            }
        }.padding(20).frame(width: 320).background(RemoteSurface.panel).foregroundStyle(JarasTheme.text)
            .environment(\.locale, Locale(identifier: language))
    }
}

/// The center grid renders native clip geometry from the Mac state.
private enum RemoteNativeGridMetrics {
    static let regionHeight: CGFloat = 24
    static let markerHeight: CGFloat = 20
    static let timeHeight: CGFloat = 28
    static let rulerAreaHeight = regionHeight + markerHeight + timeHeight + 2
}
private struct RemoteNativeTimeline: View {
    @Environment(\.displayScale) private var displayScale
    let state: DAWRemoteState
    let tracks: [DAWRemoteState.Track]
    @ObservedObject var scrolling: RemoteTrackScrollController
    let region: DAWRemoteState.Region?
    let position: Double
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    let preview: (Double) -> Void
    let seek: (Double) -> Void
    private var start: Double { region?.start ?? 0 }
    private var end: Double { region?.end ?? start }
    private var span: Double { max(0.001, end - start) }
    private var visibleMarkers: [TimelineMarker] {
        (state.markers ?? []).filter { $0.position >= start && $0.position <= end }
            .map { TimelineMarker(id: $0.id, name: $0.name, position: $0.position, color: $0.color,
                unifiedRegionID: $0.unifiedRegionID, sourceRegionID: $0.sourceRegionID, section: $0.section) }
            .sorted { $0.position < $1.position }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let marks = gridMarks(width: width)
            VStack(spacing: 1) {
                regionLane(width: width)
                markerLane(width: width)
                ruler(width: width, marks: marks)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(tracks) { track in
                            timelineRow(track, width: width, marks: marks).frame(height: DAWRemoteItemLayout.rowHeight(track, scale: scrolling.heightScale))
                        }
                    }
                    #if os(iOS)
                    .background(RemoteTrackScrollProbe(controller: scrolling, isGrid: true, gridTap: { fraction in
                        guard !state.playing, region != nil else { return }
                        seek(start + fraction * span)
                    }))
                    #endif
                }
            }.overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for marker in visibleMarkers {
                            let x = (marker.position - start) / span * size.width
                            var stem = Path()
                            stem.move(to: CGPoint(x: x, y: RemoteNativeGridMetrics.regionHeight + RemoteNativeGridMetrics.markerHeight + 1))
                            stem.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(stem, with: .color(remoteColor(marker.color).opacity(marker.unifiedRegionID != nil || marker.sourceRegionID != nil ? 1 : 0.45)), lineWidth: 1)
                        }
                    }
                    // Needles stay above coincident marker stems, as on the Mac.
                    cursor(width: width)
                        .padding(.top, RemoteNativeGridMetrics.rulerAreaHeight + 1)
                }.clipped().allowsHitTesting(false)
            }
        }.background(remoteColor(state.gridBackgroundColor ?? UInt32(TimelineAppearanceDefaults.background)))
    }
    private func gridMarks(width: CGFloat) -> [TimelineTimeRuler.Tick] {
        let sections = (state.gridTempo ?? []).map {
            TimelineTempoSection(start: $0.start, end: $0.end, bpm: $0.bpm, beats: $0.beats, unit: $0.unit, timebase: .free)
        }
        return TimelineTimeRuler.ticks(in: sections, from: start, to: end,
                                       pixelsPerSecond: width / span, divisions: state.gridDivisions ?? 4)
    }
    private func gridX(_ time: Double, width: CGFloat) -> CGFloat {
        floor((time - start) / span * width * displayScale) / displayScale + 0.5 / displayScale
    }
    private func ruler(width: CGFloat, marks: [TimelineTimeRuler.Tick]) -> some View {
        ZStack(alignment: .leading) {
            JarasTheme.display
            Canvas { context, size in
                for mark in marks {
                    let x = gridX(mark.time, width: size.width)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: mark.primary ? 20 : 24))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(TimelineStaticText.rulerColor), lineWidth: 1 / displayScale)
                    if !mark.label.isEmpty {
                        TimelineStaticText.label(mark.label, style: .barNumber, displayScale: displayScale)?
                            .draw(at: CGPoint(x: x + 3, y: 5), context: &context)
                    }
                }
            }
        }.frame(height: RemoteNativeGridMetrics.timeHeight).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard !state.playing, region != nil else { return }
                    preview(start + min(1, max(0, gesture.location.x / width)) * span)
                }
                .onEnded { gesture in
                    guard !state.playing, region != nil else { return }
                    seek(start + min(1, max(0, gesture.location.x / width)) * span)
                })
            .accessibilityLabel("Régua de tempo: arraste com o transporte parado")
    }
    private func regionLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            JarasTheme.display
            if let region {
                HStack {
                    Text(verbatim: region.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                }.foregroundStyle(remoteColor(region.nameColor ?? 0xffffff)).padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(remoteColor(region.color).opacity(0.6))
            }
        }.frame(height: RemoteNativeGridMetrics.regionHeight).clipped().accessibilityLabel("Faixa da região " + (region?.name ?? ""))
    }
    private func markerLane(width: CGFloat) -> some View {
        let markers = visibleMarkers
        return ZStack(alignment: .leading) {
            JarasTheme.display
            Canvas { context, size in
                let widths = Dictionary(uniqueKeysWithValues: markers.map { marker in
                    (marker.id, Double(context.resolve(Text(verbatim: marker.name).font(.system(size: 9, weight: .semibold)))
                        .measure(in: CGSize(width: .infinity, height: size.height)).width))
                })
                let ends = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, end) })
                let flags = TimelineMarker.flagWidths(markers, scale: size.width / span, widths: widths, regionEnds: ends)
                for marker in markers {
                    guard let flagWidth = flags[marker.id] else { continue }
                    let x = (marker.position - start) / span * size.width
                    let rect = CGRect(x: x, y: 1, width: flagWidth, height: size.height - 2)
                    drawMarkerFlag(marker, rect: rect, context: &context)
                    context.draw(Text(verbatim: marker.name).font(.system(size: 9, weight: .semibold)).foregroundColor(.black),
                        in: rect.insetBy(dx: marker.isSection ? 7 : 3, dy: 2))
                }
            }
        }.frame(height: RemoteNativeGridMetrics.markerHeight).clipped().accessibilityLabel("Marcadores da música")
    }
    private func cursor(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            needle(state.playing ? state.editPosition : position,
                   color: state.editCursorColor ?? UInt32(TimelineAppearanceDefaults.editCursor), width: width)
            if state.playing {
                needle(position, color: state.playCursorColor ?? UInt32(TimelineAppearanceDefaults.playCursor), width: width, glowing: true)
            }
            if state.subPlaying {
                needle(state.subPlayPosition ?? state.sectionPlayback?.secondaryPosition, color: state.subPlayCursorColor ?? UInt32(TimelineAppearanceDefaults.subPlayCursor), width: width, glowing: true)
            }
        }.frame(width: width, alignment: .leading).frame(maxHeight: .infinity)
            .clipped().allowsHitTesting(false)
    }
    @ViewBuilder private func needle(_ time: Double?, color: UInt32, width: CGFloat, glowing: Bool = false) -> some View {
        if let time, time >= start, time <= end {
            let x = min(width - (glowing ? 3 : 2), max(0, (time - start) / span * width))
            let displayColor = remoteColor(color)
            ZStack(alignment: .topLeading) {
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
    private func timelineRow(_ track: DAWRemoteState.Track, width: CGFloat, marks: [TimelineTimeRuler.Tick]) -> some View {
        RemoteTimelineTrackRow(track: track, width: width, marks: marks, displayScale: displayScale,
            start: start, end: end, hasRegion: region != nil, heightScale: scrolling.heightScale,
            backgroundColor: state.gridBackgroundColor ?? UInt32(TimelineAppearanceDefaults.background),
            primaryColor: state.gridPrimaryColor ?? UInt32(TimelineAppearanceDefaults.primaryGrid),
            secondaryColor: state.gridSecondaryColor ?? UInt32(TimelineAppearanceDefaults.secondaryGrid),
            gridLines: state.gridLines != false, project: state.project, song: state.song,
            scrolling: scrolling, control: control).equatable()
    }

}

/// Clip drawing is independent of the playhead. The needle can advance without
/// rebuilding paths, fake waveforms or item touch targets in every visible row.
private struct RemoteTimelineTrackRow: View, Equatable {
    let track: DAWRemoteState.Track
    let width: CGFloat
    let marks: [TimelineTimeRuler.Tick]
    let displayScale: CGFloat
    let start: Double
    let end: Double
    let hasRegion: Bool
    let heightScale: Double
    let backgroundColor: UInt32
    let primaryColor: UInt32
    let secondaryColor: UInt32
    let gridLines: Bool
    let project: UUID
    let song: UUID?
    let scrolling: RemoteTrackScrollController
    let control: (DAWRemoteCommand.Action, UUID, Double) -> Void
    private var span: Double { max(0.001, end - start) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.song == rhs.song && lhs.scrolling === rhs.scrolling &&
            lhs.track.id == rhs.track.id && lhs.track.name == rhs.track.name && lhs.track.color == rhs.track.color &&
            lhs.track.nameColor == rhs.track.nameColor && lhs.track.clips == rhs.track.clips &&
            lhs.track.laneCount == rhs.track.laneCount && lhs.track.heightScale == rhs.track.heightScale &&
            lhs.width == rhs.width && lhs.displayScale == rhs.displayScale && lhs.heightScale == rhs.heightScale &&
            lhs.start == rhs.start && lhs.end == rhs.end && lhs.hasRegion == rhs.hasRegion &&
            lhs.backgroundColor == rhs.backgroundColor && lhs.primaryColor == rhs.primaryColor &&
            lhs.secondaryColor == rhs.secondaryColor && lhs.gridLines == rhs.gridLines &&
            lhs.marks.elementsEqual(rhs.marks) { $0.time == $1.time && $0.primary == $1.primary }
    }
    private func gridX(_ time: Double, width: CGFloat) -> CGFloat {
        floor((time - start) / span * width * displayScale) / displayScale + 0.5 / displayScale
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            remoteColor(backgroundColor)
            Canvas { context, size in
                if gridLines {
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
            ForEach(track.clips.filter { hasRegion && $0.start < end && $0.start + $0.duration > start }) { clip in
                let left = max(start, clip.start), right = min(end, clip.start + clip.duration)
                let itemWidth = max(1, (right - left) / span * width)
                RemoteNativeGridItem(clip: clip, color: track.color, nameColor: track.nameColor ?? 0xffffff,
                    scrolling: scrolling,
                    sourceFraction: (left - clip.start) / max(0.001, clip.duration),
                    visibleFraction: (right - left) / max(0.001, clip.duration),
                    mute: { control(.clipMute, clip.id, 0) },
                    setGain: { control(.clipGain, clip.id, $0) })
                    .frame(width: itemWidth, height: DAWRemoteItemLayout.laneHeight(track, scale: heightScale))
                    .offset(x: (left - start) / span * width, y: Double(clip.lane ?? 0) * DAWRemoteItemLayout.laneHeight(track, scale: heightScale))
            }
        }.frame(width: width, alignment: .leading).clipped().accessibilityLabel(track.name + ", clipes")
    }}
private struct RemoteNativeGridItem: View {
    let clip: DAWRemoteState.Clip
    let color: UInt32
    let nameColor: UInt32
    let scrolling: RemoteTrackScrollController
    let sourceFraction: Double
    let visibleFraction: Double
    let mute: () -> Void
    let setGain: (Double) -> Void
    @Environment(\.isEnabled) private var controlsEnabled
    @State private var editorOpen = false
    var body: some View {
        GeometryReader { geometry in
        let headerHeight = min(28 * GridSelectionItem.headerScale, geometry.size.height)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: mute) { Text(verbatim: "M").font(.system(size: 11 * GridSelectionItem.headerScale, weight: .bold)).frame(width: 28 * GridSelectionItem.headerScale, height: headerHeight) }
                    .buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(clip.muted == true ? Color.black : Color.white)
                    .background(clip.muted == true ? Color.red : Color.black.opacity(0.28)).cornerRadius(2)
                    .accessibilityLabel("Mute do item " + clip.name)
                Text(verbatim: clip.name).font(.system(size: 10 * GridSelectionItem.headerScale, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(remoteColor(nameColor)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 3).frame(height: headerHeight)
            Canvas { context, size in
                var wave = Path()
                let seed = clip.id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % 997 }
                let count = max(1, Int(size.width / 3))
                for index in 0..<count {
                    let phase = (sourceFraction + Double(index) / Double(count) * visibleFraction) * 300 + Double(seed)
                    let amplitude = 0.12 + 0.78 * abs(sin(phase * 0.37) * cos(phase * 0.13))
                    let height = size.height * amplitude
                    wave.addRect(CGRect(x: CGFloat(index) * 3, y: (size.height - height) / 2, width: 1.5, height: height))
                }
                context.fill(wave, with: .color(clip.muted == true ? .gray : remoteColor(nameColor).opacity(0.75)))
            }.frame(height: max(0, geometry.size.height - headerHeight)).allowsHitTesting(false)
        }
        }.background(remoteColor(color).opacity(clip.muted == true ? 0.25 : 0.60)).cornerRadius(3)
            .background(RemoteGridItemHoldProbe(controller: scrolling, hold: { editorOpen = true }))
            .popover(isPresented: $editorOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                RemoteNativeItemEditor(clip: clip, color: color, setGain: setGain, mute: mute, close: { editorOpen = false })
                    .preferredColorScheme(.dark)
            }
            .onChange(of: controlsEnabled) { if !$0 { editorOpen = false } }
            .accessibilityLabel(clip.name).accessibilityAction(named: "Editar item") { editorOpen = true }
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
    private var decibels: Double { clip.gain == 0 ? -60 : min(24, max(-59.9, 20 * log10(max(0.000001, clip.gain ?? 1)))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(remoteColor(color)).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Item volume").font(.system(size: 10, weight: .medium)).foregroundStyle(JarasTheme.secondary)
                    Text(verbatim: clip.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28).background(RemoteSurface.display).cornerRadius(5)
                }.buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Close")
            }
            HStack(spacing: 10) {
                Text(verbatim: (clip.gain == 0 ? "−∞" : String(format: "%+.1f", decibels)) + " dB")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(JarasTheme.green).frame(width: 67, height: 34)
                    .background(RemoteSurface.display).cornerRadius(5)
                RemoteNativeSlider(value: decibels, range: -60...24, height: 36) {
                    setGain($0 <= -60 ? 0 : pow(10, $0 / 20))
                }.accessibilityLabel("Volume do item " + clip.name)
                Button(action: mute) {
                    Text(verbatim: "M").font(.system(size: 13, weight: .bold)).frame(width: 38, height: 34)
                        .foregroundStyle(clip.muted == true ? Color.white : JarasTheme.text)
                        .modifier(RemoteControlSurface(color: clip.muted == true ? Color.red.opacity(0.8) : nil, radius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(clip.muted == true ? Color.red : JarasTheme.line))
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Mute do item " + clip.name)
            }
        }.padding(14).frame(width: 330).fixedSize(horizontal: false, vertical: true)
            .background(RemoteSurface.panel).foregroundStyle(JarasTheme.text)
    }
}
private func remoteColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
}
/// Native rectangular fader with desktop travel and a local thumb during touch.
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(activeColor == nil ? Color.white : Color.black)
            .frame(width: 26, height: 22)
            .modifier(RemoteControlSurface(color: activeColor?.opacity(configuration.isPressed ? 0.75 : 1), radius: 3))
            .frame(width: 32, height: 28).contentShape(Rectangle())
    }
}
/// Keep the presented scroll view independent of transport/position snapshots.
/// Stable playlist IDs retain its scroll position while the bridge updates.
private struct RemoteNativePlaylistPicker: View, Equatable {
    let playlists: [DAWRemoteState.Song]
    let selected: UUID?
    let choose: (UUID?) -> Void
    let close: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.playlists == rhs.playlists && lhs.selected == rhs.selected }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet").foregroundStyle(JarasTheme.green)
                Text(verbatim: "Playlists").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30) }
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
                Text(verbatim: name).font(.system(size: 14, weight: id == selected ? .semibold : .medium))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if id == selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(JarasTheme.green) }
            }.padding(.horizontal, 12).frame(height: 42)
                .background(RemoteSurface.fill(id == selected ? JarasTheme.green.opacity(0.10) : JarasTheme.panel))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(id == selected ? JarasTheme.green.opacity(0.5) : JarasTheme.line))
        }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityAddTraits(id == selected ? .isSelected : [])
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
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(remoteColor(nameColor))
                .frame(width: 34, height: 12)
                .frame(height: 22).contentShape(Rectangle())
        }.buttonStyle(RemoteFullAreaButtonStyle()).disabled(decibels == nil)
            .accessibilityLabel(Text(verbatim: "Peak · " + name))
            .accessibilityValue(Text(verbatim: decibels.map { String(format: "%+.2f dB", $0) } ?? "—"))
            .accessibilityHint("Reset peak")
    }
}

private struct RemoteNativeMixerRow: View, Equatable {
    let track: DAWRemoteState.Track
    let project: UUID
    let song: UUID?
    let number: Int
    var compact = false
    let send: (DAWRemoteCommand.Action, Double) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.project == rhs.project && lhs.song == rhs.song && lhs.number == rhs.number &&
            lhs.compact == rhs.compact && lhs.track.hasSameMixerControls(as: rhs.track)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if track.canMeter != false {
                    RemotePeakReadout(decibels: track.peakDB, name: track.name, project: project, song: song, target: track.id, nameColor: track.nameColor ?? 0xffffff, reset: { send(.resetMeterPeak, 0) }).equatable()
                }
                if compact {
                    Text(String(format: "%02d  %@", number, track.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(remoteColor(track.nameColor ?? 0xffffff)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                Spacer(minLength: 0)
                Text(verbatim: "Pan").font(.system(size: 10, weight: .semibold)).foregroundStyle(JarasTheme.text)
                RemoteNativeSlider(value: track.pan, range: -1...1) { send(.pan, $0) }.frame(minWidth: 12, maxWidth: 60)
                    .accessibilityLabel("Pan " + track.name)
                }
                Button { send(.mute, 0) } label: { Text(verbatim: "M") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.mute ? .red : nil))
                Button { send(.solo, 0) } label: { Text(verbatim: "S") }
                    .buttonStyle(RemoteNativeTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
            }
            if !compact {
            HStack(spacing: 3) {
                Text(remoteDecibelText(track.volume)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(JarasTheme.text).frame(width: 36, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture(count: 2) { send(.volume, 1) }
                RemoteNativeSlider(value: DAWRemoteFaderScale.decibels(track.volume), range: -60...12, height: 22, linked: track.linkedTrack != nil) { send(.volume, DAWRemoteFaderScale.gain($0)) }
                    .accessibilityLabel("Volume " + track.name)
            }.frame(height: 23)
            Text(String(format: "%02d  %@", number, track.name)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .foregroundStyle(remoteColor(track.nameColor ?? 0xffffff)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background {
                let components = TrackNameContrast.components(track.color, emphasized: track.emphasized == true)
                Color(red: components.red, green: components.green, blue: components.blue)
                    .opacity(track.emphasized == true ? 0.65 : 0.50).saturation(track.silenced == true ? 0 : 1)
            }.background(JarasTheme.mixer)
            .overlay(Rectangle().stroke(track.emphasized == true ? Color.white.opacity(0.65) : .clear, lineWidth: 1))
    }
}

@MainActor private struct NativeRemoteProjectsView: View {
    let state: DAWRemoteState
    let computerName: String
    let open: (UUID) -> Void
    let close: () -> Void
    @State private var requested: UUID?
    private var browser: DAWRemoteState.ProjectBrowser? { state.projects }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent projects").font(.title2.bold())
                    Label { Text(verbatim: computerName) } icon: { Image(systemName: "desktopcomputer") }
                        .font(.subheadline).foregroundStyle(JarasTheme.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                        .background(RemoteSurface.panel).clipShape(Circle())
                }.buttonStyle(RemoteFullAreaButtonStyle()).accessibilityLabel("Close")
            }
            Text("Choose a project to open on the PC.").font(.callout).foregroundStyle(JarasTheme.secondary)
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
                                        Image(systemName: "doc.text").font(.system(size: 22)).foregroundStyle(JarasTheme.green)
                                        Text(verbatim: project.name).font(.body.weight(.semibold)).lineLimit(2)
                                        Spacer()
                                        if project.current {
                                            Text("Open").font(.caption.weight(.semibold)).foregroundStyle(JarasTheme.green)
                                        } else if requested == project.id && browser.busy {
                                            ProgressView().tint(JarasTheme.green)
                                        } else {
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(JarasTheme.secondary)
                                        }
                                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RemoteSurface.panel).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(project.current ? JarasTheme.green.opacity(0.45) : JarasTheme.line))
                                }.buttonStyle(RemoteFullAreaButtonStyle()).disabled(project.current || !browser.canOpen)
                            }
                        }
                    }
                }
                if !browser.status.isEmpty {
                    HStack(spacing: 10) {
                        if browser.busy { ProgressView().tint(JarasTheme.green) }
                        Text(LocalizedStringKey(browser.status)).font(.callout).foregroundStyle(JarasTheme.secondary)
                    }
                }
                if !browser.error.isEmpty {
                    Text(LocalizedStringKey(browser.error)).font(.callout).foregroundStyle(JarasTheme.yellow)
                }
            } else {
                Text("Update CatLive on the PC to browse recent projects.").font(.callout).foregroundStyle(JarasTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RemoteSurface.background).foregroundStyle(JarasTheme.text)
            .onChange(of: browser?.recent.first(where: { $0.current })?.id) { current in
                if let requested, current == requested { close() }
            }
    }
}

@MainActor private final class RemoteTrackScrollController: NSObject, ObservableObject {
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
        let x = gesture.location(in: scroll).x - scroll.bounds.minX
        gridTap?(min(1, max(0, Double(x / scroll.bounds.width))))
    }
    private func receiveGridTap(_ touch: UITouch) -> Bool {
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
        }.font(.system(size: 12, weight: .semibold)).foregroundStyle(JarasTheme.green)
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
    let hold: () -> Void
    func makeUIView(context: Context) -> RemoteGridItemHoldArea {
        let view = RemoteGridItemHoldArea()
        view.isUserInteractionEnabled = false
        view.bind(controller: controller, hold: hold)
        return view
    }
    func updateUIView(_ view: RemoteGridItemHoldArea, context: Context) {
        view.bind(controller: controller, hold: hold)
    }
    static func dismantleUIView(_ view: RemoteGridItemHoldArea, coordinator: ()) { view.unbind() }
}
private final class RemoteGridItemHoldArea: UIView {
    private weak var controller: RemoteTrackScrollController?
    var hold: (() -> Void)?
    func bind(controller: RemoteTrackScrollController, hold: @escaping () -> Void) {
        if self.controller !== controller {
            self.controller?.unregisterHoldArea(self)
            self.controller = controller
            controller.registerHoldArea(self)
        }
        self.hold = hold
    }
    func unbind() {
        controller?.unregisterHoldArea(self)
        controller = nil; hold = nil
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
    @ObservedObject private var remote = DAWRemoteSession.shared
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
    @ObservedObject private var remote = DAWRemoteSession.shared
    private var content: DAWRemoteTeleprompter? { remote.remoteState?.teleprompters?.first { $0.index == index } }
    var body: some View {
        VStack(spacing: 6) {
            if !fullscreen {
            HStack {
                Text("TP-\(index)").font(.system(size: 15, weight: .semibold)).foregroundStyle(JarasTheme.green)
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
                    .font(.callout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Aguardando teleprompter…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded(toggleFullscreen))
                .accessibilityAction(named: Text(fullscreen ? "Sair da tela cheia" : "Tela cheia"), toggleFullscreen)
        }.background(Color.black).foregroundStyle(JarasTheme.text)
            .onAppear { if managesSubscription { subscribe(index) } }
            .onChange(of: index) { if managesSubscription { subscribe($0) } }
            .onDisappear { if managesSubscription { subscribe(0) } }
    }
    private func subscribe(_ panel: Int) {
        guard let state = remote.remoteState else { return }
        remote.send(.init(project: state.project, song: state.song, action: .remotePanel, value: Double(panel)))
    }
    private func projection(_ content: DAWRemoteTeleprompter, state: DAWRemoteState) -> some View {
        TeleprompterProjectionLayout(content: content, fullscreen: fullscreen,
            timerValue: { (timer.displayText().replacingOccurrences(of: ":", with: " : "), timer.displayOpacity(), timer.expired()) },
            media: {
                if let image = content.imageID {
                    RemoteNativeProjectionImage(id: image, project: state.project, stretch: content.resolvedSettings.stretchesMedia)
                }
            })
            .overlay {
                if !content.resolvedSettings.isClear, let notices = state.notices, notices.active && (index == 1 ? notices.window1 : notices.window2) {
                    RemoteNativeNoticeOverlay(notice: notices, project: state.project)
                }
            }
    }
}

private func remoteTPFont(_ name: String, size: CGFloat) -> Font {
    let names = ["arial": "Arial-BoldMT", "verdana": "Verdana-Bold", "tahoma": "Tahoma-Bold", "georgia": "Georgia-Bold", "trebuchet": "TrebuchetMS-Bold", "impact": "Impact", "mono": "CourierNewPS-BoldMT"]
    if let font = names[name], UIFont(name: font, size: size) != nil { return .custom(font, size: size) }
    return .system(size: size, weight: .bold, design: name == "mono" ? .monospaced : .default)
}

private struct RemoteNativeNoticeOverlay: View {
    let notice: DAWRemoteNotices
    let project: UUID
    var body: some View {
        GeometryReader { geometry in
          TimelineView(.periodic(from: .now, by: 0.175)) { context in
            let elapsed = context.date.timeIntervalSince1970 - notice.sentAt
            let flash = elapsed >= 0 && elapsed < 1.05 && Int(elapsed / 0.175) % 2 == 0
            VStack {
                if let image = notice.imageID {
                    RemoteNativeProjectionImage(id: image, project: project)
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
    @ObservedObject private var remote = DAWRemoteSession.shared
    @State private var draft = ""
    @State private var globalDraft = ""
    @State private var slot = -1
    private var notices: DAWRemoteNotices? { remote.remoteState?.notices }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Recados").font(.headline)
                Spacer()
                Button("Fechar", action: close)
            }
            if let notices {
                HStack(spacing: 8) {
                    Button("Enviar") { command(.noticeSend, value: Double(slot), text: draft) }
                        .buttonStyle(.borderedProminent).tint(JarasTheme.green)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (slot < 0 || !notices.imageSlots[slot]))
                    Button("Retirar") { command(.noticeClear) }.buttonStyle(.bordered).disabled(!notices.active)
                    Button { command(.noticePin, value: notices.pinned ? 0 : 1) } label: {
                        Label("Fixar", systemImage: notices.pinned ? "pin.fill" : "pin")
                    }.buttonStyle(.bordered).tint(notices.pinned ? JarasTheme.yellow : JarasTheme.secondary)
                    Spacer(minLength: 0)
                    Text(notices.pinned ? "∞" : "\(notices.remaining)s").monospacedDigit().foregroundStyle(JarasTheme.secondary)
                }.font(.system(size: 13, weight: .semibold))
                Picker("Recado", selection: $slot) {
                    Text("Global").tag(-1)
                    ForEach(0..<3) { Text("Recado \($0 + 1)").tag($0) }
                }.pickerStyle(.segmented).onChange(of: slot) { value in
                    draft = value < 0 ? globalDraft : notices.templates[value]
                }
                TextEditor(text: $draft).font(.system(size: 18)).scrollContentBackground(.hidden)
                    .padding(5).background(RemoteSurface.display).cornerRadius(6)
                    .onChange(of: draft) { value in
                        var bounded = String(value.prefix(500))
                        while bounded.utf8.count > 4000 { bounded.removeLast() }
                        if bounded != value { draft = bounded }
                        if slot < 0 { globalDraft = bounded }
                    }
                HStack {
                    Text("\(draft.count) / 500").font(.caption).foregroundStyle(JarasTheme.secondary)
                    if slot >= 0 && notices.imageSlots[slot] {
                        Label("Imagem salva", systemImage: "photo").font(.caption).foregroundStyle(JarasTheme.secondary)
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
                    .font(.callout).foregroundStyle(JarasTheme.secondary).multilineTextAlignment(.center)
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView("Aguardando recados…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(16).background(RemoteSurface.panel).foregroundStyle(JarasTheme.text)
            .onAppear { if managesSubscription { command(.remotePanel, value: 3) } }
            .onDisappear { if managesSubscription { command(.remotePanel) } }
    }
    private func command(_ action: DAWRemoteCommand.Action, value: Double = 0, text: String? = nil, enabled: Bool? = nil) {
        guard let state = remote.remoteState else { return }
        remote.send(.init(project: state.project, song: state.song, action: action, value: value, text: text, enabled: enabled))
    }
}
#endif

// MARK: - Local Remote timer
/// Static gradients are shared by the Remote controls. No blur, shadow,
/// display-link or per-frame color work is needed for these surfaces.
enum RemoteSurface {
    static let background = LinearGradient(colors: [Color(white: 0.18), Color(white: 0.115)], startPoint: .top, endPoint: .bottom)
    static let panel = LinearGradient(colors: [Color(white: 0.235), Color(white: 0.155)], startPoint: .top, endPoint: .bottom)
    static let display = LinearGradient(colors: [Color(white: 0.115), Color(white: 0.075)], startPoint: .top, endPoint: .bottom)
    static let edge = LinearGradient(colors: [Color.white.opacity(0.16), Color.black.opacity(0.18)], startPoint: .top, endPoint: .bottom)
    static let shading = LinearGradient(colors: [Color.white.opacity(0.10), .clear, Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
    static func fill(_ color: Color) -> some View {
        color.overlay(shading).allowsHitTesting(false)
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
                Image(systemName: "clock").foregroundStyle(Color.blue).font(.system(size: 13))
                if timer.running {
                    RemoteNativeTimerReadout(timer: timer).font(.system(size: 14, weight: .semibold, design: .monospaced))
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
                Text("Timer").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 30, height: 30) }
                    .buttonStyle(RemoteFullAreaButtonStyle()).foregroundStyle(JarasTheme.secondary).accessibilityLabel("Close")
            }
            RemoteNativeTimerReadout(timer: timer)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 11)).foregroundStyle(JarasTheme.secondary)
                        durationField(index)
                    }.frame(maxWidth: .infinity)
                }
            }.disabled(timer.running)
            Button(action: toggleTimer) {
                Text(LocalizedStringKey(timer.running ? "Stop" : "Start"))
                    .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 38)
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
        .font(.system(size: compact ? 14 : 22, weight: .semibold, design: .monospaced))
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
