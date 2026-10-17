import Foundation
@main struct Test {
 @MainActor static func main() async throws {
  let app = AppContainerFixture()
  let first = Task { await app.start() }
  while app.auth.restores == 0 { await Task.yield() }
  first.cancel()
  let replacement = Task { await app.start() }
  try await Task.sleep(nanoseconds: 3_200_000_000)
  precondition(!app.starting && app.startupProgress == 1, "Reparenting must finish startup")
  precondition(app.auth.restores == 1 && app.accessConnectivity.starts == 1, "Initialization runs once across appearances")
  replacement.cancel()
  await first.value; await replacement.value
  let reopened = Task { await app.start() }
  try await Task.sleep(nanoseconds: 1_100_000_000)
  precondition(app.auth.expiryChecks > 0, "Access monitoring resumes after reappearance")
  precondition(app.auth.restores == 1 && app.accessConnectivity.starts == 1)
  reopened.cancel(); await reopened.value
  print("STARTUP_REPARENT_CANCELLATION_INITIALIZES_ONCE_AND_RESUMES_MONITORING_OK")
 }
}
