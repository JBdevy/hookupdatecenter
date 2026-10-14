// App presentation is local even though it shares the Remote's view DTOs.
// Compiled beside production sources: assert that no networking primitive starts.
extension DAWRemoteSession {
    fileprivate func requireLocalOnly(_ label: String) {
        require(isLocalWorkspace && enabled && connected && accessMode == .director, label + ": native authority")
        require(browser == nil && listener == nil && channel == nil && discoveryPathMonitor == nil,
                label + ": no discovery, listener, path monitor or channel")
        require(stateTimer == nil && reconnectTimer == nil && discoveryRetryTimer == nil,
                label + ": no duplicate publication/transport timer")
    }
}
var localFixture = fixture
localFixture.project = UUID()
localFixture.tracks[0].clips[0].waveform = [0.02, 0.4, 1, 0.1]
localFixture.tracks[0].clips[0].waveformLoopLength = 4
localFixture.tracks[0].clips[0].waveformOffset = 1
localFixture.tracks[0].clips[0].waveformRate = 1.2
let localWorkspace = DAWRemoteSession(role: .client, name: "Standalone iPad")
let untouchedRemote = DAWRemoteSession.shared.remoteState
var localCommands: [DAWRemoteCommand.Action] = []
var localPanels: [Int] = []
localWorkspace.stateProviderForSession = { session in
    localPanels.append(session.requestedPanel)
    return localFixture
}
localWorkspace.commandHandler = { command in
    localCommands.append(command.action)
    if command.action == .play { localFixture.playing = true }
    if command.action == .stop { localFixture.playing = false }
}
localWorkspace.noticeSendHandler = { $0.valid && $0.action == .noticeSend && $0.text == "Local message" }
localWorkspace.startLocalWorkspace()
localWorkspace.requireLocalOnly("start")
require(localWorkspace.remoteState?.tracks[0].clips[0].waveform == [0.02, 0.4, 1, 0.1], "Local PCM overview survives in-process projection")
localWorkspace.send(.init(project: localFixture.project, song: localFixture.song, action: .play))
require(localCommands == [.play] && localWorkspace.remoteState?.playing == true, "Play reaches local handler immediately without pairing")
localWorkspace.send(.init(project: UUID(), action: .stop))
localWorkspace.send(.init(project: localFixture.project, action: .volume, value: .nan))
require(localCommands == [.play] && localWorkspace.remoteState?.playing == true, "Stale project and invalid commands do not mutate local transport")
localWorkspace.send(.init(project: localFixture.project, action: .remotePanel, value: 2))
require(localPanels.last == 2, "Local TP subscription selects its requested projection")
var localDelivery: DAWRemoteNoticeDelivery?
localWorkspace.sendNotice(.init(project: localFixture.project, action: .noticeSend, value: -1, text: "Local message")) { localDelivery = $0 }
require(localDelivery == .accepted, "Local notice acknowledges actual handler acceptance")
localWorkspace.sendNotice(.init(project: UUID(), action: .noticeSend, value: -1, text: "Local message")) { localDelivery = $0 }
require(localDelivery == .rejected, "Local notice cannot target an old project")
var localClearCompleted = false
localWorkspace.sendNoticeClear(.init(project: localFixture.project, action: .noticeClear)) { localClearCompleted = true }
require(localClearCompleted && localCommands.last == .noticeClear, "Local notice withdrawal is synchronous and acknowledged")
localWorkspace.suspendForBackground()
localWorkspace.requireLocalOnly("background")
require(localWorkspace.remoteState?.playing == true, "Remote suspension cannot stop local presentation or audio")
let encodedLocal = try DAWRemoteWire.state(localFixture)
let localJSON = try JSONSerialization.jsonObject(with: Data(encodedLocal.dropFirst(4))) as! [String: Any]
let localClipJSON = ((localJSON["tracks"] as! [[String: Any]])[0]["clips"] as! [[String: Any]])[0]
require(localClipJSON["waveform"] == nil && localClipJSON["waveformLoopLength"] == nil && localClipJSON["waveformOffset"] == nil && localClipJSON["waveformRate"] == nil,
        "In-process PCM drawing data never extends or enlarges Remote network packets")
if case .state(let decoded) = try DAWRemoteWire.decode(encodedLocal) {
    require(decoded.tracks[0].clips[0].waveform == nil, "Remote decoder remains metadata-only")
} else { fatalError("Local wire roundtrip") }
let localBefore = localCommands.count
localWorkspace.endLocalWorkspace()
localWorkspace.send(.init(project: localFixture.project, action: .play))
require(!localWorkspace.enabled && !localWorkspace.connected && localWorkspace.remoteState == nil && localWorkspace.accessMode == nil,
        "Leaving native workspace retires local state")
require(localCommands.count == localBefore && localWorkspace.commandHandler == nil && localWorkspace.stateProviderForSession == nil,
        "Leaving native workspace releases handlers and rejects delayed controls")
require(DAWRemoteSession.shared.remoteState == untouchedRemote, "Local session never mutates the Remote singleton")
print("IPAD_STANDALONE_NO_NETWORK_DIRECT_COMMANDS_NOTICES_REAL_WAVEFORM_ISOLATION_AND_EXIT_OK")
