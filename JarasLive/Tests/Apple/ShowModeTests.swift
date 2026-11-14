final class FakePower: @unchecked Sendable {
    private let lock = NSLock()
    var active = false
    var deny = false
    var ignoreChange = false
    var calls: [(String,[String])] = []
    func execute(_ path: String, _ arguments: [String]) throws -> String {
        lock.lock(); defer { lock.unlock() }
        calls.append((path,arguments))
        if path == "/usr/bin/osascript" {
            if deny { throw NSError(domain:"fixture",code:-128,userInfo:[NSLocalizedDescriptionKey:"Authorization cancelled"]) }
            precondition(arguments.count == 2 && arguments[0] == "-e")
            precondition(arguments[1].contains("with administrator privileges"))
            if !ignoreChange { active = arguments[1].contains("disablesleep 1") }
            return ""
        }
        precondition(path == "/usr/bin/pmset" && arguments == ["-g"])
        return "System-wide power settings: SleepDisabled \(active ? 1 : 0)"
    }
}
@main struct Tests {
    @MainActor static func settle(_ model: MacShowMode) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        preconditionFailure("Asynchronous Show Mode operation did not finish")
    }
    @MainActor static func main() async throws {
        precondition(MacShowMode.isEnabled("SleepDisabled 1"))
        precondition(MacShowMode.isEnabled("disablesleep 1"))
        precondition(!MacShowMode.isEnabled("SleepDisabled 0"))
        precondition(!MacShowMode.isEnabled("sleep 1 (sleep prevented by audio)"))
        let fake=FakePower()
        let model=MacShowMode(run: { try fake.execute($0, $1) }, brightnessEnabled: { _ in })
        model.refresh(); try await settle(model)
        precondition(model.loaded && !model.enabled && model.error.isEmpty)
        precondition(fake.calls.count == 1 && fake.calls[0].0 == "/usr/bin/pmset")
        model.setEnabled(true); try await settle(model)
        precondition(model.enabled && model.error.isEmpty)
        let reopened=MacShowMode(run: { try fake.execute($0, $1) }, brightnessEnabled: { _ in })
        reopened.refresh(); try await settle(reopened)
        precondition(reopened.enabled && reopened.loaded, "Reopening must read the persisted system state")
        precondition(fake.calls[1].1[1] == "do shell script \"/usr/bin/pmset -a disablesleep 1\" with administrator privileges")
        fake.deny=true
        model.setEnabled(false); try await settle(model)
        precondition(model.enabled && !model.error.isEmpty)
        fake.deny=false
        model.setEnabled(false); try await settle(model)
        precondition(!model.enabled && model.error.isEmpty)
        fake.ignoreChange=true
        model.setEnabled(true); try await settle(model)
        precondition(!model.enabled && !model.error.isEmpty)
        var levels: [UInt32: Float] = [1: 0.75, 2: 0.4]
        var writes: [(UInt32, Float)] = []
        let brightness = MacShowLidBrightness(backend: .init(displays: { [1] }, read: { levels[$0] }, write: { display, level in levels[display] = level; writes.append((display,level)); return true }), watchesHardware: false)
        brightness.lidChanged(closed: true)
        precondition(writes.isEmpty, "Disabled Show Mode cannot change brightness")
        brightness.setEnabled(true); brightness.lidChanged(closed: true)
        precondition(levels[1] == 0 && levels[2] == 0.4, "Only the built-in display is dimmed")
        brightness.lidChanged(closed: true); brightness.lidChanged(closed: false)
        precondition(levels[1] == 0.75 && writes.count == 2, "Repeated lid events must not overwrite the original brightness")
        brightness.lidChanged(closed: true); brightness.setEnabled(false)
        precondition(levels[1] == 0.75, "Disabling Show Mode restores brightness")
        brightness.setEnabled(true); brightness.lidChanged(closed: true); levels[1] = 0.5; brightness.lidChanged(closed: false)
        precondition(levels[1] == 0.5, "A manual brightness adjustment is preserved")
        brightness.lidChanged(closed: true); brightness.stop()
        precondition(levels[1] == 0.5, "Shutdown restores the saved brightness")
        print("MAC_SHOW_LID_BRIGHTNESS_MINIMUM_RESTORE_MANUAL_OVERRIDE_AND_EXTERNAL_DISPLAY_UNCHANGED_OK")
        print("MAC_SHOW_MODE_OK: query only, enabled/disabled, authorization cancellation, verified system state; no real power settings changed")
    }
}
