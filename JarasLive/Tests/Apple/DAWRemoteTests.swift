// Compiled with the production protocol/session sources by test-daw-remote.sh.
import AppKit
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
for command in [DAWRemoteCommand(project: project, action: .volume, value: -.infinity),
                DAWRemoteCommand(project: project, action: .volume, value: 5),
                DAWRemoteCommand(project: project, action: .pan, target: trackID, value: 2),
                DAWRemoteCommand(project: project, action: .selectRegion),
                DAWRemoteCommand(project: project, action: .seek, value: -1),
                DAWRemoteCommand(project: project, action: .pitch, target: regionID, value: 7),
                DAWRemoteCommand(project: project, action: .pitch, target: regionID, value: 0.5),
                DAWRemoteCommand(project: project, action: .pitch, value: 1)] {
    require((try? DAWRemoteWire.command(command)) == nil, "reject invalid command values")
}
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
observer.stop(); rolesHost.stop()
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
let storedCredential = credentialPreferences.data(forKey: "catlive.remote.directorPIN")!
require(String(data: storedCredential, encoding: .utf8)?.contains("0742") == false, "preferences contain digest and salt, not the PIN")
let loadedPolicy = DAWRemoteAccessPolicy(preferences: credentialPreferences)
require(loadedPolicy.requiresPIN && loadedPolicy.authorize(.init(mode: .director, pin: "0742")).mode == .director, "PIN survives app restart")
require(loadedPolicy.setPIN("") && !DAWRemoteAccessPolicy(preferences: credentialPreferences).requiresPIN, "empty PIN removes stored credential")
print("REMOTE_DIRECTOR_PIN_PERSISTENCE_REMOVAL_AND_OBSERVER_SETLIST_SELECTION_QUEUE_OK")
