import SwiftUI

struct MediaProcessingFormatEditor: View {
    let scope: String
    @State private var format = AudioExportFormat.wav
    @State private var bits = 24
    @State private var bitrate = 320
    var body: some View {
        HStack(spacing: 14) {
            Text("Format")
            Picker("Format", selection: $format) {
                ForEach(AudioExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 140)
            if format == .mp3 {
                Picker("Quality", selection: $bitrate) {
                    ForEach(MediaProcessingFormat.mp3Bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }.labelsHidden().frame(width: 160)
            } else {
                Picker("Bit depth", selection: $bits) {
                    Text("16-bit PCM").tag(16); Text("24-bit PCM").tag(24); Text("32-bit PCM").tag(32)
                }.labelsHidden().frame(width: 160)
            }
        }.onAppear {
            let value = MediaProcessingFormat.load(scope)
            format = value.format; bits = value.bitDepth; bitrate = value.bitrate
        }.onChange(of: format) { _ in save() }.onChange(of: bits) { _ in save() }.onChange(of: bitrate) { _ in save() }
    }
    private func save() {
        let root = "jaras.media." + scope + "."
        UserDefaults.standard.set(format.rawValue, forKey: root + "format")
        UserDefaults.standard.set(bits, forKey: root + "bits")
        UserDefaults.standard.set(bitrate, forKey: root + "bitrate")
    }
}
