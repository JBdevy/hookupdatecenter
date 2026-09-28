import SwiftUI

struct TimecodeOptions: View {
    @ObservedObject var show: ShowController
    let track: Track
    @ObservedObject private var audio = AudioDeviceSettings.shared
    private var settings: TimecodeSettings { track.timecode ?? TimecodeSettings() }
    private func value<T>(_ path: WritableKeyPath<TimecodeSettings,T>) -> Binding<T> {
        Binding(get: { settings[keyPath: path] }, set: { var copy = settings; copy[keyPath: path] = $0; show.setTimecode(track.id, settings: copy) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: value(\.mode)) { Text("MTC").tag("mtc"); Text("LTC").tag("ltc") }.pickerStyle(.segmented)
            Picker("Frame rate", selection: value(\.frameRate)) {
                ForEach([24.0,25,29.97,30], id: \.self) { rate in Text(rate == 29.97 ? "29.97 DF" : String(format: "%.0f fps",rate)).tag(rate) }
            }
            Toggle("Start at zero in each region", isOn: value(\.regionRelative))
            HStack { Text("Offset (s)"); TextField("0", value: value(\.offset), format: .number).frame(width: 80) }
            if settings.mode == "mtc" {
                Picker("MIDI output", selection: value(\.midiDestination)) {
                    Text(JarasLocalization.string("Default output") + " · " + audio.midiOutputTitle).tag(Int32(0))
                    ForEach(audio.midiOutputs) { port in Text(port.name).tag(port.id) }
                    if settings.midiDestination != 0 && !audio.midiOutputs.contains(where: { $0.id == settings.midiDestination }) { Text("Unavailable").tag(settings.midiDestination) }
                }
            }
        }
    }
}
