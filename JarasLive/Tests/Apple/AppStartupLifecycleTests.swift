import Foundation
@main struct Test {
 @MainActor static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
  let deadline = ProcessInfo.processInfo.systemUptime + 10
  while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
   try await Task.sleep(nanoseconds: 10_000_000)
  }
  precondition(condition(), message)
 }
 @MainActor static func main() async throws {
  let app = AppContainerFixture()
  let first = Task { await app.start() }
  try await waitUntil("Initialization must start") { app.auth.restores > 0 }
  first.cancel()
  let replacement = Task { await app.start() }
  try await waitUntil("Reparenting must finish startup") { !app.starting && app.startupProgress == 1 }
  precondition(app.auth.restores == 1 && app.accessConnectivity.starts == 1, "Initialization runs once across appearances")
  replacement.cancel()
  await first.value; await replacement.value
  let previousChecks = app.auth.expiryChecks
  let reopened = Task { await app.start() }
  // Observe a fresh monitoring tick rather than assuming the shared CI runner
  // can schedule both tasks within 100 ms of the one-second timer deadline.
  try await waitUntil("Access monitoring resumes after reappearance") { app.auth.expiryChecks > previousChecks }
  precondition(app.auth.restores == 1 && app.accessConnectivity.starts == 1)
  reopened.cancel(); await reopened.value
  print("STARTUP_REPARENT_CANCELLATION_INITIALIZES_ONCE_AND_RESUMES_MONITORING_OK")
 }
}
