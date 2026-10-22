import Foundation

@MainActor final class MappingProbe {
    struct Entry { var input: ControlInput }
    var show: Bool? = true
    var editing: Int?
    var transferRequest: Int?
    var candidate: ControlInput?
    var mode = "keyboard"
    var error = ""
    var actions = DAWActionBindings()
    var current: [Entry] = []
    var executed: [ControlInput] = []
    var saves = 0
    func execute(_ input: ControlInput) { executed.append(input) }
    func save() { saves += 1; editing = nil }
    // PRODUCTION_HANDLER
}

@main struct HardwareKeyboardActionsTests {
    @MainActor static func main() {
        let probe = MappingProbe()
        func event(_ usage: Int, _ modifiers: HardwareKeyboardModifiers = [], repeatKey: Bool = false,
                   phase: HardwareKeyboardEvent.Phase = .down) -> HardwareKeyboardEvent {
            HardwareKeyboardInput.event(hidUsage: usage, modifierFlags: modifiers.rawValue,
                                        isRepeat: repeatKey, phase: phase)!
        }
        precondition(probe.handleHardwareKey(event(0x2c)))
        precondition(probe.handleHardwareKey(event(0x2c, repeatKey: true)))
        precondition(probe.executed.count == 1, "Holding Space must not repeatedly start/stop playback")
        precondition(!probe.handleHardwareKey(event(0x2c, phase: .up)))
        precondition(probe.handleHardwareKey(event(0x51)))
        precondition(probe.handleHardwareKey(event(0x51, repeatKey: true)))
        precondition(probe.executed.count == 3, "Held arrows must navigate as on the desktop")
        precondition(probe.handleHardwareKey(event(0x2e, .shift, repeatKey: true)))
        precondition(probe.executed.count == 4, "Continuous tempo shortcuts must repeat")
        precondition(!probe.handleHardwareKey(event(0x06, .command)), "Copy belongs to the editor")

        let custom = event(0x09, [.control, .option]).input
        precondition(probe.actions.setInput(custom, action: .repeatPlayback, kind: "keyboard"))
        precondition(probe.handleHardwareKey(event(0x09, [.control, .option])))
        precondition(probe.executed.last?.matches(custom) == true, "Saved/custom Action binding was ignored")

        let executed = probe.executed.count
        probe.editing = 1
        precondition(probe.handleHardwareKey(event(0x0b, .option)))
        precondition(probe.candidate?.matches(event(0x0b, .option).input) == true)
        precondition(probe.executed.count == executed, "Learning must not execute the mapped Action")
        let learned = probe.candidate
        precondition(probe.handleHardwareKey(event(0x17, .option, repeatKey: true)))
        precondition(probe.candidate == learned, "Repeat must not change the learning candidate")
        precondition(probe.handleHardwareKey(event(0x14, .command)))
        precondition(probe.candidate == learned, "Application shortcuts must not be learned")
        precondition(probe.handleHardwareKey(event(0x28)))
        precondition(probe.saves == 1 && probe.editing == nil, "Enter did not commit learning")

        probe.editing = 1; probe.mode = "midi"; probe.candidate = nil
        precondition(probe.handleHardwareKey(event(0x2c)))
        precondition(probe.candidate == nil && probe.executed.count == executed, "Keyboard must not change MIDI learning")
        precondition(probe.handleHardwareKey(event(0x29)))
        precondition(probe.editing == nil, "Escape did not cancel MIDI learning")
        probe.transferRequest = 1
        precondition(!probe.handleHardwareKey(event(0x2c)), "Transfer confirmation must own the keyboard")
        probe.transferRequest = nil; probe.show = nil
        precondition(!probe.handleHardwareKey(event(0x2c)), "Detached native session executed an Action")
        print("IPAD_HARDWARE_KEYBOARD_ACTIONS_LEARNING_REPEATS_AND_EDITOR_PRIORITY_OK")
    }
}
