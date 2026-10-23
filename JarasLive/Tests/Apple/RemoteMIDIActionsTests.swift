extension RemoteMIDIActions {
 static func verify() {
  UserDefaults.standard.removeObject(forKey: "catlive.remote.midiActions.smoke-test")
  defer { UserDefaults.standard.removeObject(forKey: "catlive.remote.midiActions.smoke-test") }
  let midi = RemoteMIDIActions(); midi.sources[42] = (777, "Controller")
  midi.learning = .play
  midi.receive(42, 0x91, 60, 127)
  precondition(midi.bindings["play"]?.channel == 1 && midi.event == nil)
  midi.receive(42, 0x81, 60, 0); midi.receive(42, 0x91, 60, 100)
  precondition(midi.event?.action == .play)
  let event = midi.event!.id
  midi.receive(42, 0x91, 60, 90); precondition(midi.event!.id == event)
  midi.receive(42, 0x91, 60, 0); midi.receive(42, 0x91, 60, 90)
  precondition(midi.event!.id != event)
  midi.learning = .stop; midi.receive(42, 0xb0, 12, 127)
  midi.receive(42, 0xb0, 12, 0); midi.receive(42, 0xb0, 12, 127)
  precondition(midi.event?.action == .stop)
  let held = midi.event!.id; midi.receive(42, 0xb0, 12, 50)
  precondition(midi.event!.id == held)
  let restored = RemoteMIDIActions(); precondition(restored.bindings == midi.bindings)
  midi.clear(.stop); precondition(midi.bindings["stop"] == nil)
  print("REMOTE_MIDI_LEARN_NOTE_CC_CHANNEL_EDGE_AND_PERSISTENCE_OK")
 }
}
@main struct RemoteMIDITest {
 @MainActor static func main() { RemoteMIDIActions.verify() }
}
