@main struct Test {
 @MainActor static func main() async {
  let state = InstrumentKeyboardState(), a = UUID(), b = UUID()
  state.receive(track:a,source:12,status:0x90,number:60,value:100)
  precondition(state.notes == [60] && state.activity(a).level > 0)
  state.receive(track:b,source:13,status:0x91,number:60,value:90)
  state.receive(track:a,source:12,status:0x80,number:60,value:0)
  precondition(state.notes == [60], "releasing one track must preserve the other's held note")
  state.receive(track:b,source:13,status:0x91,number:60,value:0)
  precondition(state.notes.isEmpty, "zero-velocity note-on releases the key")
  state.receive(track:a,source:Int32.min,status:0x90,number:21,value:127)
  state.receive(track:a,source:12,status:0x91,number:108,value:100)
  state.receive(track:a,source:12,status:0xb1,number:123,value:0)
  precondition(state.notes == [21], "all-notes-off applies only to its source/channel")
  state.receive(track:a,source:Int32.min,status:0x80,number:21,value:0)
  precondition(state.notes.isEmpty)
  try? await Task.sleep(nanoseconds: 280_000_000)
  precondition(state.activity(a).level == 0 && state.activity(b).level == 0, "MIDI indicator decays without a continuous polling timer")
  state.receive(track:a,source:12,status:0x90,number:60,value:100); state.reset()
  precondition(state.notes.isEmpty && state.activity(a).level == 0)
  let monitor = KeyboardMIDIMonitor()
  let oldChannel = monitor.channel
  monitor.channel = 2
  monitor.receive(source: 1, status: 0x90, number: 60, value: 100)
  precondition(monitor.notes.isEmpty)
  monitor.receive(source: 1, status: 0x91, number: 60, value: 100)
  monitor.receive(source: 2, status: 0x91, number: 60, value: 100)
  monitor.receive(source: 1, status: 0x81, number: 60, value: 0)
  precondition(monitor.notes == [60])
  monitor.receive(source: 2, status: 0x91, number: 60, value: 0)
  precondition(monitor.notes.isEmpty)
  monitor.receive(source: 1, status: 0x91, number: 60, value: 100)
  monitor.channel = 3
  precondition(monitor.notes.isEmpty)
  monitor.channel = oldChannel
  print("MIDI_KEYBOARD_MULTI_SOURCE_RELEASE_CHANNEL_CLEAR_AND_ACTIVITY_DECAY_OK")
 }
}
