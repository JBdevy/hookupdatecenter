import AppKit

@MainActor final class CloseTestAlert {
    static var response: NSApplication.ModalResponse = .alertThirdButtonReturn
    static var buttons: [NSButton] = []
    static var instances = 0, deferred = false
    static var answer: ((NSApplication.ModalResponse) -> Void)?
    var messageText = "", informativeText = ""
    var alertStyle: NSAlert.Style = .informational
    init() { Self.buttons = []; Self.instances += 1 }
    func addButton(withTitle title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        Self.buttons.append(button); return button
    }
    func beginSheetModal(for window: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {
        if Self.deferred { Self.answer = completionHandler }
        else { completionHandler?(Self.response) }
    }
    func runModal() -> NSApplication.ModalResponse { Self.response }
}
enum JarasLocalization { static func string(_ key: String) -> String { key } }
enum ProjectError: Error { case invalid(String) }
enum CloseTestCommand { case stopAll }
@MainActor final class CloseTestShow {
    var hasUnsavedChanges = true, saving = false, saves = 0, stops = 0
    var failSave = false
    func send(_ command: CloseTestCommand) { stops += 1 }
    func saveForClosing() async throws {
        saves += 1
        if failSave { throw ProjectError.invalid("Save failed") }
        hasUnsavedChanges = false
    }
}
@MainActor final class ProjectDocuments {
    // INSERT_OPENING_CONTROLLER
    var error = "", status = "", cleanups = 0
    var missingAudioPrompt: Bool?
    let show = CloseTestShow()
    func rememberProjectMedia() async throws {}
}
@MainActor final class TrackRecording {
    static let shared = TrackRecording()
    var recording = false, busy = false, error = ""
    func finishAndWait() async {}
}
@MainActor final class ClosingLogo { func begin() {} ; func advance(_ value: Double) {} ; func finish(restore: Bool) {} ; func focus() -> Bool { false } }
@MainActor final class FXWindows { static let shared = FXWindows(); func closeAll() {} }
@MainActor final class StemAudioPlayback { static let shared = StemAudioPlayback(); func prepareForClosing() {} }
// INSERT_CLOSE_CONTROLLER

@MainActor final class CloseTestWindow: NSWindow {
    var focusCount = 0
    var simulatedSheet: NSWindow?
    override var attachedSheet: NSWindow? { simulatedSheet }
    override func makeKeyAndOrderFront(_ sender: Any?) { focusCount += 1 }
}

Task { @MainActor in
    _ = NSApplication.shared
    let window = CloseTestWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    for (choice, allowed, writes) in [(NSApplication.ModalResponse.alertFirstButtonReturn, true, 1), (.alertSecondButtonReturn, true, 0), (.alertThirdButtonReturn, false, 0)] {
        let documents = ProjectDocuments(), guardClose = ProjectCloseGuard()
        guardClose.attach(window: window, documents: documents)
        CloseTestAlert.response = choice
        var outcome: Bool?
        guardClose.request { outcome = $0 }
        while outcome == nil { await Task.yield() }
        precondition(outcome == allowed)
        precondition(documents.show.saves == writes, "discard and cancel must not call persistence")
        precondition(documents.show.hasUnsavedChanges == (writes == 0))
        precondition(documents.cleanups == 0)
        precondition(!guardClose.pending)
        precondition(CloseTestAlert.buttons.map(\.title) == ["Save", "Close without saving", "Cancel"])
        precondition(CloseTestAlert.buttons[0].keyEquivalent == "\r")
        precondition(CloseTestAlert.buttons[1].keyEquivalent.isEmpty, "discard is never the default keyboard action")
        precondition(CloseTestAlert.buttons[2].keyEquivalent == "\u{1b}")
    }
    print("PROJECT_CLOSE_SAVE_DISCARD_CANCEL_OK")
    do {
        let documents = ProjectDocuments(), guardClose = ProjectCloseGuard()
        guardClose.attach(window: window, documents: documents)
        var started = false, rollbackFinished = false
        documents.missingAudioPrompt = true
        documents.beginOpening {
            started = true
            defer { rollbackFinished = true }
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        while !started { await Task.yield() }
        CloseTestAlert.response = .alertFirstButtonReturn
        var outcome: Bool?, completions = 0
        guardClose.request {
            precondition(rollbackFinished && !documents.busy, "opening must finish cancellation before closing")
            completions += 1; outcome = $0
        }
        precondition(guardClose.pending && documents.busy)
        while outcome == nil { await Task.yield() }
        precondition(outcome == true && completions == 1 && documents.show.saves == 1)
        precondition(documents.missingAudioPrompt == nil && !documents.canCancelOpening)
        precondition(documents.status.isEmpty && !guardClose.pending)
    }
    do {
        let documents = ProjectDocuments(), guardClose = ProjectCloseGuard()
        guardClose.attach(window: window, documents: documents)
        documents.busy = true; documents.status = "Importing audio…"
        let alerts = CloseTestAlert.instances, focus = window.focusCount
        var outcome: Bool?
        guardClose.request { outcome = $0 }
        while outcome == nil { await Task.yield() }
        precondition(outcome == false && documents.busy && !guardClose.pending)
        precondition(documents.status == "Importing audio…" && documents.show.saves == 0)
        precondition(documents.closeNotice == "Finish the current operation before closing.")
        precondition(CloseTestAlert.instances == alerts && window.focusCount > focus)
        documents.busy = false
        precondition(documents.closeNotice.isEmpty, "feedback must clear when the operation finishes")
    }
    print("PROJECT_CLOSE_CANCEL_OPENING_WAIT_AND_BUSY_FEEDBACK_OK")
    do {
        let documents = ProjectDocuments(), guardClose = ProjectCloseGuard()
        guardClose.attach(window: window, documents: documents)
        let sheet = CloseTestWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.simulatedSheet = sheet
        let alerts = CloseTestAlert.instances
        var rejected: Bool?
        guardClose.request { rejected = $0 }
        precondition(rejected == false && sheet.focusCount == 1 && CloseTestAlert.instances == alerts)
        window.simulatedSheet = nil
        CloseTestAlert.deferred = true
        var outcome: Bool?, completions = 0
        guardClose.request { completions += 1; outcome = $0 }
        precondition(guardClose.pending && outcome == nil)
        window.simulatedSheet = sheet
        guardClose.request { rejected = $0 }
        precondition(rejected == false && sheet.focusCount == 2 && guardClose.pending)
        precondition(CloseTestAlert.instances == alerts + 1, "repeated close must focus the existing confirmation")
        window.simulatedSheet = nil
        CloseTestAlert.deferred = false
        CloseTestAlert.answer?(.alertFirstButtonReturn)
        CloseTestAlert.answer = nil
        while outcome == nil { await Task.yield() }
        precondition(outcome == true && completions == 1 && documents.show.saves == 1 && !guardClose.pending)
    }
    do {
        let documents = ProjectDocuments(), guardClose = ProjectCloseGuard()
        guardClose.attach(window: window, documents: documents)
        documents.show.failSave = true
        CloseTestAlert.response = .alertFirstButtonReturn
        var outcome: Bool?
        guardClose.request { outcome = $0 }
        while outcome == nil { await Task.yield() }
        precondition(outcome == false && !guardClose.pending && documents.show.hasUnsavedChanges)
        precondition(!documents.error.isEmpty)
    }
    print("PROJECT_CLOSE_EXISTING_DIALOG_FOCUS_AND_SAVE_FAILURE_OK")
    exit(0)
}
RunLoop.main.run()
