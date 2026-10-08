// Included after DAWRemoteTests.swift by test-daw-remote.sh.
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
