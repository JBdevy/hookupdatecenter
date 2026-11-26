import Foundation

@MainActor final class ControlledStartupSound {
    static var instance: ControlledStartupSound?
    static var plays = 0
    static var startsSuccessfully = true
    let duration: TimeInterval = 0.05
    var isPlaying = false
    init?(contentsOf url: URL, byReference: Bool) { Self.instance = self }
    func play() -> Bool {
        Self.plays += 1
        isPlaying = Self.startsSuccessfully
        return isPlaying
    }
    func stop() { isPlaying = false }
}

@main struct AppStartupSoundTests {
    @MainActor static func main() async throws {
        let scenario = CommandLine.arguments[1]
        UserDefaults.standard.set(scenario != "disabled", forKey: "jaras.startup.sound")
        defer { UserDefaults.standard.removeObject(forKey: "jaras.startup.sound") }
        ControlledStartupSound.startsSuccessfully = scenario != "failed"
        var activated = false
        let opening = Task { @MainActor in
            try await AppStartupPresentation.waitForSound()
            activated = true
        }
        if scenario == "disabled" || scenario == "failed" {
            try await opening.value
            precondition(activated, "Disabled or failed audio must not delay project activation")
            precondition(ControlledStartupSound.plays == (scenario == "disabled" ? 0 : 1))
        } else {
            try await AppStartupTestClock.until("Sound playback must start waiting") { !AppStartupTestClock.sleeps.isEmpty }
            precondition(!activated, "A document must not rebuild the graph while the introduction is playing")
            precondition(ControlledStartupSound.plays == 1)
            // The main actor can run here while project activation is waiting.
            if scenario == "cancelled" {
                opening.cancel()
                do { try await opening.value; preconditionFailure("Cancelled opening must not activate") }
                catch is CancellationError {}
                precondition(!activated && ControlledStartupSound.instance?.isPlaying == true,
                             "Cancelling one opening must not cut off the introduction")
            } else if scenario == "timeout" {
                // The real coordinator must keep waiting before its deadline,
                // then release the graph at that deadline regardless of CI load.
                AppStartupTestClock.now += 1.049
                let previousWaits = AppStartupTestClock.sleeps.count
                try await AppStartupTestClock.until("Sound must still wait before its deadline") { AppStartupTestClock.sleeps.count > previousWaits }
                precondition(!activated)
                AppStartupTestClock.now += 0.002
                try await AppStartupTestClock.until("A lost output route must release activation") { activated }
                try await opening.value
                precondition(ControlledStartupSound.instance?.isPlaying == false)
            } else {
                ControlledStartupSound.instance?.isPlaying = false
                try await opening.value
                precondition(activated)
            }
            ControlledStartupSound.instance?.isPlaying = false
            AppStartupTestClock.reset()
            try await AppStartupPresentation.waitForSound()
            precondition(AppStartupTestClock.sleeps.isEmpty, "Later openings add no wait")
            precondition(ControlledStartupSound.plays == 1, "Later openings must not replay the introduction")
        }
        print("STARTUP_SOUND_GRAPH_ACTIVATION_\(scenario.uppercased())_OK")
    }
}
