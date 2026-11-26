import AVFoundation

enum DrummerSamples {
    static var roots: [(String, URL)] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [("Native", Bundle.main.bundleURLForDrumSamples),
                ("User", support.appendingPathComponent("JarasLive/Samplers")),
                ("Pads", support.appendingPathComponent("CatLive/Vinhetas/Pads"))]
    }
    static func reference(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for (name, root) in roots {
            let prefix = root.standardizedFileURL.path + "/"
            if path.hasPrefix(prefix) {
                let key = name + "/" + path.dropFirst(prefix.count)
                return DrummerPadKit.validSample(key) ? key : nil
            }
        }
        return nil
    }
    static func resolve(_ key: String) -> URL? {
        guard DrummerPadKit.validSample(key), let i = key.firstIndex(of: "/"),
              let root = roots.first(where: { $0.0 == String(key[..<i]) })?.1 else { return nil }
        return root.appendingPathComponent(String(key[key.index(after: i)...]))
    }
}
private extension Bundle {
    var bundleURLForDrumSamples: URL { (resourceURL ?? bundleURL).appendingPathComponent("NativeSamples") }
}

final class DrummerPadVoice {
    let mixer = AVAudioMixerNode()
    let source: JarasDrummerPad
    private let loader = DispatchQueue(label: "CatLive.DrummerPad.samples", qos: .userInitiated)
    private var paths: [String?]
    var enabled = false
    init(kind: DrummerPadKind, rate: Double) {
        source = JarasDrummerPad(count: UInt(kind.count), sampleRate: rate)
        paths = Array(repeating: nil, count: kind.count)
    }
    func apply(_ kit: DrummerPadKit, enabled: Bool, offline: Bool) {
        self.enabled = enabled
        source.masterGain(enabled ? Float(kit.volume) : 0)
        if !enabled { source.silence() }
        for (i, pad) in kit.pads.enumerated() where paths.indices.contains(i) {
            source.pad(UInt(i), note: pad.note ?? -1, gain: Float(pad.volume))
            guard paths[i] != pad.sample else { continue }
            paths[i] = pad.sample
            let url = pad.sample.flatMap(DrummerSamples.resolve)
            let work = { [source] in
                let buffer: AVAudioPCMBuffer? = url.flatMap { url in
                    guard let file = try? AVAudioFile(forReading: url),
                          file.length > 0, Double(file.length) <= 60.01 * file.fileFormat.sampleRate else { return nil }
                    return try? PadAudioBuffer.read(file, frames: AVAudioFrameCount(file.length))
                }
                source.sample(buffer, pad: UInt(i))
            }
            if offline { loader.sync(execute: work) } else { loader.async(execute: work) }
        }
    }
}
