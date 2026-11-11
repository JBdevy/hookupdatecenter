import AppKit
@MainActor final class SMK37FirmwareTask {
 static let shared = SMK37FirmwareTask()
 var busy = false
}
@MainActor enum ProjectSyncControl { static var following = false }
@MainActor final class CloseDocuments { var closeNotice = "" }
@MainActor final class CloseProject { var documents = CloseDocuments() }
@MainActor final class DesktopProjectTabs {
 static let shared = DesktopProjectTabs()
 var active: CloseProject? = CloseProject()
}
@MainActor final class ProjectCloseGuard {
 static let shared = ProjectCloseGuard()
 var attached = true, pending = false, focused = 0, requests = 0
 var answer: ((Bool) -> Void)?
 func focusCurrentDialog() { focused += 1 }
 func request(completion: @escaping (Bool) -> Void) { pending = true; requests += 1; answer = completion }
 func respond(_ allowed: Bool) { pending = false; let callback = answer; answer = nil; callback?(allowed) }
}
// INSERT_APPLICATION_DELEGATE
@MainActor final class CloseApplication: NSApplication {
 var requests: [NSApplication.TerminateReply] = []
 override func terminate(_ sender: Any?) {
  requests.append((delegate as! JarasApplicationDelegate).applicationShouldTerminate(self))
 }
}
Task { @MainActor in
 let app = CloseApplication()
 let delegate = JarasApplicationDelegate(); app.delegate = delegate
 let guardClose = ProjectCloseGuard.shared
 SMK37FirmwareTask.shared.busy = true
 precondition(delegate.applicationShouldTerminate(app) == .terminateCancel,
              "Firmware installation must prevent application termination")
 precondition(guardClose.requests == 0 && !guardClose.pending)
 SMK37FirmwareTask.shared.busy = false
 precondition(delegate.applicationShouldTerminate(app) == .terminateCancel,
              "A save decision must not enter AppKit's termination run loop and suspend audio scheduling")
 while !guardClose.pending { await Task.yield() }
 precondition(guardClose.requests == 1 && app.requests.isEmpty)
 precondition(delegate.applicationShouldTerminate(app) == .terminateCancel && guardClose.focused == 1)
 guardClose.respond(false)
 precondition(app.requests.isEmpty, "Cancel must leave the app and its playback alive")
 precondition(delegate.applicationShouldTerminate(app) == .terminateCancel)
 while !guardClose.pending { await Task.yield() }
 guardClose.respond(true)
 precondition(app.requests == [.terminateNow], "Only a successful close/save decision may terminate")
 print("APPLICATION_CLOSE_KEEPS_NORMAL_AUDIO_RUN_LOOP_UNTIL_SAVE_APPROVAL_OK")
 exit(0)
}
dispatchMain()
