import Foundation

@main struct AppStartupPresentationTests {
    @MainActor static func main() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        var mainActorResponded = false
        let loading = Task { @MainActor in
            try await Task.sleep(nanoseconds: 350_000_000)
            mainActorResponded = true
        }
        // Simulate loading before waiting; that time counts toward the minimum.
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!mainActorResponded, "the concurrent task must still be pending before the splash wait")
        try await AppStartupPresentation.wait(since: began)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        precondition(elapsed >= 3 && elapsed < 3.5, "startup shows the logo for at least three seconds including loading")
        precondition(mainActorResponded, "the splash delay allows loading and UI work to continue")
        try await loading.value

        let mostlyLoaded = ProcessInfo.processInfo.systemUptime
        try await AppStartupPresentation.wait(since: mostlyLoaded - 2.95)
        let remainder = ProcessInfo.processInfo.systemUptime - mostlyLoaded
        precondition(remainder >= 0.05 && remainder < 0.2,
                     "time already spent loading is subtracted from the three-second minimum")

        let slowLoadFinished = ProcessInfo.processInfo.systemUptime
        try await AppStartupPresentation.wait(since: slowLoadFinished - 4)
        precondition(ProcessInfo.processInfo.systemUptime - slowLoadFinished < 0.1,
                     "loading beyond the minimum adds no extra delay")

        let cancelledAt = ProcessInfo.processInfo.systemUptime
        let cancelledStartup = Task { @MainActor in
            try await AppStartupPresentation.wait(since: cancelledAt)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledStartup.cancel()
        do { try await cancelledStartup.value; preconditionFailure("a cancelled startup cannot finish its splash") }
        catch is CancellationError {}
        precondition(ProcessInfo.processInfo.systemUptime - cancelledAt < 0.2,
                     "closing during the splash cancels the wait immediately")
        print("STARTUP_LOGO_THREE_SECOND_MINIMUM_CONCURRENT_LOADING_AND_CANCELLATION_OK")
    }
}
