// Included after DAWRemoteTests.swift by test-daw-remote.sh.
// Preview controls belong to the host, including when neither TP is open on the client.
require(fixture.previewActive == nil && fixture.previewPage == nil, "older hosts do not advertise Preview controls")
for active in [true, false] {
    var hostPreview = fixture
    hostPreview.previewActive = active; hostPreview.previewPage = 5
    if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(hostPreview)) {
        require(decoded.previewActive == active && decoded.previewPage == 5 && decoded.teleprompters == nil,
                "global Preview state updates and clears outside the TP panels")
    } else { fatalError("host Preview state") }
}
for control in [DAWRemoteCommand(project: project, action: .togglePreview),
                DAWRemoteCommand(project: project, action: .selectPreviewPage, value: 5)] {
    if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(control)) {
        require(decoded.action == control.action && decoded.value == control.value, "Preview control roundtrip")
        require(DAWRemoteAccessRules.allows(decoded, mode: .director), "director can control desktop Preview")
        require(!DAWRemoteAccessRules.allows(decoded, mode: .observer) && !DAWRemoteAccessRules.allows(decoded, mode: .notices),
                "view-only and notice access cannot change the host Preview")
    } else { fatalError("Preview control packet") }
}
for page in [-1.0, 6.0, 0.5] {
    require(!DAWRemoteCommand(project: project, action: .selectPreviewPage, value: page).valid, "invalid Preview block page rejected")
}
var invalidPreviewState = fixture; invalidPreviewState.previewPage = 6
require(!invalidPreviewState.valid, "out-of-range host Preview page rejected")
print("PASS: host Preview control, state synchronization and access permissions")

let unicodeNotice = String(repeating: "🎵", count: 500)
let noticeCommand = DAWRemoteCommand(project: project, song: song, action: .noticeSend, value: -1, text: unicodeNotice)
require(noticeCommand.valid, "500 non-ASCII characters remain a valid notice")
if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(noticeCommand)) {
    require(decoded.text == unicodeNotice && decoded.value == -1, "notice command survives bounded Unicode wire encoding")
} else { fatalError("notice command packet") }
require(!DAWRemoteCommand(project: project, song: song, action: .noticeSend, value: -2, text: "test").valid, "notice rejects invalid global slot")
require(!DAWRemoteCommand(project: project, song: song, action: .noticeSend, value: 3, text: "test").valid, "notice rejects out-of-bounds template slot")
require(!DAWRemoteCommand(project: project, song: song, action: .noticeSend, value: 0.5, text: "test").valid, "notice rejects fractional slots before host indexing")
require(!DAWRemoteCommand(project: project, song: song, action: .noticeSaveTemplate, value: -1, text: "test").valid, "global draft cannot overwrite a template")
require(!DAWRemoteCommand(project: project, song: song, action: .noticeSend, text: String(repeating: "x", count: 501)).valid, "notice text limit")
require(!DAWRemoteCommand(project: project, song: song, action: .play, text: "unrelated payload").valid, "transport command cannot carry notice text")
require(!DAWRemoteCommand(project: project, song: song, action: .noticeDestination, value: 1).valid, "destination requires explicit desired state")
require(DAWRemoteCommand(project: project, song: song, action: .noticeDestination, value: 2, enabled: false).valid, "destination uses idempotent desired state")
require(!DAWRemoteCommand(project: project, song: song, action: .noticePin, value: 2).valid, "pin accepts only desired boolean")
for slot in [-1.0, 0, 1, 2] {
    let command = DAWRemoteCommand(project: project, action: .noticePinStopped, value: slot, text: unicodeNotice, enabled: true)
    require(command.valid, "stopped-transport pin captures Global or any template")
    if case .command(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.command(command)) {
        require(decoded.text == unicodeNotice && decoded.value == slot && decoded.enabled == true, "stopped notice capture survives wire")
        require(DAWRemoteAccessRules.allows(decoded, mode: .notices) && DAWRemoteAccessRules.allows(decoded, mode: .director), "both notice editors may control stopped pin")
        require(!DAWRemoteAccessRules.allows(decoded, mode: .observer), "observer cannot change stopped pin")
    } else { fatalError("stopped notice command") }
}
require(DAWRemoteCommand(project: project, action: .noticePinStopped, value: -1, enabled: false).valid, "disable needs no draft")
require(DAWRemoteCommand(project: project, action: .noticePinStopped, value: 1, text: "", enabled: true).valid, "image-only preset may pin while stopped")
for command in [DAWRemoteCommand(project: project, action: .noticePinStopped, text: "Missing enabled"),
                DAWRemoteCommand(project: project, action: .noticePinStopped, enabled: true),
                DAWRemoteCommand(project: project, action: .noticePinStopped, value: 3, text: "Bad slot", enabled: true),
                DAWRemoteCommand(project: project, action: .noticePinStopped, value: 0.5, text: "Fraction", enabled: true),
                DAWRemoteCommand(project: project, action: .noticePinStopped, target: UUID(), text: "Bad target", enabled: true)] {
    require(!command.valid, "malformed stopped notice command rejected")
}
for value in [0.0, 1.0, 2.0, 3.0] {
    require(DAWRemoteCommand(project: project, song: song, action: .remotePanel, value: value).valid, "native panel subscription range")
}
require(!DAWRemoteCommand(project: project, song: song, action: .remotePanel, value: 4).valid, "unknown remote panel rejected")
for seconds in [0.0, 359999.0] {
    require(DAWRemoteCommand(project: project, song: song, action: .timerStart, value: seconds).valid, "timer endpoint accepted")
}
for seconds in [-1.0, 360000.0, 1.5, Double.infinity, Double.nan] {
    require(!DAWRemoteCommand(project: project, song: song, action: .timerStart, value: seconds).valid, "invalid timer duration rejected")
}
var tpFixture = fixture
tpFixture.teleprompters = [DAWRemoteTeleprompter(index: 2, text: "TP2 independent lyrics", chords: "C / G", song: "Current", queued: "Next",
    progress: 0.25, style: .init(), imageID: UUID())]
tpFixture.notices = .init(templates: ["One", "Two", "Three"], imageSlots: [false, true, false], message: "Notice", active: true, pinned: false,
    remaining: 20, window1: true, window2: false, textColor: 0xffffff, backgroundColor: 0, flashColor: 0xffdc52,
    font: "Arial", scale: 100, emoji: "", cleanDisplay: true, sentAt: 12345, imageID: UUID())
tpFixture.timer = .init(revision: UUID(), targetSeconds: 90, running: true, remainingSeconds: 83.5)
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(tpFixture)) {
    require(decoded == tpFixture, "independent TP2, opaque images, notice destinations, timer revision state roundtrip")
} else { fatalError("teleprompter state packet") }
require(tpFixture.notices?.pinWhenStopped == nil && tpFixture.notices?.stoppedNoticeActive == nil,
        "older hosts do not advertise stopped pin capability")
if case .state(let legacy) = try DAWRemoteWire.decode(DAWRemoteWire.state(tpFixture)) {
    require(legacy.notices?.pinWhenStopped == nil, "legacy notices decode without new fields")
}
tpFixture.notices?.pinWhenStopped = true; tpFixture.notices?.stoppedNoticeActive = true
tpFixture.previewActive = true
if case .state(let pinned) = try DAWRemoteWire.decode(DAWRemoteWire.state(tpFixture)) {
    require(pinned.notices?.active == true && pinned.notices?.pinWhenStopped == true && pinned.notices?.stoppedNoticeActive == true,
            "Preview preserves automatic notice state for restoration after Preview")
} else { fatalError("stopped notice state") }
print("PASS: stopped-transport notices, backwards compatibility and access permissions")
var malformedTP = tpFixture
malformedTP.notices?.templates = []
require(!malformedTP.valid, "malformed template list rejected before native view indexing")
malformedTP = tpFixture; malformedTP.teleprompters?[0].progress = .infinity
require(!malformedTP.valid, "invalid TP progress rejected")
malformedTP = tpFixture; malformedTP.timer?.remainingSeconds = .nan
require(!malformedTP.valid, "invalid timer sample rejected")
require(fixture.valid && fixture.teleprompters == nil && fixture.notices == nil && fixture.timer == nil, "older optional-state fixture remains valid")
print("PASS: native teleprompter, notices and timer protocol")

var fullProjectionSettings = TeleprompterSettings(preset: .day)
fullProjectionSettings.clockPosition = "right-bottom"
fullProjectionSettings.localClockPosition = "left"
fullProjectionSettings.clockScale = 65
fullProjectionSettings.localClockScale = 80
fullProjectionSettings.clockBorderColor = 0x123456
fullProjectionSettings.localClockBorderColor = 0x987654
fullProjectionSettings.clockBorderEnabled = false
fullProjectionSettings.songNameFontFamily = "georgia"
fullProjectionSettings.songNameScale = 125
fullProjectionSettings.queueNameFontFamily = "verdana"
fullProjectionSettings.previewScale = 70
fullProjectionSettings.previewSongDurationEnabled = false
fullProjectionSettings.previewUnderlineEnabled = false
fullProjectionSettings.ignoresPreview = true
fullProjectionSettings.rgbTextBoxBorderEnabled = true
fullProjectionSettings.stretchesMedia = true
tpFixture.teleprompters?[0].settings = fullProjectionSettings
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(tpFixture)) {
    require(decoded.teleprompters?[0].resolvedSettings == fullProjectionSettings, "full Mac projection appearance survives transport without reducing to the legacy style")
} else { fatalError("full projection settings packet") }
var legacyProjection = tpFixture.teleprompters![0]
legacyProjection.settings = nil
legacyProjection.style.textColor = 0xabcdef
legacyProjection.style.clockPosition = "left-bottom"
let legacyDecoded = try JSONDecoder().decode(DAWRemoteTeleprompter.self, from: JSONEncoder().encode(legacyProjection))
require(legacyDecoded.settings == nil && legacyDecoded.resolvedSettings.textColor == 0xabcdef && legacyDecoded.resolvedSettings.clockPosition == "left-bottom", "older hosts preserve supported appearance without a full settings field")
print("PASS: full native projection settings and legacy compatibility")

// Optional row state preserves compatibility while carrying Live and transport
// presentation from either desktop host to both native iPad projections.
var previewFixture = tpFixture
previewFixture.teleprompters?[0].preview = true
previewFixture.teleprompters?[0].blocks = [.init(id: UUID(), name: "Block", color: 0x4488ff,
    rows: [.init(id: regionID, name: "Played", color: 0x44ff88, duration: 120)])]
let oldRow = previewFixture.teleprompters![0].blocks[0].rows[0]
let legacyRow = try JSONDecoder().decode(DAWRemoteTeleprompter.Row.self, from: JSONEncoder().encode(oldRow))
require(legacyRow.liveExecuted == nil && !legacyRow.hasPlaybackHighlight && legacyRow.previewTextColor == oldRow.color,
        "Old hosts keep their preview colors and decode without new fields")
for marked in [true, false] {
    previewFixture.teleprompters?[0].blocks[0].rows[0].liveExecuted = marked
    previewFixture.teleprompters?[0].blocks[0].rows[0].playing = true
    previewFixture.teleprompters?[0].blocks[0].rows[0].queued = false
    previewFixture.teleprompters?[0].blocks[0].rows[0].playbackProgress = 0.42
    if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(previewFixture)) {
        let row = decoded.teleprompters![0].blocks[0].rows[0]
        require(row.liveExecuted == marked && row.playing == true && row.progressFraction == 0.42,
                "Preview marks, reset and progress must survive the actual Remote packet")
        require(row.previewTextColor == (marked ? 0xff4040 : 0xffffff), "Played songs stay red, even while replaying")
    } else { fatalError("preview state packet") }
}
previewFixture.teleprompters?[0].blocks[0].rows[0].playbackProgress = .infinity
require(!previewFixture.valid, "Nonfinite preview progress is rejected")
print("PASS: preview Live red marks, reset, playback progress and legacy packets")

var blockColorFixture = fixture
blockColorFixture.teleprompters = [.init(index: 1, text: "", chords: "", song: "", queued: "", progress: 0,
    style: .init(), preview: true, blocks: [.init(id: UUID(), name: "Block", color: 0xff0000, rows: [], nameColor: 0x00ff88)])]
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(blockColorFixture)) {
    require(decoded.teleprompters?.first?.blocks.first?.nameColor == 0x00ff88, "preview block text follows Setlist color separately from its red strip")
} else { fatalError("preview block text color packet") }
print("PREVIEW_BLOCK_SETLIST_TEXT_COLOR_SEPARATE_FROM_STRIP_OK")
