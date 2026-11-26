import Foundation

@main struct AppStartupPresentationTests {
    @MainActor static func main() async throws {
        var finished = false
        let loading = Task {
            try await AppStartupPresentation.wait(since: AppStartupTestClock.now - 0.15)
            finished = true
        }
        try await AppStartupTestClock.until("The splash must schedule its wait") { !AppStartupTestClock.sleeps.isEmpty }
        precondition(!finished, "the splash delay allows loading and UI work to continue")
        precondition(abs(Double(AppStartupTestClock.sleeps[0]) - 2_850_000_000) <= 1,
                     "startup shows the logo for three seconds including loading")
        try await loading.value

        AppStartupTestClock.reset()
        try await AppStartupPresentation.wait(since: AppStartupTestClock.now - 2.95)
        precondition(AppStartupTestClock.sleeps.count == 1 && abs(Double(AppStartupTestClock.sleeps[0]) - 50_000_000) <= 1,
                     "time already spent loading is subtracted from the three-second minimum")

        AppStartupTestClock.reset()
        try await AppStartupPresentation.wait(since: AppStartupTestClock.now - 4)
        precondition(AppStartupTestClock.sleeps.isEmpty,
                     "loading beyond the minimum adds no extra delay")

        let cancelledStartup = Task { @MainActor in
            try await AppStartupPresentation.wait(since: AppStartupTestClock.now)
        }
        try await AppStartupTestClock.until("The cancellable splash must start waiting") { !AppStartupTestClock.sleeps.isEmpty }
        cancelledStartup.cancel()
        do { try await cancelledStartup.value; preconditionFailure("a cancelled startup cannot finish its splash") }
        catch is CancellationError {}
        print("STARTUP_LOGO_THREE_SECOND_MINIMUM_CONCURRENT_LOADING_AND_CANCELLATION_OK")
    }
}
