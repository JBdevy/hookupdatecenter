import SwiftUI

/// New takes and frozen items use their own global format preference.
struct MediaProcessingFormat {
    var format: AudioExportFormat
    var bitDepth: Int
    var bitrate: Int
    var recordingKey: String { format == .mp3 ? "mp3-\(bitrate)" : format.fileExtension + "\(bitDepth)pcm" }
    static func load(_ scope: String, preferences: UserDefaults = .standard) -> Self {
        let root = "jaras.media." + scope + "."
        return Self(format: AudioExportFormat(rawValue: preferences.string(forKey: root + "format") ?? "WAV") ?? .wav,
                    bitDepth: [16,24,32].contains(preferences.integer(forKey: root + "bits")) ? preferences.integer(forKey: root + "bits") : 24,
                    bitrate: [128,160,192,224,256,320].contains(preferences.integer(forKey: root + "bitrate")) ? preferences.integer(forKey: root + "bitrate") : 320)
    }
    var encoding: AudioExportEncoding { AudioExportEncoding(format: format, bitDepth: bitDepth, bitrate: bitrate) }
}
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
                    ForEach([128,160,192,224,256,320], id: \.self) { Text("\($0) kbps").tag($0) }
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
