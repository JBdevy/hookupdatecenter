private enum JarasLocalization { static func string(_ key: String) -> String { key } }
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
  midi.beginBlock(1)
  let beforeLearning = midi.event!.id
  midi.receive(42, 0xc2, 79, 0)
  precondition(midi.candidate == nil && midi.event!.id == beforeLearning, "Program Change is ignored while learning a block; blocks use Note/CC like Native/Desktop")
  midi.receive(42, 0xb2, 80, 127)
  precondition(midi.learningBlock == 1 && midi.candidate?.channel == 2 && midi.candidate?.number == 80)
  precondition(midi.event!.id == beforeLearning && midi.bindings["setlistBlock:1"] == nil, "A candidate must neither execute nor persist before Save")
  midi.saveBlock()
  precondition(!midi.isLearning && midi.bindings["setlistBlock:1"]?.number == 80)
  midi.receive(42, 0xb2, 80, 0); midi.receive(42, 0xb2, 80, 127)
  precondition(midi.event?.blockNumber == 1 && midi.event?.action == nil, "Block events contain only an ordinal, never Play")
  let heldBlock = midi.event!.id
  midi.receive(42, 0xb2, 80, 90)
  midi.receive(42, 0xb1, 80, 127)
  precondition(midi.event!.id == heldBlock, "Holding CC or using a different channel cannot repeat/select a block")
  midi.beginBlock(1)
  precondition(midi.candidate == midi.bindings["setlistBlock:1"] && midi.hasBlockMapping)
  midi.receive(42, 0x92, 81, 100); midi.cancelLearning()
  precondition(midi.bindings["setlistBlock:1"]?.number == 80, "Cancel preserves the original mapping")
  midi.beginBlock(2); midi.receive(42, 0xb2, 80, 0); midi.receive(42, 0xb2, 80, 127); midi.saveBlock()
  precondition(midi.transfer != nil && midi.bindings["setlistBlock:1"] != nil && midi.bindings["setlistBlock:2"] == nil, "Another block using this MIDI must require an explicit transfer")
  midi.cancelTransfer(); midi.cancelLearning()
  midi.beginBlock(2); midi.receive(42, 0xb2, 80, 0); midi.receive(42, 0xb2, 80, 127); midi.saveBlock()
  let request = midi.transfer!
  midi.cancelTransfer()
  midi.confirmTransfer(request)
  precondition(midi.bindings["setlistBlock:1"] != nil && midi.bindings["setlistBlock:2"] == nil, "A dismissed transfer cannot later commit")
  midi.saveBlock()
  let currentRequest = midi.transfer!
  midi.confirmTransfer(request)
  precondition(midi.transfer?.id == currentRequest.id && midi.bindings["setlistBlock:2"] == nil, "An older alert for the same block must not override a new request")
  midi.confirmTransfer(currentRequest)
  precondition(midi.bindings["setlistBlock:1"] == nil && midi.bindings["setlistBlock:2"]?.number == 80)
  midi.beginAction(.play); midi.receive(42, 0xb2, 80, 0); midi.receive(42, 0xb2, 80, 127)
  precondition(midi.transfer != nil && midi.bindings["setlistBlock:2"] != nil, "Actions must not silently overwrite a global block")
  midi.confirmTransfer()
  precondition(midi.bindings["setlistBlock:2"] == nil && midi.bindings["play"]?.number == 80)
  midi.beginBlock(129); midi.receive(42, 0xb2, 80, 0); midi.receive(42, 0xb2, 80, 127); midi.saveBlock()
  precondition(midi.transfer != nil && midi.bindings["play"] != nil, "Block MIDI must detect Action conflicts")
  midi.confirmTransfer()
  precondition(midi.bindings["play"] == nil && midi.bindings["setlistBlock:129"] != nil, "Numbered block mappings have no enum limit")
  let newSession = RemoteMIDIActions()
  precondition(newSession.bindings == midi.bindings && newSession.bindings["setlistBlock:129"] != nil, "Bindings persist globally on this Remote, with no host/project/playlist UUID")
  newSession.sources[42] = (777, "Controller")
  newSession.receive(42, 0xb2, 80, 127)
  precondition(newSession.event?.blockNumber == 129)
  midi.beginBlock(129); midi.removeBlockMapping()
  precondition(!midi.isLearning && midi.bindings["setlistBlock:129"] == nil)
  precondition(RemoteMIDIActions().bindings["setlistBlock:129"] == nil, "Removing a mapping persists")
  midi.beginBlock(4); midi.receive(42, 0x92, 81, 0); midi.receive(42, 0x92, 81, 100); midi.saveBlock()
  let beforeRelease = midi.event!.id
  midi.receive(42, 0x82, 81, 0); precondition(midi.event!.id == beforeRelease)
  midi.receive(42, 0x92, 81, 100); precondition(midi.event?.blockNumber == 4)
  midi.beginBlock(0); precondition(!midi.isLearning)
  print("REMOTE_GLOBAL_BLOCK_MIDI_CANDIDATE_SAVE_CANCEL_REMOVE_NOTE_CC_CHANNEL_CONFLICT_TRANSFER_AND_NEW_HOST_SESSION_OK")
 }
}
@main struct RemoteMIDITest {
 @MainActor static func main() { RemoteMIDIActions.verify() }
}
