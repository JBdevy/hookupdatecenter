import SwiftUI

final class VideoMediaSettings: ObservableObject {
    static let shared = VideoMediaSettings()
    struct Resolution: Hashable, Identifiable {
        let width: Int; let height: Int
        var id: Int { height }
        var title: String { "\(width) × \(height)" }
    }
    static let resolutions = [Resolution(width: 640, height: 360), Resolution(width: 854, height: 480), Resolution(width: 1280, height: 720), Resolution(width: 1920, height: 1080)]
    @Published var stretch: Bool { didSet { UserDefaults.standard.set(stretch, forKey: "jaras.video.stretch") } }
    @Published var blackAndWhite: Bool { didSet { UserDefaults.standard.set(blackAndWhite, forKey: "jaras.video.grayscale") } }
    @Published var noAudio: Bool { didSet { UserDefaults.standard.set(noAudio, forKey: "jaras.video.noAudio") } }
    @Published var resolution: Int { didSet { UserDefaults.standard.set(resolution, forKey: "jaras.video.resolution") } }
    init() {
        stretch = UserDefaults.standard.bool(forKey: "jaras.video.stretch")
        blackAndWhite = UserDefaults.standard.bool(forKey: "jaras.video.grayscale")
        noAudio = UserDefaults.standard.object(forKey: "jaras.video.noAudio") as? Bool ?? true
        let saved = UserDefaults.standard.integer(forKey: "jaras.video.resolution")
        resolution = Self.resolutions.contains { $0.height == saved } ? saved : 1080
    }
    var size: CGSize {
        let selected = Self.resolutions.first { $0.height == resolution } ?? Self.resolutions.last!
        return CGSize(width: selected.width, height: selected.height)
    }
}
struct AdvancedVideoSettings: View {
    @ObservedObject private var settings = VideoMediaSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Stretch", isOn: $settings.stretch)
            HStack {
                Text("Resolution")
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(VideoMediaSettings.resolutions) { Text($0.title).tag($0.height) }
                }.labelsHidden().frame(width: 190)
            }
            Toggle("Black and white", isOn: $settings.blackAndWhite)
            Toggle("No audio", isOn: $settings.noAudio)
        }
    }
}
