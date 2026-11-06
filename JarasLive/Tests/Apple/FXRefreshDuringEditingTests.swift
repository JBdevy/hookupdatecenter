import AppKit
import SwiftUI
import Combine

// The production views and analyzers run unchanged. Their audio source and
// app-only theme/font registration are replaced for this standalone fixture.
@MainActor final class StemAudioPlayback {
    static let shared = StemAudioPlayback()
    var rta = 0, meters = 0, spectrogram = 0
    func eqSpectrumFrames(_ target: UUID?, effect: String) -> [EQAnalysisFrame] { rta += 1; return [] }
    func effectPeaks(_ target: UUID?, effect: String) -> [Float] { meters += 1; return [0.4, 0.2, 0.3, 0.1] }
    func spectrumFrame(_ target: UUID?, effect: String) -> Data? { spectrogram += 1; return nil }
}
struct EQAnalysisFrame: Sendable { let input: Data?, output: Data?, sampleRate: Double }
final class AudioDeviceSettings { static let shared = AudioDeviceSettings(); let sampleRate = 48000.0 }
enum JarasTheme { static let green = Color.green, secondary = Color.gray, display = Color.black, line = Color.gray }
extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
extension Font {
    static func jarasSystem(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: size, weight: weight ?? .regular, design: design ?? .default)
    }
}
@MainActor final class EditingActivity: ObservableObject { @Published var revision = 0 }
@MainActor struct EditingHost: View {
    @ObservedObject var activity: EditingActivity
    var body: some View {
        VStack {
            Text("Parameter \(activity.revision)")
            EQRTAOverlay(target: nil).frame(height: 100)
            EffectVerticalMeters(track: nil, effect: "Compressor")
            EffectSpectrogram(track: nil, effect: "Reverb").frame(height: 120)
        }
    }
}
@main struct FXRefreshDuringEditingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let analyzer = EQSpectrumDisplay()
        var captures = 0
        analyzer.update { captures += 1; return [] }
        analyzer.update { captures += 1; return [] }
        precondition(captures == 1, "A busy analyzer must not copy audio frames that it cannot consume")
        NSApp.setActivationPolicy(.accessory)
        let activity = EditingActivity()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CatLive — teste de atualização dos FX"
        window.contentView = NSHostingView(rootView: EditingHost(activity: activity))
        window.orderFrontRegardless()
        // Mounting SwiftUI and preparing the first Core Animation frames can
        // consume the entire measurement window on a cold CI runner. Wait for
        // all production displays to start before exercising parameter edits.
        let source = StemAudioPlayback.shared
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 15
        while (source.rta == 0 || source.meters == 0 || source.spectrogram == 0),
              ProcessInfo.processInfo.systemUptime < readyDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let ready = "FX_REFRESH_READY rta=\(source.rta) meters=\(source.meters) spectrogram=\(source.spectrogram)\n"
        FileHandle.standardError.write(Data(ready.utf8))
        precondition(source.rta > 0 && source.meters > 0 && source.spectrogram > 0,
                     "FX displays must mount before measuring editing refresh")
        source.rta = 0; source.meters = 0; source.spectrogram = 0
        let editing = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { activity.revision += 1 } }
        RunLoop.main.add(editing, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        editing.invalidate()
        let result = "FX_REFRESH_DURING_EDITING revisions=\(activity.revision) rta=\(source.rta) meters=\(source.meters) spectrogram=\(source.spectrogram)\n"
        FileHandle.standardError.write(Data(result.utf8))
        window.contentView = nil; window.close()
        precondition(activity.revision >= 80, "Must exercise continuous parameter changes")
        precondition(source.rta >= 20 && source.meters >= 30 && source.spectrogram >= 15, "FX displays froze during parameter editing")
    }
}
