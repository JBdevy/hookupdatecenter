// Compiled with the production protocol/session sources by test-daw-remote.sh.
import AppKit
setbuf(stdout, nil)
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let project = UUID(), song = UUID(), trackID = UUID(), regionID = UUID()
var fixture = DAWRemoteState(project: project, projectName: "Remote native test", song: song, songName: "Test",
    songs: [.init(id: song, name: "Test")],
    tracks: [.init(id: trackID, name: "Track", color: 0x828282, volume: 1, pan: 0, mute: false, solo: false,
                   clips: [.init(id: UUID(), name: "Clip", start: 0, duration: 10)])],
    regions: [.init(id: regionID, name: "Region", start: 0, end: 10, color: 0x123456)],
    timelineRegions: [], currentRegion: regionID, queuedRegion: nil, focusedRegion: regionID,
    position: 0, duration: 10, bpm: 120, playing: false, paused: false, subPlaying: false, loop: false,
    masterVolume: 1, masterMute: false, masterSolo: false, masterMono: false,
    pendingSave: false, saving: false, message: "")
fixture.tracks[0].nameColor = 0x000000
fixture.tracks[0].emphasized = true
fixture.tracks[0].silenced = true
fixture.regions[0].nameColor = 0x00ff9a
fixture.setlistFontStyle = 2
fixture.masterColor = 0x414141
let legacyTrackPacket = try DAWRemoteWire.state(fixture)
let legacyTrackJSON = try JSONSerialization.jsonObject(with: Data(legacyTrackPacket.dropFirst(4))) as! [String: Any]
require((legacyTrackJSON["tracks"] as! [[String: Any]])[0]["linkedTrack"] == nil, "unlinked state omits optional link metadata for older peers")
if case .state(let decoded) = try DAWRemoteWire.decode(legacyTrackPacket) {
    require(decoded.tracks[0].linkedTrack == nil, "legacy state without link metadata remains compatible")
} else { fatalError("legacy track state packet") }
var linkedFixture = fixture
let partnerTrackID = UUID()
linkedFixture.tracks[0].linkedTrack = partnerTrackID
linkedFixture.tracks.append(.init(id: partnerTrackID, name: "Partner", color: 0x828282,
    volume: 1, pan: 0, mute: false, solo: false, clips: [], linkedTrack: trackID))
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(linkedFixture)) {
    require(decoded.tracks[0].linkedTrack == partnerTrackID && decoded.tracks[1].linkedTrack == trackID,
            "reciprocal stereo fader link identifiers roundtrip unchanged")
} else { fatalError("linked track state packet") }
print("REMOTE_STEREO_FADER_LINK_METADATA_AND_LEGACY_COMPATIBILITY_OK")
require(DAWRemoteFaderScale.gain(-60) == 0, "desktop fader lower endpoint is silent")
require(DAWRemoteFaderScale.gain(0) == 1 && DAWRemoteFaderScale.decibels(1) == 0, "desktop fader unity")
require(DAWRemoteFaderScale.decibels(4) == 12 && DAWRemoteFaderScale.gain(12) < 4, "desktop fader upper bound")
for gain in [0.01, 0.1, 1.0, 2.0] {
    require(abs(DAWRemoteFaderScale.gain(DAWRemoteFaderScale.decibels(gain)) - gain) < 0.000001, "fader gain roundtrip")
}
require(DAWRemoteScrollRange.clamp(-200, content: 2000, viewport: 500) == 0, "track scrolling upper bound")
require(DAWRemoteScrollRange.clamp(3000, content: 2000, viewport: 500) == 1500, "track scrolling lower bound")
require(DAWRemoteScrollRange.clamp(50, content: 100, viewport: 500) == 0, "short list does not scroll")
let panelStart = DAWRemotePanelWidths(track: 0.30, setlist: 0.32)
require(panelStart.resizingTrack(by: 2) == .init(track: 1, setlist: 0), "mixer can occupy the whole content area and push grid/setlist closed")
require(panelStart.resizingSetlist(by: -2) == .init(track: 0, setlist: 1), "setlist can occupy the whole content area and push grid/mixer closed")
require(panelStart.resizingTrack(by: -2) == .init(track: 0, setlist: 0.32), "mixer can collapse fully while preserving setlist")
require(panelStart.resizingSetlist(by: 2) == .init(track: 0.30, setlist: 0), "setlist can collapse fully while preserving mixer")
let expandedTrack = panelStart.resizingTrack(by: 0.5)
require(abs(expandedTrack.track - 0.8) < 0.000001 && abs(expandedTrack.setlist - 0.2) < 0.000001 && expandedTrack.grid < 0.000001,
        "expanding mixer first consumes grid then pushes setlist")
let expandedSetlist = panelStart.resizingSetlist(by: -0.5)
require(abs(expandedSetlist.setlist - 0.82) < 0.000001 && abs(expandedSetlist.track - 0.18) < 0.000001 && expandedSetlist.grid < 0.000001,
        "expanding setlist first consumes grid then pushes mixer")
for delta in [0.0, 0.1, 2.0, 0.5, 0.0, -2.0, -0.1, 0.0] {
    for widths in [panelStart.resizingTrack(by: delta), panelStart.resizingSetlist(by: delta)] {
        require(widths.track >= 0 && widths.setlist >= 0 && widths.grid >= 0 && abs(widths.track + widths.setlist + widths.grid - 1) < 0.000001,
                "full-range resize and reversals stay within the physical content width")
    }
}
require(panelStart.resizingTrack(by: 0) == panelStart && panelStart.resizingSetlist(by: 0) == panelStart,
        "reversing to the original pointer restores both original pane widths after either was pushed closed")
let onlySetlist = DAWRemotePanelWidths(track: 0, setlist: 1)
let restoredMixer = onlySetlist.resizingTrack(by: 0.3)
require(abs(restoredMixer.track - 0.3) < 0.000001 && abs(restoredMixer.setlist - 0.7) < 0.000001,
        "the retained mixer handle can reopen a collapsed mixer from full-screen setlist")
let onlyMixer = DAWRemotePanelWidths(track: 1, setlist: 0)
let restoredSetlist = onlyMixer.resizingSetlist(by: -0.3)
require(abs(restoredSetlist.setlist - 0.3) < 0.000001 && abs(restoredSetlist.track - 0.7) < 0.000001,
        "the retained setlist handle can reopen a collapsed setlist from full-screen mixer")
require(onlyMixer.resizingTrack(by: -0.2).grid > 0.19 && onlySetlist.resizingSetlist(by: 0.2).grid > 0.19,
        "retracting the full-width panel restores grid space")
require(panelStart.resizingTrack(by: .nan) == panelStart && panelStart.resizingSetlist(by: .infinity) == panelStart,
        "invalid drag values cannot corrupt panel layout")
print("REMOTE_FULL_RANGE_PANEL_WIDTHS_COLLAPSE_RESTORE_AND_REVERSALS_OK")
let autoCommand = DAWRemoteCommand(project: project, song: song, action: .toggleRegionAuto)
if case .command(let decodedAuto) = try DAWRemoteWire.decode(DAWRemoteWire.command(autoCommand)) {
    require(decodedAuto.action == .toggleRegionAuto && decodedAuto.valid, "AUTO typed command roundtrip")
} else { fatalError("AUTO packet") }
var autoFixture = fixture
 autoFixture.projectSavedAt = "2026-10-01T15:00:00Z"; autoFixture.footerInformation = "Loop armed"; autoFixture.upcomingName = "Next"; autoFixture.upcomingKind = "Queued song"
 autoFixture.regionAuto = true; autoFixture.queueStartedAt = 2; autoFixture.playbackEnd = 10
if case .state(let decodedState) = try DAWRemoteWire.decode(DAWRemoteWire.state(autoFixture)) {
    require(decodedState.projectSavedAt == autoFixture.projectSavedAt && decodedState.footerInformation == "Loop armed" && decodedState.upcomingName == "Next" && decodedState.upcomingKind == "Queued song", "footer and upcoming display metadata roundtrip")
    require(decodedState.regionAuto == true && decodedState.queueStartedAt == 2 && decodedState.playbackEnd == 10, "authoritative AUTO and countdown state")
} else { fatalError("AUTO state packet") }
let itemID = fixture.tracks[0].clips[0].id
let itemGain = DAWRemoteCommand(project: project, song: song, action: .clipGain, target: itemID, value: pow(10, 24.0 / 20))
require(itemGain.valid, "item fader accepts desktop +24 dB maximum")
require(!DAWRemoteCommand(project: project, song: song, action: .clipGain, target: nil, value: 1).valid, "item gain requires explicit target")
require(!DAWRemoteCommand(project: project, song: song, action: .clipGain, target: itemID, value: 16).valid, "item gain rejects above +24 dB")
require(!DAWRemoteCommand(project: project, song: song, action: .clipGain, target: itemID, value: .nan).valid, "item gain rejects nonfinite value")
for command in [itemGain, DAWRemoteCommand(project: project, song: song, action: .clipMute, target: itemID), DAWRemoteCommand(project: project, song: song, action: .selectPlaylist)] {
    require(command.valid, "native grid/playlist command valid")
    if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(command)) {
        require(decoded.action == command.action && decoded.target == command.target && decoded.value == command.value, "native item and playlist command roundtrip")
    } else { fatalError("grid command packet") }
}
var gridFixture = fixture
let playlistID = UUID()
gridFixture.tracks[0].clips[0].gain = 0.5; gridFixture.tracks[0].clips[0].muted = true
gridFixture.playlists = [.init(id: playlistID, name: "Playlist")]; gridFixture.selectedPlaylist = playlistID; gridFixture.gridRegion = regionID
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(gridFixture)) {
    require(decoded.tracks[0].clips[0].gain == 0.5 && decoded.tracks[0].clips[0].muted == true, "authoritative item volume/mute state")
    require(decoded.selectedPlaylist == playlistID && decoded.playlists?.first?.name == "Playlist" && decoded.gridRegion == regionID, "playlist and currently playing grid state")
} else { fatalError("grid state packet") }
var markerFixture = fixture
markerFixture.markers = [.init(id: UUID(), name: "Entrada", position: 2, color: 0x00ff9a)]
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(markerFixture)) {
    require(decoded.markers?.first?.name == "Entrada" && decoded.markers?.first?.position == 2, "grid marker metadata roundtrip")
} else { fatalError("marker state packet") }
markerFixture.markers![0].position = .nan
require(!markerFixture.valid, "marker invalid time rejected")
var laneFixture = fixture
laneFixture.tracks[0].laneCount = 2; laneFixture.tracks[0].clips[0].lane = 1
require(abs(DAWRemoteItemLayout.rowHeight(laneFixture.tracks[0]) - 120.4) < 0.000001, "overlapping item lanes expand matching mixer/grid row height")
require(DAWRemoteItemLayout.laneHeight(fixture.tracks[0]) == 86, "single item fills full track height")
for scale in [0.35, 0.5, 1.0, 2.0, 3.0] {
    let track = laneFixture.tracks[0]
    require(DAWRemoteItemLayout.laneHeight(track, scale: scale) >= 28, "pinch keeps item mute/name header visible")
    require(abs(DAWRemoteItemLayout.rowHeight(track, scale: scale) - DAWRemoteItemLayout.laneHeight(track, scale: scale) * Double(track.laneCount ?? 1)) < 0.000001, "pinch scales every overlapping lane and mixer row together")
}
require(DAWRemoteItemLayout.heightScale(.nan) == 1 && DAWRemoteItemLayout.heightScale(0) == 0.35 && DAWRemoteItemLayout.heightScale(100) == 3, "pinch restores only finite bounded heights")
var visibleLaneTrack = fixture.tracks[0]
visibleLaneTrack.laneCount = 8
visibleLaneTrack.clips = [
    .init(id: UUID(), name: "unified A", start: 0, duration: 5, lane: 4),
    .init(id: UUID(), name: "unified B", start: 2, duration: 5, lane: 7),
    .init(id: UUID(), name: "adjacent C", start: 7, duration: 3, lane: 6),
    .init(id: UUID(), name: "another song", start: 20, duration: 10, lane: 7)
]
let visibleLaneLayout = DAWRemoteItemLayout.tracks([visibleLaneTrack], within: fixture.regions[0])[0]
require(visibleLaneLayout.laneCount == 2 && visibleLaneLayout.clips.map(\.lane) == [0, 1, 0],
    "unified overlaps expand to contiguous lanes and adjacent items reuse an available lane")
require(abs(DAWRemoteItemLayout.rowHeight(visibleLaneLayout) - 120.4) < 0.000001,
    "current song height ignores lanes occupied only outside its region")
let laterRegion = DAWRemoteState.Region(id: UUID(), name: "Later", start: 20, end: 30, color: 0)
let singleLaneLayout = DAWRemoteItemLayout.tracks([visibleLaneTrack], within: laterRegion)[0]
require(singleLaneLayout.laneCount == 1 && singleLaneLayout.clips[0].lane == 0 && DAWRemoteItemLayout.rowHeight(singleLaneLayout) == 86,
    "a single visible item fills its track, even when the host assigned it a higher global lane")
require(DAWRemoteItemLayout.tracks([visibleLaneTrack], within: nil)[0].clips.isEmpty, "no selection displays no out-of-region items")
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(laneFixture)) {
    require(decoded.tracks[0].laneCount == 2 && decoded.tracks[0].clips[0].lane == 1, "desktop item lane metadata roundtrip")
} else { fatalError("lane state packet") }
let volume = DAWRemoteCommand(project: project, song: song, action: .volume, target: trackID, value: 0.5)
if case .command(let command) = try DAWRemoteWire.decode(DAWRemoteWire.command(volume)) {
    require(command.id == volume.id && command.value == 0.5 && command.target == trackID, "typed action roundtrip")
} else { fatalError("command packet") }
if case .state(let state) = try DAWRemoteWire.decode(DAWRemoteWire.state(fixture)) {
    require(state == fixture, "native state roundtrip")
} else { fatalError("state packet") }
for data in [Data(), Data([0x4a,0x4c,1,1]), Data([0x4a,0x4c,2,99]), Data(repeating: 0, count: DAWRemoteWire.maximumPacket + 1)] {
    require((try? DAWRemoteWire.decode(data)) == nil, "reject old mirroring protocol and malformed packets")
}
for semitones in [-12.0, -7, 7, 12] {
    let pitch = DAWRemoteCommand(project: project, action: .pitch, target: regionID, value: semitones)
    if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(pitch)) {
        require(decoded.value == semitones && decoded.target == regionID, "remote preserves the full VS Hook tuner range")
    } else { fatalError("pitch command packet") }
}
for command in [DAWRemoteCommand(project: project, action: .volume, value: -.infinity),
                DAWRemoteCommand(project: project, action: .volume, value: 5),
                DAWRemoteCommand(project: project, action: .pan, target: trackID, value: 2),
                DAWRemoteCommand(project: project, action: .selectRegion),
                DAWRemoteCommand(project: project, action: .seek, value: -1),
                DAWRemoteCommand(project: project, action: .pitch, target: regionID, value: 13),
                DAWRemoteCommand(project: project, action: .pitch, target: regionID, value: -13),
                DAWRemoteCommand(project: project, action: .pitch, target: regionID, value: 0.5),
                DAWRemoteCommand(project: project, action: .pitch, value: 1)] {
    require((try? DAWRemoteWire.command(command)) == nil, "reject invalid command values")
}
for phase in [0, 1, 3] {
    var pulse = fixture; pulse.loop = true; pulse.footerInformation = "Loop Ativo"; pulse.footerLoopBeatPhase = phase
    if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(pulse)) {
        require(decoded.footerLoopBeatPhase == phase && decoded.footerInformation == "Loop Ativo", "notice pulse and exact loop text roundtrip")
    } else { fatalError("notice pulse packet") }
}
var invalidPulse = fixture; invalidPulse.footerLoopBeatPhase = 2
require((try? DAWRemoteWire.state(invalidPulse)) == nil, "reject unknown notice pulse phase")
print("REMOTE_LOOP_NOTICE_PULSE_ROUNDTRIP_OK")
var malformed = fixture; malformed.position = .nan
require((try? DAWRemoteWire.state(malformed)) == nil, "reject nonfinite presentation state")
var catalog = DAWRemoteProjectCatalog()
let firstProject = URL(fileURLWithPath: "/private/mac-only/first/Concert.jl")
let secondProject = URL(fileURLWithPath: "/private/mac-only/second/Concert.jl")
let firstCatalog = catalog.update([firstProject, firstProject, secondProject], current: firstProject)
require(firstCatalog.count == 2 && firstCatalog[0].current && !firstCatalog[1].current, "recent projects deduplicate URLs and identify open document")
require(firstCatalog[0].id != firstCatalog[1].id, "same-named projects have separate opaque identifiers")
let reordered = catalog.update([secondProject, firstProject], current: secondProject)
require(reordered.map(\.id) == firstCatalog.reversed().map(\.id), "recent project identifiers survive reordering")
require(catalog.url(for: firstCatalog[1].id) == secondProject && catalog.url(for: UUID()) == nil, "host resolves only issued recent project identifiers")
var projectsFixture = fixture
projectsFixture.projects = .init(recent: reordered, busy: false, canOpen: true, status: "", error: "")
let projectsPacket = try DAWRemoteWire.state(projectsFixture)
require(!String(decoding: projectsPacket, as: UTF8.self).contains("mac-only"), "remote project browser never sends Mac paths")
if case .state(let decoded) = try DAWRemoteWire.decode(projectsPacket) {
    require(decoded.projects == projectsFixture.projects, "recent projects and opening status roundtrip")
} else { fatalError("project browser state packet") }
let openRecent = DAWRemoteCommand(project: project, song: song, action: .openRecentProject, target: reordered[0].id)
if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(openRecent)) {
    require(decoded.action == .openRecentProject && decoded.target == reordered[0].id, "open recent project typed action roundtrip")
} else { fatalError("open recent project packet") }
require(!DAWRemoteCommand(project: project, action: .openRecentProject).valid, "open project requires explicit opaque target")
require(!DAWRemoteCommand(project: project, action: .openRecentProject, target: UUID(), value: 1).valid, "open project rejects arbitrary payload values")
_ = catalog.update([firstProject], current: firstProject)
require(catalog.url(for: firstCatalog[1].id) == nil, "removed recent project identifiers are revoked")
projectsFixture.projects?.recent.append(reordered[0])
require(!projectsFixture.valid, "duplicate recent identifiers rejected")
projectsFixture.projects = .init(recent: reordered, busy: true, canOpen: false, status: "Opening project…", error: "")
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(projectsFixture)) {
    require(decoded.projects?.busy == true && decoded.projects?.canOpen == false, "host owns opening progress and transition availability")
} else { fatalError("project progress state packet") }
print("REMOTE_RECENT_PROJECTS_OPAQUE_IDS_AND_OPEN_COMMAND_OK")
print("REMOTE_NATIVE_STATE_TYPED_ACTIONS_AND_VERSION_VALIDATION_OK")

func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError(message) } catch {}
}
func waitFor(_ message: String, seconds: Double = 5, _ done: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
    if !done() { FileHandle.standardError.write(Data(("TIMEOUT: " + message + "\n").utf8)) }
    require(done(), message)
}

let plain = try DAWRemoteWire.command(volume)
let encoderHost = DAWRemoteCipher(role: .host, name: "Mac test")
let encoderClient = DAWRemoteCipher(role: .client, name: "iPad test")
let helloClientName = try encoderHost.accept(encoderClient.hello())
let helloHostName = try encoderClient.accept(encoderHost.hello())
require(helloClientName == "iPad test", "host reads bounded peer hello")
require(helloHostName == "Mac test", "client reads bounded peer hello")
let sealed = try encoderClient.seal(plain)
require(sealed.range(of: plain) == nil, "application packet is not sent as plaintext")
var tampered = sealed; tampered[tampered.count - 1] ^= 1
rejects("tampered packets rejected") { _ = try encoderHost.open(tampered) }
let opened = try encoderHost.open(sealed)
require(opened == plain, "authenticated encryption roundtrip")
rejects("replayed encrypted packet rejected") { _ = try encoderHost.open(sealed) }
let reply = try encoderHost.seal(DAWRemoteWire.acknowledge(42))
let openedReply = try encoderClient.open(reply), expectedReply = try DAWRemoteWire.acknowledge(42)
require(openedReply == expectedReply, "directional keys carry reply")
rejects("direction reflection rejected") { _ = try encoderClient.open(encoderClient.seal(plain)) }
rejects("duplicate key handshake rejected") { _ = try encoderClient.accept(encoderHost.hello()) }
let wrongRole = DAWRemoteCipher(role: .host, name: "Wrong role")
rejects("same role cannot establish a connection") { _ = try wrongRole.accept(encoderHost.hello()) }
let freshClient = DAWRemoteCipher(role: .client, name: "Next connection")
_ = try freshClient.accept(encoderHost.hello())
rejects("ciphertext cannot cross connections") { _ = try freshClient.open(reply) }
let hugeName = DAWRemoteCipher(role: .client, name: String(repeating: "👩‍👩‍👧‍👦", count: 200))
require(hugeName.hello().count <= 197, "Unicode device names stay within handshake limit")
let payloads = [encoderHost.hello(), sealed, reply]
let allFrames = try payloads.reduce(into: Data()) { $0.append(try DAWRemoteFrames.encode($1)) }
for chunkSize in [1, 2, 3, 4, 7, 32, allFrames.count] {
    var framer = DAWRemoteFrames(), decoded: [Data] = []
    for first in stride(from: 0, to: allFrames.count, by: chunkSize) {
        decoded += try framer.receive(allFrames.subdata(in: first..<min(first + chunkSize, allFrames.count)))
    }
    require(decoded == payloads, "TCP fragmentation and coalescence preserve exact packet boundaries")
}
var invalidFramer = DAWRemoteFrames()
rejects("oversized declared length rejected before allocation") { _ = try invalidFramer.receive(Data([0xff, 0xff, 0xff, 0xff])) }
var emptyFramer = DAWRemoteFrames()
rejects("zero-length frame rejected") { _ = try emptyFramer.receive(Data(repeating: 0, count: 4)) }
rejects("oversized output frame rejected") { _ = try DAWRemoteFrames.encode(Data(repeating: 0, count: DAWRemoteFrames.maximum + 1)) }
print("REMOTE_DIRECT_EPHEMERAL_ENCRYPTION_TAMPER_REPLAY_DIRECTION_AND_BOUNDED_TCP_FRAMING_OK")

var remoteTestSubscriptions: [AnyCancellable] = []
extension DAWRemoteSession {
    func testListen() throws -> NWEndpoint {
        stop(); enabled = true
        let parameters = DAWRemoteChannel.parameters()
        require(parameters.includePeerToPeer, "direct path enables Apple peer-to-peer discovery and transport")
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        startListener(listener)
        waitFor("isolated loopback listener becomes ready") { (listener.port?.rawValue ?? 0) > 0 }
        return .hostPort(host: "127.0.0.1", port: listener.port!)
    }
    func testConnect(_ endpoint: NWEndpoint, access: DAWRemoteAccess? = .director, pin: String = "") {
        stop(); enabled = true
        if let access {
            remoteTestSubscriptions.append($connected.filter { $0 }.prefix(1).sink { [weak self] _ in
                DispatchQueue.main.async { self?.requestAccess(access, pin: pin) }
            })
        }
        let peer = DAWRemotePeer(id: "loopback-only", displayName: "Direct loopback Mac")
        peers = [peer]; endpoints[peer.id] = endpoint
        connect(peer)
    }
    func testGate(_ endpoint: NWEndpoint, occupied: Bool) {
        let current = channel
        let candidate = NWConnection(to: endpoint, using: DAWRemoteChannel.parameters())
        let listener = self.listener!
        if !occupied { enabled = false }
        accept(candidate, from: listener)
        require(channel === current, occupied ? "occupied host rejects a replacement" : "disabled Remote rejects direct connections")
        enabled = true
    }
    func testIsolation(_ endpoint: NWEndpoint) {
        let stranger = DAWRemoteChannel(connection: NWConnection(to: endpoint, using: DAWRemoteChannel.parameters()), role: .client, name: "Stranger", queue: worker)
        received(.command(.init(project: project, action: .stop)), from: stranger)
    }
    func testAcknowledgements() {
        stateTimer?.invalidate(); stateTimer = nil
        waitingForState = 987
        let before = stateSequence
        sendingState = false; publishState()
        require(stateSequence == before, "unacknowledged state prevents another full-state publication")
        received(.acknowledge(986), from: channel!)
        require(waitingForState == 987, "stale acknowledgement cannot release backpressure")
        received(.acknowledge(987), from: channel!)
        require(waitingForState == nil, "matching acknowledgement releases backpressure")
        publishState()
    }
    func testEquivalentStatePublication() {
        var publications = 0
        let observation = $remoteState.dropFirst().sink { _ in publications += 1 }
        var next = remoteState!
        next.sequence = receivedStateSequence + 1
        received(.state(next), from: channel!)
        require(publications == 0 && receivedStateSequence == next.sequence, "identical content advances receive sequence without rebuilding the UI")
        next.sequence += 1; next.message = "Changed presentation"
        received(.state(next), from: channel!)
        require(publications == 1 && remoteState?.message == next.message, "changed state publishes immediately")
        next.sequence -= 1; next.message = "Stale presentation"
        received(.state(next), from: channel!)
        require(publications == 1 && remoteState?.message == "Changed presentation", "outdated state cannot regress presentation")
        withExtendedLifetime(observation) {}
    }
    func testReset() {
        require(channel == nil && waitingForState == nil && !sendingState && handledCommands.isEmpty, "disconnect resets transport and command history")
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let windowsBefore = app.windows.count
let host = DAWRemoteSession(role: .host, name: "Direct test Mac")
let client = DAWRemoteSession(role: .client, name: "Direct test iPad")
let endpoint = try host.testListen()
host.testGate(endpoint, occupied: false)
var commandCount = 0
host.stateProvider = { fixture }
host.commandHandler = { command in
    commandCount += 1
    if command.action == .play { fixture.playing = true }
    if command.action == .volume { fixture.tracks[0].volume = command.value }
}
client.testConnect(endpoint)
waitFor("direct loopback peers complete encrypted handshake") { host.connected && client.connected && client.remoteState != nil }
require(host.peerName == "Direct test iPad" && client.peerName == "Direct test Mac", "handshake carries device names")
// Multiple independently authorized iPads may now share the same host.
host.testIsolation(endpoint)
require(commandCount == 0, "packets from another channel do not execute")
let play = DAWRemoteCommand(project: project, song: song, action: .play)
client.send(play); client.send(volume); client.send(volume); client.send(openRecent); client.send(openRecent)
waitFor("native actions and state roundtrip over encrypted direct TCP") {
    commandCount == 3 && client.remoteState?.playing == true && client.remoteState?.tracks.first?.volume == 0.5
}
host.testAcknowledgements()
client.testEquivalentStatePublication()
client.stop()
waitFor("host releases disconnected client") { !host.connected && !host.connecting }
host.testReset()
client.testConnect(endpoint)
waitFor("same host accepts direct reconnect with fresh ephemeral keys") { host.connected && client.connected && client.remoteState != nil }
client.send(play)
waitFor("new session has independent command dedup history") { commandCount == 4 }
require(app.windows.count == windowsBefore, "Remote never creates a screen capture window")
client.stop(); host.stop()
host.testReset(); client.testReset()
print("REMOTE_DIRECT_LOOPBACK_COMMAND_STATE_ACK_DEDUP_DISABLED_OCCUPIED_DISCONNECT_RECONNECT_NO_CAPTURE_OK")

extension DAWRemoteSession {
    func testSendSnapshots(_ states: [DAWRemoteState]) -> UInt64 {
        stateTimer?.invalidate(); stateTimer = nil
        for var state in states {
            stateSequence += 1; state.sequence = stateSequence
            channel!.send(try! DAWRemoteWire.state(state))
        }
        return stateSequence
    }
    func testReceivedSequence() -> UInt64 { receivedStateSequence }
}
let timerHost = DAWRemoteSession(role: .host, name: "Timer test Mac")
let timerClient = DAWRemoteSession(role: .client, name: "Timer test iPad")
var timerFixture = fixture
timerFixture.playing = false; timerFixture.paused = true
timerFixture.timer = .init(revision: UUID(), targetSeconds: 300, running: true, remainingSeconds: 300)
timerHost.stateProvider = { timerFixture }
let timerEndpoint = try timerHost.testListen()
timerClient.testConnect(timerEndpoint)
waitFor("timer fixture connects with initial timer sample") { timerClient.remoteState?.timer != nil }
var timerPublications = 0
let timerObservation = timerClient.$remoteState.dropFirst().sink { _ in timerPublications += 1 }
let ticks = (1...100).map { tick -> DAWRemoteState in
    var state = timerFixture; state.timer?.remainingSeconds -= Double(tick) * 0.1; return state
}
let lastTick = timerHost.testSendSnapshots(ticks)
waitFor("all 100 encrypted timer ticks are received") { timerClient.testReceivedSequence() >= lastTick }
require(timerPublications == 0, "100 unchanged timer ticks must not republish the paused workspace")
timerFixture.timer?.revision = UUID(); timerFixture.timer?.remainingSeconds = 180
let resetTick = timerHost.testSendSnapshots([timerFixture])
waitFor("new timer revision arrives") { timerClient.testReceivedSequence() >= resetTick }
require(timerPublications == 1 && timerClient.remoteState?.timer?.remainingSeconds == 180, "timer revision publishes a fresh remaining sample")
timerFixture.timer?.commandID = UUID(); timerFixture.timer?.remainingSeconds = 179
let confirmedTick = timerHost.testSendSnapshots([timerFixture])
waitFor("timer command confirmation arrives") { timerClient.testReceivedSequence() >= confirmedTick }
require(timerPublications == 2 && timerClient.remoteState?.timer?.commandID == timerFixture.timer?.commandID, "command acknowledgement cannot be hidden by timer normalization")
timerFixture.masterVolume = 0.6; timerFixture.timer?.remainingSeconds = 170
let changedTick = timerHost.testSendSnapshots([timerFixture])
waitFor("other workspace change arrives with live timer sample") { timerClient.testReceivedSequence() >= changedTick }
require(timerPublications == 3 && timerClient.remoteState?.timer?.remainingSeconds == 170,
        "when another field changes, publish the actual incoming timer sample")
withExtendedLifetime(timerObservation) {}
timerClient.stop(); timerHost.stop()
print("REMOTE_TIMER_100_NETWORK_TICKS_NO_WORKSPACE_PUBLICATION_REVISION_COMMAND_AND_OTHER_CHANGES_OK")

// Still-image transport uses local fixtures only; video decoders are never used.
let imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-remote-images-\(UUID())")
try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: imageDirectory) }
let imagePixels = Data(repeating: 128, count: 3200 * 32 * 4)
let imageProvider = CGDataProvider(data: imagePixels as CFData)!
let fixtureImage = CGImage(width: 3200, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 3200 * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
    provider: imageProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
func fixtureImageData(type: UTType, frames: Int = 1) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(destination, fixtureImage, nil) }
    require(CGImageDestinationFinalize(destination), "fixture image encodes")
    return output as Data
}
let imagePNG = fixtureImageData(type: .png)
let imageURL = imageDirectory.appendingPathComponent("fixture.png")
try imagePNG.write(to: imageURL)
let preparedImage = DAWRemoteStillImage.prepare(.file(imageURL))!
require(DAWRemoteStillImage.valid(preparedImage), "prepared still image has bounded dimensions and encoded bytes")
let preparedSource = CGImageSourceCreateWithData(preparedImage as CFData, nil)!
let preparedProperties = CGImageSourceCopyPropertiesAtIndex(preparedSource, 0, nil) as! [CFString: Any]
require(preparedProperties[kCGImagePropertyPixelWidth] as? Int == 1600, "oversized images are downsampled before transfer")
require(CGImageSourceGetType(preparedSource) as String? == UTType.png.identifier, "transparent still images retain PNG alpha")
let fakeMovieURL = imageDirectory.appendingPathComponent("movie.mov")
try imagePNG.write(to: fakeMovieURL)
require(DAWRemoteStillImage.prepare(.file(fakeMovieURL)) == nil, "video URLs are refused even when their payload resembles an image")
require(DAWRemoteStillImage.prepare(.bytes(Data("not a still image".utf8))) == nil, "non-image payloads are refused")
require(DAWRemoteStillImage.prepare(.bytes(fixtureImageData(type: .gif, frames: 2))) == nil, "animated/multiframe media is never transferred")
require(!DAWRemoteStillImage.valid(imagePNG), "client refuses source images exceeding its decoding bounds")
let imageAsset = DAWRemoteImageAsset(project: project, id: UUID(), data: preparedImage)
let imageWire = try DAWRemoteWire.imageAsset(imageAsset)
require(imageWire.count == preparedImage.count + 36, "image wire is binary without JSON/base64 expansion")
if case .imageAsset(let decoded) = try DAWRemoteWire.decode(imageWire) { require(decoded == imageAsset, "opaque image identifiers and data roundtrip") }
else { fatalError("image packet kind") }
rejects("oversized image asset rejected") {
    _ = try DAWRemoteWire.imageAsset(.init(project: project, id: UUID(), data: Data(repeating: 0, count: DAWRemoteImageAsset.maximumBytes + 1)))
}
let tinyCache = DAWRemoteImageCache(limit: 10), firstImageID = UUID(), secondImageID = UUID(), thirdImageID = UUID()
tinyCache.insert(Data(repeating: 1, count: 4), id: firstImageID)
tinyCache.insert(Data(repeating: 2, count: 4), id: secondImageID)
_ = tinyCache.data(firstImageID)
tinyCache.insert(Data(repeating: 3, count: 4), id: thirdImageID)
require(tinyCache.bytes == 8 && tinyCache.data(secondImageID) == nil && tinyCache.data(firstImageID) != nil, "image cache evicts by byte budget and recent use")
print("REMOTE_STILL_IMAGE_BINARY_BOUNDS_DOWNSAMPLE_ALPHA_NO_VIDEO_NO_ANIMATION_AND_CACHE_BUDGET_OK")

extension DAWRemoteSession {
    func testImagePending() -> Int { imagePending.count + imageQueue.count }
    func testFailedImage(_ id: UUID) -> Bool { imageFailed.contains(id) }
    func testDropImageCache() { images.clear() }
    func testUnsolicitedImage(_ asset: DAWRemoteImageAsset) { received(.imageAsset(asset), from: channel!) }
    func testImageProjectChange() {
        var next = remoteState!; next.sequence = receivedStateSequence + 1; next.project = UUID()
        received(.state(next), from: channel!)
    }
}
let imageHost = DAWRemoteSession(role: .host, name: "Image test Mac")
let imageClient = DAWRemoteSession(role: .client, name: "Image test iPad")
let imageEndpoint = try imageHost.testListen()
let registeredImage = imageHost.imageID(for: imageURL, project: project)!
require(imageHost.imageID(for: imageURL, project: project) == registeredImage, "URL registration is stable and does not reprocess images")
let noticeImageID = imageHost.imageID(for: imagePNG, project: project, key: "notice-revision-1")!
require(imageHost.imageID(for: imagePNG, project: project, key: "notice-revision-1") == noticeImageID, "notice revision reuses its opaque image ID")
require(imageHost.imageData(id: registeredImage, project: project) == nil, "registration alone does not read, prepare, or transfer the image")
var imageApplicationCommands = 0
imageHost.commandHandler = { _ in imageApplicationCommands += 1 }
imageHost.stateProvider = { fixture }
imageClient.testConnect(imageEndpoint)
waitFor("image fixture direct session connects") { imageClient.remoteState != nil }
imageClient.testUnsolicitedImage(imageAsset)
require(imageClient.imageData(id: imageAsset.id, project: project) == nil, "unsolicited assets never enter the cache")
imageClient.requestImage(id: registeredImage, project: project)
imageClient.requestImage(id: registeredImage, project: project)
require(imageClient.testImagePending() == 1, "concurrent requests for the same image are deduplicated")
waitFor("requested static image arrives over encrypted direct channel") { imageClient.imageData(id: registeredImage, project: project) != nil }
require(imageClient.imageData(id: registeredImage, project: project) == preparedImage && imageApplicationCommands == 0, "image transport does not execute project actions")
imageClient.requestImage(id: registeredImage, project: project)
require(imageClient.testImagePending() == 0, "cached still image does not request another transfer")
try FileManager.default.removeItem(at: imageURL)
imageClient.testDropImageCache(); imageClient.requestImage(id: registeredImage, project: project)
waitFor("host serves cached derivative without reopening source") { imageClient.imageData(id: registeredImage, project: project) != nil }
let unknownImage = UUID()
imageClient.requestImage(id: unknownImage, project: project)
waitFor("unknown opaque image ends with unavailable response") { imageClient.testFailedImage(unknownImage) }
require(imageClient.imageUnavailable(id: unknownImage, project: project), "unavailable response exposes a terminal placeholder state to the image view")
require(!imageClient.imageUnavailable(id: unknownImage, project: UUID()), "image failure state cannot leak to another project")
imageClient.requestImage(id: unknownImage, project: project)
require(imageClient.testImagePending() == 0, "unavailable image cannot create a repeated request loop")
imageClient.requestImage(id: noticeImageID, project: project)
waitFor("notice data uses same cached static transfer") { imageClient.imageData(id: noticeImageID, project: project) != nil }
imageClient.testImageProjectChange()
require(imageClient.imageData(id: registeredImage, project: project) == nil && imageClient.testImagePending() == 0,
        "project change clears old image data and requests")
imageClient.stop(); imageHost.stop()
require(imageHost.imageData(id: registeredImage, project: project) == nil, "disconnect clears prepared image cache and registrations")
print("REMOTE_ON_DEMAND_STILL_IMAGE_REQUEST_DEDUP_CACHE_REUSE_UNKNOWN_REJECTION_PROJECT_RESET_AND_DISCONNECT_OK")

// Switching documents on the Mac keeps the encrypted connection alive and
// publishes a complete replacement, even when copied projects reuse item IDs.
let switchHost = DAWRemoteSession(role: .host, name: "Switch test Mac")
let switchClient = DAWRemoteSession(role: .client, name: "Switch test iPad")
var switchFixture = fixture
switchFixture.playing = false
switchHost.stateProvider = { switchFixture }
let switchEndpoint = try switchHost.testListen()
switchClient.testConnect(switchEndpoint)
waitFor("first project arrives") { switchClient.remoteState?.project == switchFixture.project }
let oldProject = switchFixture.project
switchFixture.project = UUID(); switchFixture.projectName = "Second session"
switchFixture.tracks[0].name = "Second session track"
switchFixture.position = 0
waitFor("Mac project switch reaches iPad without reconnecting") {
    switchClient.remoteState?.project == switchFixture.project &&
    switchClient.remoteState?.projectName == "Second session" &&
    switchClient.remoteState?.tracks.first?.name == "Second session track"
}
require(switchHost.connected && switchClient.connected && switchClient.remoteState?.project != oldProject,
        "document switch preserves the connection and replaces the old project")
switchClient.stop(); switchHost.stop()
print("REMOTE_MAC_DOCUMENT_SWITCH_REPLACES_PROJECT_WITHOUT_RECONNECT_OK")

var gridTimingFixture = fixture
gridTimingFixture.gridTempo = [.init(start: 0, end: 5.3, bpm: 120, beats: 4, unit: 4),
                         .init(start: 5.3, end: 10, bpm: 90, beats: 3, unit: 4)]
gridTimingFixture.gridDivisions = 8
gridTimingFixture.gridLines = true
gridTimingFixture.gridPrimaryColor = 0x414141
gridTimingFixture.gridSecondaryColor = 0x282828
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(gridTimingFixture)) {
    require(decoded.gridTempo == gridTimingFixture.gridTempo && decoded.gridDivisions == 8, "remote preserves absolute tempo boundaries and subdivisions")
    require(decoded.gridPrimaryColor == 0x414141 && decoded.gridSecondaryColor == 0x282828 && decoded.gridLines == true, "remote preserves grid appearance")
} else { fatalError("grid state packet") }
gridTimingFixture.gridTempo![0].bpm = 0
require(!gridTimingFixture.valid, "invalid grid tempo must be rejected before calculating ticks")
gridTimingFixture.gridTempo = []
gridTimingFixture.gridDivisions = 3
require(!gridTimingFixture.valid, "unsupported grid subdivisions must be rejected")
print("REMOTE_GRID_TEMPO_DIVISIONS_COLORS_ROUNDTRIP_AND_VALIDATION_OK")

// Roles are authenticated on the host. A forged client packet cannot bypass UI restrictions.
let rolesHost = DAWRemoteSession(role: .host, name: "Roles Mac")
require(rolesHost.setDirectorPIN("0123"), "four digit PIN accepts leading zero")
let rolesEndpoint = try rolesHost.testListen()
var rolesFixture = fixture
var roleCommandCount = 0
rolesHost.stateProviderForSession = { session in
    var state = rolesFixture; state.message = "panel-\(session.requestedPanel)"; return state
}
rolesHost.commandHandler = { command in
    roleCommandCount += 1
    if command.action == .play { rolesFixture.playing = true }
}
extension DAWRemoteSession {
    func testUnchecked(_ command: DAWRemoteCommand) { channel?.send(try! DAWRemoteWire.command(command)) }
    func testPendingAccessSnapshot() { waitingForState = 123456789; sentAt = Date() }
    func testNoPendingAccessSnapshot() { require(waitingForState == nil, "revocation clears the old ACK wait") }
}
let director = DAWRemoteSession(role: .client, name: "Director")
let observer = DAWRemoteSession(role: .client, name: "Observer")
director.testConnect(rolesEndpoint, access: nil)
waitFor("mode picker waits for host PIN requirement") { director.connected && director.directorRequiresPIN }
require(director.remoteState == nil, "no workspace before selecting an authorized role")
director.testUnchecked(.init(project: project, action: .play))
director.requestAccess(.director, pin: "9999")
waitFor("incorrect PIN rejected") { !director.authorizing && !director.accessError.isEmpty }
require(director.accessMode == nil && roleCommandCount == 0, "unauthenticated packet never controls host")
director.requestAccess(.director, pin: "0123")
waitFor("correct PIN opens director") { director.accessMode == .director && director.remoteState != nil }
observer.testConnect(rolesEndpoint, access: .observer)
waitFor("observer joins alongside director without PIN") { observer.accessMode == .observer && observer.remoteState != nil }
require(observer.remoteState!.tracks.isEmpty && observer.remoteState!.playlists == nil && observer.remoteState!.projects == nil, "observer receives no mixer or project controls")
observer.testUnchecked(.init(project: project, action: .play))
observer.testUnchecked(.init(project: project, action: .selectPlaylist))
observer.send(.init(project: project, action: .remotePanel, value: 2))
director.send(.init(project: project, action: .remotePanel, value: 1))
waitFor("independent local teleprompter subscriptions") { observer.remoteState?.message == "panel-2" && director.remoteState?.message == "panel-1" }
require(roleCommandCount == 0, "observer cannot control Mac even with raw packets")
director.send(.init(project: project, action: .play))
waitFor("director changes are mirrored to observer") { director.remoteState?.playing == true && observer.remoteState?.playing == true && roleCommandCount == 1 }
let observerNext = UUID()
rolesFixture.regions.append(.init(id: observerNext, name: "Next", start: 12, end: 20, color: 0x123456))
rolesFixture.regions.reverse(); rolesFixture.focusedRegion = observerNext; rolesFixture.queuedRegion = observerNext
waitFor("observer mirrors host setlist order, focus and queue") {
    observer.remoteState?.regions.first?.id == observerNext && observer.remoteState?.focusedRegion == observerNext && observer.remoteState?.queuedRegion == observerNext
}
rolesHost.testPendingAccessSnapshot()
require(rolesHost.setDirectorPIN("4567"), "host updates PIN")
rolesHost.testNoPendingAccessSnapshot()
waitFor("PIN change revokes old director grant") { director.accessMode == nil }
require(observer.accessMode == .observer, "PIN change does not interrupt observers")
director.testUnchecked(.init(project: project, action: .stop))
require(rolesHost.setDirectorPIN(""), "empty PIN disables password")
director.requestAccess(.director)
waitFor("director without password after explicit removal") { director.accessMode == .director }
director.stop()
waitFor("observer survives director disconnect") { rolesHost.connected && observer.connected }
rolesFixture.position = 2
waitFor("remaining observer continues receiving states") { observer.remoteState?.position == 2 }
let reboundProject = UUID()
rolesHost.stateProviderForSession = { session in
    var state = rolesFixture; state.project = reboundProject; state.message = "rebound-\(session.requestedPanel)"; return state
}
waitFor("secondary client follows replacement project provider instead of waiting on stale binding") {
    observer.remoteState?.project == reboundProject && observer.remoteState?.message == "rebound-2"
}
observer.stop(); rolesHost.stop()
// A notices login is independent from the director and never controls transport.
let noticesHost = DAWRemoteSession(role: .host, name: "Notices Mac")
require(noticesHost.setDirectorPIN("0123") && noticesHost.setNoticesPIN("9876"), "independent role PINs saved")
var noticeCommands: [DAWRemoteCommand.Action] = []
noticesHost.stateProviderForSession = { session in
    var state = fixture; state.message = "panel-\(session.requestedPanel)"; return state
}
noticesHost.commandHandler = { noticeCommands.append($0.action) }
let noticesEndpoint = try noticesHost.testListen()
let noticesClient = DAWRemoteSession(role: .client, name: "Notices phone")
noticesClient.testConnect(noticesEndpoint, access: nil)
waitFor("both PIN requirements advertised") { noticesClient.directorRequiresPIN && noticesClient.noticesRequiresPIN }
noticesClient.requestAccess(.notices, pin: "0123")
waitFor("director PIN cannot unlock notices") { !noticesClient.authorizing && !noticesClient.accessError.isEmpty }
require(noticesClient.accessMode == nil, "wrong role credential rejected")
noticesClient.requestAccess(.notices, pin: "9876")
waitFor("notices joins with own PIN") { noticesClient.accessMode == .notices && noticesClient.remoteState != nil }
require(noticesClient.remoteState!.tracks.isEmpty && noticesClient.remoteState!.regions.isEmpty && noticesClient.remoteState!.projects == nil, "notices has no workspace controls")
noticesClient.testUnchecked(.init(project: project, action: .play))
noticesClient.testUnchecked(.init(project: project, action: .remotePanel, value: 1))
noticesClient.testUnchecked(.init(project: project, action: .timerStart, value: 60))
noticesClient.send(.init(project: project, action: .remotePanel, value: 3))
noticesClient.send(.init(project: project, action: .noticeSend, value: -1, text: "Stage ready"))
waitFor("notices subscribes and sends") { noticesClient.remoteState?.message == "panel-3" && noticeCommands == [.noticeSend] }
require(noticesHost.setNoticesPIN("4567"), "notices PIN can change")
waitFor("changed notices PIN revokes grant") { noticesClient.accessMode == nil }
noticesClient.testUnchecked(.init(project: project, action: .noticeClear))
require(noticesHost.setNoticesPIN(""), "empty notices PIN removes protection")
noticesClient.requestAccess(.notices)
waitFor("unprotected notices access") { noticesClient.accessMode == .notices }
require(noticeCommands == [.noticeSend], "revoked notice commands were rejected")
noticesClient.stop(); noticesHost.stop()
print("PASS: independent notices authentication, restricted commands and revocation")

let policy = DAWRemoteAccessPolicy()
require(policy.setPIN("0123") && !policy.setPIN("12") && !policy.setPIN("abcd"), "PIN format exact ASCII four digits or empty")
let now = Date()
for _ in 0..<5 { require(policy.authorize(.init(mode: .director, pin: "9999"), now: now).mode == nil, "bad PIN rejected") }
require(policy.authorize(.init(mode: .director, pin: "0123"), now: now).mode == nil, "shared retry budget blocks guessing")
require(policy.authorize(.init(mode: .observer), now: now).mode == .observer, "observer stays available during PIN delay")
require(policy.authorize(.init(mode: .director, pin: "0123"), now: now.addingTimeInterval(31)).mode == .director, "correct PIN works after delay")
print("REMOTE_DIRECTOR_PIN_HOST_AUTHORITY_OBSERVER_READ_ONLY_MULTICLIENT_INDEPENDENT_TP_AND_RECONNECT_OK")

let credentialSuite = "catlive.remote.credentials-test-" + UUID().uuidString
let credentialPreferences = UserDefaults(suiteName: credentialSuite)!
defer { credentialPreferences.removePersistentDomain(forName: credentialSuite) }
let persistedPolicy = DAWRemoteAccessPolicy(preferences: credentialPreferences)
require(persistedPolicy.setPIN("0742"), "PIN can be saved")
require(persistedPolicy.setPIN("0987", mode: .notices), "notices PIN can be saved separately")
let storedCredential = credentialPreferences.data(forKey: "catlive.remote.directorPIN")!
require(String(data: storedCredential, encoding: .utf8)?.contains("0742") == false, "preferences contain digest and salt, not the PIN")
let loadedPolicy = DAWRemoteAccessPolicy(preferences: credentialPreferences)
require(loadedPolicy.authorize(.init(mode: .notices, pin: "0987")).mode == .notices, "notices PIN survives restart")
require(loadedPolicy.authorize(.init(mode: .notices, pin: "0742")).mode == nil, "director PIN cannot access notices after restart")
require(loadedPolicy.requiresPIN && loadedPolicy.authorize(.init(mode: .director, pin: "0742")).mode == .director, "PIN survives app restart")
require(loadedPolicy.setPIN("") && !DAWRemoteAccessPolicy(preferences: credentialPreferences).requiresPIN, "empty PIN removes stored credential")
print("REMOTE_DIRECTOR_PIN_PERSISTENCE_REMOVAL_AND_OBSERVER_SETLIST_SELECTION_QUEUE_OK")

// Section selection is a director command, with the same authoritative playback banks as the Mac.
let sectionID = UUID(), nextSectionRegion = UUID()
let sectionCommand = DAWRemoteCommand(project: project, song: song, action: .queueSection, target: sectionID)
require(sectionCommand.valid, "section command requires a valid target")
require(!DAWRemoteCommand(project: project, song: song, action: .queueSection).valid, "section target cannot be absent")
require(DAWRemoteAccessRules.allows(sectionCommand, mode: .director), "director may queue sections")
require(!DAWRemoteAccessRules.allows(sectionCommand, mode: .observer), "observer cannot queue sections")
if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(sectionCommand)) {
    require(decoded.action == .queueSection && decoded.target == sectionID, "section command roundtrip")
} else { fatalError("section command packet") }
var sectionFixture = fixture
sectionFixture.markers = [.init(id: sectionID, name: "Refrão", position: 3, color: 0xffcc00, section: true)]
sectionFixture.sectionPlayback = .init(currentRegion: regionID, secondaryRegion: nextSectionRegion, position: 2,
    secondaryPosition: 12, queuedMarker: sectionID, queueStartedAt: 1, nextTrigger: 3)
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(sectionFixture)) {
    require(decoded.sectionPlayback == sectionFixture.sectionPlayback && decoded.markers == sectionFixture.markers,
        "both section banks, Sub Play position, queued target and countdown survive the bridge")
} else { fatalError("section state packet") }
sectionFixture.sectionPlayback?.nextTrigger = .nan
require(!sectionFixture.valid, "invalid section timing rejected")
print("REMOTE_SECTIONS_OK")

var displaysFixture = fixture
displaysFixture.songDisplays = .init(current: "First", currentBPM: 100, next: "Next", nextBPM: 125,
    queued: "Queued", queuedBPM: nil, playlistSeconds: 600)
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(displaysFixture)) {
    require(decoded.songDisplays == displaysFixture.songDisplays, "Mac/iPad song names, optional BPM and playlist duration match")
} else { fatalError("song display packet") }
print("REMOTE_SONG_DISPLAYS_OK")

var importedGainState = fixture
importedGainState.tracks[0].clips = [.init(id: UUID(), name: "Imported high gain", start: 0, duration: 4, gain: 27.039209)]
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(importedGainState)) {
    require(decoded.tracks[0].clips[0].gain == 27.039209, "imported gain above editor range must not block Director state")
} else { fatalError("Missing imported gain state") }
print("REMOTE_IMPORTED_GAIN_DIRECTOR_STATE_OK")
let gainHost = DAWRemoteSession(role: .host, name: "Imported gain host")
let gainClient = DAWRemoteSession(role: .client, name: "Director")
gainHost.stateProvider = { importedGainState }
let gainEndpoint = try gainHost.testListen()
gainClient.testConnect(gainEndpoint)
waitFor("Director receives high-gain imported project instead of waiting indefinitely") { gainClient.remoteState?.tracks.first?.clips.first?.gain == 27.039209 }
gainClient.stop(); gainHost.stop()
print("REMOTE_IMPORTED_GAIN_DIRECTOR_LIVE_CONNECTION_OK")

let bypassCommand = DAWRemoteCommand(project: project, action: .toggleMultiLoopBypass)
require(bypassCommand.valid, "global bypass is a target-free command")
if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(bypassCommand)) {
    require(decoded.action == .toggleMultiLoopBypass, "global bypass command roundtrip")
} else { fatalError("bypass command packet") }
var bypassFixture = fixture
bypassFixture.multiLoopsBypassed = true
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(bypassFixture)) {
    require(decoded.multiLoopsBypassed == true, "Remote reflects the host bypass state")
} else { fatalError("bypass state packet") }
print("REMOTE_GLOBAL_MULTILOOP_BYPASS_COMMAND_AND_STATE_OK")

let liveCommand = DAWRemoteCommand(project: project, action: .toggleSetlistLive)
require(liveCommand.valid, "Live toggle is a target-free command")
require(DAWRemoteAccessRules.allows(liveCommand, mode: .director), "Director may toggle Live")
require(!DAWRemoteAccessRules.allows(liveCommand, mode: .observer), "Observer cannot toggle Live")
require(!DAWRemoteAccessRules.allows(liveCommand, mode: .notices), "Messages mode cannot toggle Live")
require(!DAWRemoteAccessRules.allows(liveCommand, mode: nil), "Unauthenticated connection cannot toggle Live")
require(!DAWRemoteCommand(project: project, action: .toggleSetlistLive, target: UUID()).valid, "Live cannot target a region")
require(!DAWRemoteCommand(project: project, action: .toggleSetlistLive, value: 1).valid, "Live cannot inject arbitrary numeric arguments")
if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(liveCommand)) {
    require(decoded.action == .toggleSetlistLive, "Live command roundtrip")
} else { fatalError("Live command packet") }
var liveFixture = fixture
let playedRegion = UUID()
liveFixture.setlistLiveEnabled = true
liveFixture.playedLiveRegionIDs = [playedRegion]
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(liveFixture)) {
    require(decoded.setlistLiveEnabled == true && decoded.playedLiveRegionIDs == [playedRegion], "Remote reflects Live and played history")
} else { fatalError("Live state packet") }
liveFixture.setlistLiveEnabled = false
liveFixture.playedLiveRegionIDs = []
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(liveFixture)) {
    require(decoded.setlistLiveEnabled == false && decoded.playedLiveRegionIDs == [], "Remote receives cleared played markings when the host disables Live")
} else { fatalError("disabled Live state packet") }
liveFixture.playedLiveRegionIDs = [playedRegion, playedRegion]
require(!liveFixture.valid, "Duplicate played identifiers cannot inflate Remote snapshots")
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(fixture)) {
    require(decoded.setlistLiveEnabled == nil && decoded.playedLiveRegionIDs == nil, "Legacy host snapshots decode without Live fields")
} else { fatalError("legacy Live state packet") }
print("REMOTE_SETLIST_LIVE_COMMAND_AUTHORIZATION_HISTORY_AND_LEGACY_STATE_OK")


var themed = fixture
themed.gridBackgroundColor = 0x123456; themed.gridPrimaryColor = 0x234567; themed.gridSecondaryColor = 0x345678
themed.playCursorColor = 0x456789; themed.editCursorColor = 0x56789a; themed.subPlayCursorColor = 0x6789ab
themed.editPosition = 2; themed.subPlayPosition = 8; themed.setlistFontStyle = 2
themed.regions[0].nameColor = 0xab1234
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(themed)) {
    require(decoded.gridBackgroundColor == themed.gridBackgroundColor && decoded.gridPrimaryColor == themed.gridPrimaryColor && decoded.gridSecondaryColor == themed.gridSecondaryColor, "Mac grid colors survive Remote transport")
    require(decoded.playCursorColor == themed.playCursorColor && decoded.editCursorColor == themed.editCursorColor && decoded.subPlayCursorColor == themed.subPlayCursorColor, "all three cursor colors survive Remote transport")
    require(decoded.editPosition == 2 && decoded.subPlayPosition == 8, "Remote receives independent cursor positions")
    require(decoded.setlistFontStyle == 2 && decoded.regions[0].nameColor == 0xab1234, "Mac setlist font and song text color reach iPad")
} else { fatalError("theme state packet") }
print("REMOTE_MAC_TIMELINE_CURSOR_AND_SETLIST_APPEARANCE_OK")

var markerKinds = fixture
markerKinds.markers = [
    .init(id: UUID(), name: "Normal", position: 1, color: 0x123456),
    .init(id: UUID(), name: "TRECHO", position: 2, color: 0xabcdef, section: true),
    .init(id: UUID(), name: "0st Música unificada", position: 3, color: 0xffcc00,
          unifiedRegionID: UUID(), sourceRegionID: UUID())
]
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(markerKinds)) {
    require(decoded.markers == markerKinds.markers, "normal, section and unified marker styles survive Remote transport")
} else { fatalError("Missing marker style state") }
print("REMOTE_MAC_MARKER_STYLES_OK")

var subGrid = fixture
let mainGridID = UUID(), subGridID = UUID(), otherGridID = UUID(), childGridID = UUID()
subGrid.timelineRegions = [
    .init(id: mainGridID, name: "Principal", start: 0, end: 30, color: 0x111111),
    .init(id: subGridID, name: "SubPlay", start: 40, end: 80, color: 0x222222),
    .init(id: otherGridID, name: "Fila", start: 90, end: 120, color: 0x333333)
]
subGrid.regions = subGrid.timelineRegions
subGrid.playing = true; subGrid.position = 10; subGrid.currentRegion = mainGridID; subGrid.gridRegion = mainGridID
subGrid.focusedRegion = otherGridID; subGrid.queuedRegion = otherGridID
require(DAWRemoteTimelinePresentation.region(in: subGrid)?.id == mainGridID, "queue/focus cannot move the playing grid")
subGrid.subPlaying = true; subGrid.subPlayPosition = 47
require(DAWRemoteTimelinePresentation.region(in: subGrid)?.id == subGridID, "SubPlay takes grid priority over main, queue and focus")
subGrid.subPlayPosition = 52
require(DAWRemoteTimelinePresentation.region(in: subGrid)?.id == subGridID, "moving SubPlay keeps its song visible")
var promotedGrid = subGrid
promotedGrid.subPlaying = false; promotedGrid.position = 52; promotedGrid.currentRegion = subGridID; promotedGrid.gridRegion = subGridID
require(DAWRemoteTimelinePresentation.region(in: promotedGrid)?.id == DAWRemoteTimelinePresentation.region(in: subGrid)?.id,
        "promotion preserves the displayed song as the normal playback cursor takes over")
subGrid.subPlaying = false
require(DAWRemoteTimelinePresentation.region(in: subGrid)?.id == mainGridID, "cancelling SubPlay returns the viewport to main playback")
subGrid.subPlaying = true
subGrid.timelineRegions.append(.init(id: childGridID, name: "Música da gaveta", start: 50, end: 60, color: 0x444444, parentRegion: subGridID))
require(DAWRemoteTimelinePresentation.region(in: subGrid)?.id == subGridID, "a drawer song retains its special region's grid")
subGrid.subPlayPosition = 85
require(DAWRemoteTimelinePresentation.region(in: subGrid) == nil, "SubPlay outside a region cannot show the unrelated main song")
subGrid.subPlaying = false; subGrid.playing = false; subGrid.gridRegion = otherGridID
require(DAWRemoteTimelinePresentation.region(in: subGrid)?.id == otherGridID, "stopped grid follows the selected song")
print("REMOTE_SUBPLAY_GRID_PRIORITY_PROMOTION_CANCEL_AND_UNIFIED_REGION_OK")

// A closed Mac/disabled Remote keeps the last workspace behind the reconnect
// modal, blocks commands and reauthorizes before releasing the modal.
extension DAWRemoteSession {
    func testRediscover(_ endpoint: NWEndpoint) {
        guard let peer = preferredPeer else { fatalError("Missing selected Mac") }
        peers = [peer]; endpoints = [peer.id: endpoint]
        attemptReconnect()
    }
}
let resumeHost = DAWRemoteSession(role: .host, name: "Resume Mac")
let resumeClient = DAWRemoteSession(role: .client, name: "Resume iPad")
require(resumeHost.setDirectorPIN("1234"), "initial resume PIN")
var resumeState = fixture
resumeHost.stateProvider = { resumeState }
var resumeCommands = 0
resumeHost.commandHandler = { _ in resumeCommands += 1 }
let resumeEndpoint = try resumeHost.testListen()
resumeClient.testConnect(resumeEndpoint, access: .director, pin: "1234")
waitFor("initial authorized resume state") { resumeClient.remoteState != nil }
resumeHost.stop()
waitFor("host stop displays reconnection modal and retains workspace") { resumeClient.reconnecting && !resumeClient.connected }
require(resumeClient.remoteState?.project == project && resumeClient.presentationAccess == .director && resumeClient.accessMode == nil, "stale presentation is kept without command authority")
resumeClient.send(.init(project: project, action: .play))
require(resumeCommands == 0, "disconnected controls cannot execute or enqueue commands")
resumeState.message = "Fresh after restart"
let resumedEndpoint = try resumeHost.testListen()
resumeClient.testRediscover(resumedEndpoint)
waitFor("same Mac reauthorizes and replaces workspace before hiding modal") {
    !resumeClient.reconnecting && resumeClient.remoteState?.message == "Fresh after restart" && resumeClient.accessMode == .director
}
resumeHost.stop()
waitFor("second outage") { resumeClient.reconnecting && !resumeClient.connected }
require(resumeHost.setDirectorPIN("4567"), "PIN changes while disconnected")
let changedPINEndpoint = try resumeHost.testListen()
resumeClient.testRediscover(changedPINEndpoint)
waitFor("changed PIN returns to access picker") {
    resumeClient.connected && !resumeClient.reconnecting && resumeClient.accessMode == nil && !resumeClient.accessError.isEmpty
}
require(resumeClient.remoteState == nil && resumeClient.presentationAccess == nil, "reconnection cannot bypass changed credentials")
resumeClient.requestAccess(.director, pin: "4567")
waitFor("new PIN restores session") { resumeClient.remoteState != nil }
resumeClient.stop(); resumeHost.stop()
require(!resumeClient.reconnecting && resumeClient.remoteState == nil, "explicit exit clears reconnect intention")
print("REMOTE_DISCONNECT_MODAL_RETAINED_WORKSPACE_AUTO_REAUTH_FRESH_STATE_CHANGED_PIN_AND_EXIT_OK")

for panel in DAWRemotePhonePanel.allCases {
    require(panel.selecting(.grid) == .grid, "Grid closes every phone panel")
    require(panel.selecting(.mixer) == (panel == .mixer ? .grid : .mixer), "Mixer toggles exclusively")
    require(panel.selecting(.setlist) == (panel == .setlist ? .grid : .setlist), "Setlist toggles exclusively")
    require(panel.togglingFooterParts() == (panel == .sections ? .setlist : .sections),
        "Persistent Parts footer returns to Setlist instead of hiding into Grid")
}
require(DAWRemotePhonePanel.teleprompter1.subscription == 1 && DAWRemotePhonePanel.teleprompter2.subscription == 2 && DAWRemotePhonePanel.notices.subscription == 3, "phone subscribes only to its visible projection panel")
print("REMOTE_PHONE_EXCLUSIVE_MIXER_SETLIST_GRID_AND_PROJECTION_SUBSCRIPTIONS_OK")

var sectionsDisplayFixture = fixture
for vertical in [false, true] {
    sectionsDisplayFixture.sectionListVertical = vertical
    if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(sectionsDisplayFixture)) {
        require(decoded.sectionListVertical == vertical, "Legacy section display field remains decodable")
    } else { fatalError("section display mode packet") }
}
print("REMOTE_SECTION_DISPLAY_MODE_ROUNDTRIP_OK")

let cancelSection = DAWRemoteCommand(project: project, action: .cancelSection)
require(cancelSection.valid && DAWRemoteAccessRules.allows(cancelSection, mode: .director), "director can cancel only the queued section")
require(!DAWRemoteAccessRules.allows(cancelSection, mode: .observer) && !DAWRemoteAccessRules.allows(cancelSection, mode: .notices), "read-only and notices roles cannot cancel a section")
require(!DAWRemoteCommand(project: project, action: .cancelSection, target: UUID()).valid, "section cancellation has no ambiguous target")
if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(cancelSection)) {
    require(decoded.action == .cancelSection, "dedicated cancellation survives transport")
} else { fatalError("cancel section packet") }

// Peak numbers are held by the host, not locally sampled or decayed by Remote.
var peakFixture = fixture
peakFixture.masterPeakDB = -24
peakFixture.tracks[0].peakDB = -6.12
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(peakFixture)) {
    require(decoded.masterPeakDB == -24 && decoded.tracks[0].peakDB == -6.12, "Master/track held peaks roundtrip, including threshold")
} else { fatalError("held peak state packet") }
peakFixture.masterPeakDB = nil; peakFixture.tracks[0].peakDB = nil
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(peakFixture)) {
    require(decoded.masterPeakDB == nil && decoded.tracks[0].peakDB == nil, "Reset clears number; old host state also remains compatible")
} else { fatalError("cleared peak state packet") }
for invalidPeak in [-24.01, Double.nan, Double.infinity] {
    peakFixture.masterPeakDB = invalidPeak
    require(!peakFixture.valid, "Master rejects invalid/below-threshold numeric peaks")
    peakFixture.masterPeakDB = nil; peakFixture.tracks[0].peakDB = invalidPeak
    require(!peakFixture.valid, "Track rejects invalid/below-threshold numeric peaks")
    peakFixture.tracks[0].peakDB = nil
}
for target in [Optional<UUID>.none, Optional(trackID)] {
    let reset = DAWRemoteCommand(project: project, song: song, action: .resetMeterPeak, target: target)
    require(reset.valid && DAWRemoteAccessRules.allows(reset, mode: .director), "Director may reset master/track")
    for mode in [Optional<DAWRemoteAccess>.none, .observer, .notices] {
        require(!DAWRemoteAccessRules.allows(reset, mode: mode), "Other roles cannot reset held peaks")
    }
    if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(reset)) {
        require(decoded.action == .resetMeterPeak && decoded.target == target, "Peak reset command preserves target")
    } else { fatalError("reset peak command packet") }
}
require(!DAWRemoteCommand(project: project, action: .resetMeterPeak, value: 1).valid, "Peak reset rejects numeric payload")
print("REMOTE_HELD_NUMERIC_PEAKS_MASTER_TRACK_RESET_ROLE_AUTH_AND_LEGACY_OK")

var drawerFixture = fixture
let drawerChild = UUID(), plainRegion = UUID()
drawerFixture.regions.append(.init(id: plainRegion, name: "Regular", start: 11, end: 20, color: 0x123456))
drawerFixture.timelineRegions = drawerFixture.regions + [.init(id: drawerChild, name: "Inside", start: 1, end: 5, color: 0x123456, parentRegion: regionID)]
require(DAWRemoteSetlistPresentation.canToggleDrawer(regionID, in: drawerFixture), "Unified parent admits local long-press drawer toggle")
require(!DAWRemoteSetlistPresentation.canToggleDrawer(plainRegion, in: drawerFixture), "Ordinary song cannot toggle drawer")
require(!DAWRemoteSetlistPresentation.canToggleDrawer(drawerChild, in: drawerFixture), "Child song cannot toggle its parent's drawer")
require(!DAWRemoteSetlistPresentation.canToggleDrawer(UUID(), in: drawerFixture), "Unknown region cannot toggle drawer")
let closedRows = DAWRemoteSetlistPresentation.rows(in: drawerFixture, expanded: [], query: "")
require(closedRows.map(\.id) == [regionID, plainRegion] && closedRows.map(\.hasDrawer) == [true, false], "Only parent row installs long-press gesture")
let expandedRows = DAWRemoteSetlistPresentation.rows(in: drawerFixture, expanded: [regionID], query: "")
require(expandedRows.map(\.id) == [regionID, drawerChild, plainRegion] && expandedRows[1].child && !expandedRows[1].hasDrawer, "Opening drawer adds children in place; child keeps ordinary gestures")
require(DAWRemoteSetlistPresentation.rows(in: drawerFixture, expanded: [], query: "").map(\.id) == closedRows.map(\.id), "Closing drawer restores ordinary list")
require(drawerFixture.focusedRegion == fixture.focusedRegion && drawerFixture.currentRegion == fixture.currentRegion, "Local drawer presentation never changes host selection/playback")
drawerFixture.playing = true
for activeID in [regionID, drawerChild, plainRegion] {
    drawerFixture.currentRegion = activeID
    drawerFixture.focusedRegion = activeID
    require(DAWRemoteSetlistPresentation.rows(in: drawerFixture, expanded: [], query: "").map(\.id) == closedRows.map(\.id),
        "Playing or focusing the parent, child or another song never opens a closed drawer")
    require(DAWRemoteSetlistPresentation.rows(in: drawerFixture, expanded: [regionID], query: "").map(\.id) == expandedRows.map(\.id),
        "Playback and focus retain a drawer that the user manually opened")
}
drawerFixture.playing = false
require(DAWRemoteSetlistPresentation.rows(in: drawerFixture, expanded: [], query: "").map(\.id) == closedRows.map(\.id),
    "Stopping playback never changes manual drawer visibility")
print("REMOTE_LONG_PRESS_DRAWER_PARENT_ELIGIBILITY_OPEN_CLOSE_WITHOUT_SELECTION_OK")

var sectionBoundaryFixture = fixture
sectionBoundaryFixture.sectionPlayback = .init(currentRegion: regionID, secondaryRegion: nil, position: 8,
    secondaryPosition: nil, queuedMarker: UUID(), queueStartedAt: 7, nextTrigger: 18.5, currentEnd: 18.5)
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(sectionBoundaryFixture)) {
    require(decoded.sectionPlayback?.currentEnd == 18.5 && decoded.sectionPlayback?.nextTrigger == 18.5,
        "Ignore Next tail beyond region end remains the last section progress and seek countdown boundary")
} else { fatalError("section actual end packet") }
sectionBoundaryFixture.sectionPlayback?.currentEnd = nil
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(sectionBoundaryFixture)) {
    require(decoded.sectionPlayback?.currentEnd == nil, "Older host without currentEnd keeps region end fallback")
} else { fatalError("legacy section actual end packet") }
for invalidEnd in [-0.01, Double.nan, Double.infinity] {
    sectionBoundaryFixture.sectionPlayback?.currentEnd = invalidEnd
    require(!sectionBoundaryFixture.valid, "Current section end rejects negative and non-finite times")
}
print("REMOTE_SECTION_ACTUAL_END_COUNTDOWN_TAIL_AND_LEGACY_BOUNDARY_OK")

require(DAWRemoteSidebarGesture.shouldReveal(horizontal: 36, vertical: 0), "Right edge pull at threshold reveals sidebar")
require(DAWRemoteSidebarGesture.shouldReveal(horizontal: 90, vertical: 30), "Dominantly horizontal pull reveals sidebar")
require(DAWRemoteSidebarGesture.shouldBegin(horizontal: 2, vertical: 1), "Native delegate accepts a slow rightward swipe before completion distance")
require(!DAWRemoteSidebarGesture.shouldBegin(horizontal: 1, vertical: 2), "Native delegate fails vertical intent before taking ownership of the scroll touch")
require(!DAWRemoteSidebarGesture.shouldBegin(horizontal: -2, vertical: 0), "Native delegate rejects leftward intent")
for (x, y) in [(0.0, 0.0), (35.9, 0), (-60, 0), (40, 40), (0, 80), (100, 100), (Double.nan, 0), (60, Double.infinity)] {
    require(!DAWRemoteSidebarGesture.shouldReveal(horizontal: x, vertical: y), "Taps, vertical scrolling and invalid drag cannot reveal sidebar")
}
print("REMOTE_SIDEBAR_REVEAL_DIRECTION_THRESHOLD_AND_SCROLL_REJECTION_OK")

// Retained layout must pass new control values through without repartitioning
// thousands of clips for each incoming transport/peak packet.
let layoutCache = DAWRemoteItemLayoutCache()
let layoutRegion = DAWRemoteState.Region(id: UUID(), name: "Cache region", start: 0, end: 160, color: 0x123456)
let manyTracks: [DAWRemoteState.Track] = (0..<500).map { index in
    .init(id: UUID(), name: "Track \(index)", color: 0x828282, volume: 1, pan: 0, mute: false, solo: false,
          clips: (0..<80).reversed().map { clip in
              .init(id: UUID(), name: "Clip \(clip)", start: Double(clip), duration: 2)
          })
}
let cacheColdStart = ProcessInfo.processInfo.systemUptime
let coldLayout = layoutCache.tracks(manyTracks, within: layoutRegion)
let cacheColdTime = ProcessInfo.processInfo.systemUptime - cacheColdStart
require(layoutCache.rebuildCount == 500, "Initial layout builds exactly one partition per track")
// Independent array storage models newly decoded wire packets, rather than
// benchmarking Array equality against its own backing buffer.
let layoutPackets = (0..<24).map { _ in manyTracks.map { track -> DAWRemoteState.Track in
    var copy = track; copy.clips = track.clips.map { $0 }; return copy
} }
let uncachedStart = ProcessInfo.processInfo.systemUptime
var uncachedChecksum = 0
for packet in layoutPackets {
    uncachedChecksum += DAWRemoteItemLayout.tracks(packet, within: layoutRegion).reduce(0) { $0 + ($1.laneCount ?? 0) }
}
let uncachedTime = ProcessInfo.processInfo.systemUptime - uncachedStart
let warmStart = ProcessInfo.processInfo.systemUptime
var cachedChecksum = 0
for packet in layoutPackets {
    cachedChecksum += layoutCache.tracks(packet, within: layoutRegion).reduce(0) { $0 + ($1.laneCount ?? 0) }
}
let warmTime = ProcessInfo.processInfo.systemUptime - warmStart
require(uncachedChecksum == cachedChecksum && layoutCache.rebuildCount == 500, "24 independent snapshots reuse all 500 track partitions")
var changedTracks = manyTracks
changedTracks[0].volume = 0.5; changedTracks[0].pan = -0.25; changedTracks[0].mute = true
changedTracks[0].peakDB = -4; changedTracks[0].name = "Renamed"; changedTracks[0].heightScale = 1.8
let controlsLayout = layoutCache.tracks(changedTracks, within: layoutRegion)
require(layoutCache.rebuildCount == 500 && controlsLayout[0].volume == 0.5 && controlsLayout[0].pan == -0.25 &&
    controlsLayout[0].mute && controlsLayout[0].peakDB == -4 && controlsLayout[0].name == "Renamed" && controlsLayout[0].heightScale == 1.8,
    "New track scalars and height pass through without rebuilding clip geometry")
changedTracks[0].clips[0].start = 0.25; changedTracks[0].clips[0].name = "Edited item"
changedTracks[0].clips[0].muted = true; changedTracks[0].clips[0].gain = 0.75
let editedLayout = layoutCache.tracks(changedTracks, within: layoutRegion)
let editedID = changedTracks[0].clips[0].id
require(layoutCache.rebuildCount == 501 && editedLayout[0].clips.first(where: { $0.id == editedID })?.name == "Edited item" &&
    editedLayout[0].clips.first(where: { $0.id == editedID })?.muted == true, "One edited clip only rebuilds its own track and refreshes metadata")
var changedRegion = layoutRegion; changedRegion.start = 50
require(layoutCache.tracks(changedTracks, within: changedRegion) == DAWRemoteItemLayout.tracks(changedTracks, within: changedRegion),
    "Region bounds invalidate all affected lane partitions")
require(layoutCache.rebuildCount == 1001, "Region change rebuilds each track exactly once")
let afterRegionBuilds = layoutCache.rebuildCount
let removedTrack = changedTracks.removeLast()
_ = layoutCache.tracks(changedTracks, within: changedRegion)
changedTracks.append(removedTrack)
_ = layoutCache.tracks(changedTracks, within: changedRegion)
require(layoutCache.rebuildCount == afterRegionBuilds + 1, "Removed track cache is discarded and restored track rebuilds once")
print(String(format: "REMOTE_LAYOUT_CACHE_500_TRACKS_40000_CLIPS_COLD_MS=%.2f_UNCACHED_24_MS=%.2f_WARM_24_MS=%.2f_REBUILDS_12000_TO_0", cacheColdTime * 1000, uncachedTime * 1000, warmTime * 1000))

let rowsCache = DAWRemoteSetlistRowsCache()
var rowPacket = drawerFixture
let cachedClosedIDs = rowsCache.rows(in: rowPacket, expanded: [], query: "").map(\.id)
for tick in 0..<100 {
    rowPacket.position = Double(tick) / 10; rowPacket.playing = tick > 0
    rowPacket.currentRegion = tick % 2 == 0 ? regionID : drawerChild
    rowPacket.focusedRegion = rowPacket.currentRegion
    require(rowsCache.rows(in: rowPacket, expanded: [], query: "").map(\.id) == cachedClosedIDs, "Position/focus never opens or rebuilds cached drawer rows")
}
require(rowsCache.rebuildCount == 1, "100 transport packets reuse setlist rows")
_ = rowsCache.rows(in: rowPacket, expanded: [regionID], query: "")
require(rowsCache.rebuildCount == 2, "Manual drawer action rebuilds once")
rowPacket.timelineRegions[rowPacket.timelineRegions.count - 1].name = "Renamed child"
require(rowsCache.rows(in: rowPacket, expanded: [regionID], query: "").contains(where: { $0.region.name == "Renamed child" }), "Cached drawer name follows item edits")
require(rowsCache.rebuildCount == 3, "Metadata edit invalidates rows")
require(rowsCache.rows(in: rowPacket, expanded: [regionID], query: "Renamed child").count == 1, "Search remains current after caching")

var mixerComparison = fixture.tracks[0]
mixerComparison.clips[0].name = "Grid-only edit"; mixerComparison.clips[0].start += 1
require(fixture.tracks[0].hasSameMixerControls(as: mixerComparison), "Grid-only changes do not rebuild mixer controls")
for mutate: (inout DAWRemoteState.Track) -> Void in [
    { $0.id = UUID() }, { $0.name += " changed" }, { $0.color = 0x112233 }, { $0.volume = 0.8 },
    { $0.pan = 0.4 }, { $0.mute.toggle() }, { $0.solo.toggle() }, { $0.nameColor = 0xaabbcc },
    { $0.emphasized = false }, { $0.silenced = false }, { $0.linkedTrack = UUID() }, { $0.peakDB = -7 }, { $0.canMeter = false }
] {
    var changed = fixture.tracks[0]; mutate(&changed)
    require(!fixture.tracks[0].hasSameMixerControls(as: changed), "Every visible mixer control invalidates its row")
}
var meterCapability = fixture
meterCapability.tracks[0].canMeter = false
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(meterCapability)) {
    require(decoded.tracks[0].canMeter == false, "Non-audio readout capability roundtrips independently of track name")
} else { fatalError("meter capability") }
require(fixture.tracks[0].canMeter == nil, "Legacy tracks retain meter eligibility when capability is absent")
print("REMOTE_CACHED_ROWS_MIXER_SCALARS_AND_METER_CAPABILITY_INVALIDATION_OK")

require(DAWRemoteSnapshotComparison.differs(fixture, from: nil), "First snapshot publishes")
require(!DAWRemoteSnapshotComparison.differs(fixture, from: fixture), "Identical snapshot remains suppressed")
var markedLiveSnapshot = fixture
markedLiveSnapshot.setlistLiveEnabled = true
markedLiveSnapshot.playedLiveRegionIDs = [regionID, drawerChild]
var clearedLiveSnapshot = markedLiveSnapshot
clearedLiveSnapshot.setlistLiveEnabled = false
clearedLiveSnapshot.playedLiveRegionIDs = []
require(DAWRemoteSnapshotComparison.differs(clearedLiveSnapshot, from: markedLiveSnapshot),
    "Disabling Live publishes removal of both unified-parent and drawer-song markings without a transport change")
var clearedMarksSnapshot = markedLiveSnapshot
clearedMarksSnapshot.playedLiveRegionIDs = []
require(DAWRemoteSnapshotComparison.differs(clearedMarksSnapshot, from: markedLiveSnapshot),
    "Clearing played markings alone invalidates Remote presentation")
for mutate: (inout DAWRemoteState) -> Void in [
    { $0.position += 0.1 }, { $0.subPlayPosition = 4 }, { $0.editPosition = 3 }, { $0.playing.toggle() },
    { $0.tracks[0].clips[0].name += " edit" }, { $0.tracks[0].clips[0].duration += 1 },
    { $0.tracks[0].name += " edit" }, { $0.tracks[0].peakDB = -5 }, { $0.selectedPlaylist = UUID() },
    { $0.setlistLiveEnabled = true }, { $0.playedLiveRegionIDs = [regionID] }, { $0.project = UUID() }
] {
    var changed = fixture; mutate(&changed)
    require(DAWRemoteSnapshotComparison.differs(changed, from: fixture) == (changed != fixture), "Fast snapshot comparison preserves full-state change semantics")
}
print("REMOTE_SNAPSHOT_TRANSPORT_FAST_PATH_AND_METADATA_FALLBACK_OK")
