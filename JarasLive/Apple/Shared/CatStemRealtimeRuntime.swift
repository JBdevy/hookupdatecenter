#if os(macOS)
import Foundation

enum CatStemRealtimeRuntime {
    struct Paths {
        let executable: URL
        let worker: URL
        let models: URL
    }
    /// Do not load/link MLX into the DAW process. Its separate helper requires
    /// macOS 14; the DAW itself continues to run on Intel and macOS 12.
    static func paths(bundle: Bundle = .main) throws -> Paths {
        #if arch(arm64)
        guard #available(macOS 14, *) else {
            throw ProjectError.invalid("CatStem em tempo real requer macOS 14 ou posterior e Apple Silicon.")
        }
        guard let resources = bundle.resourceURL else {
            throw ProjectError.invalid("O motor CatStem não está incluído nesta instalação.")
        }
        let runtime = resources.appendingPathComponent("StemSeparationRuntime/realtime-arm64", isDirectory: true)
        let paths = Paths(executable: runtime.appendingPathComponent("python/bin/python3.11"),
                          worker: resources.appendingPathComponent("StemSeparation/stream.py"),
                          models: runtime.appendingPathComponent("models", isDirectory: true))
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: paths.executable.path),
              fm.fileExists(atPath: paths.worker.path),
              fm.fileExists(atPath: paths.models.appendingPathComponent("htdemucs_6s.safetensors").path),
              fm.fileExists(atPath: paths.models.appendingPathComponent("htdemucs_6s_config.json").path) else {
            throw ProjectError.invalid("O motor CatStem em tempo real não está incluído nesta instalação.")
        }
        return paths
        #else
        throw ProjectError.invalid("CatStem em tempo real requer macOS 14 ou posterior e Apple Silicon.")
        #endif
    }
}
#endif
