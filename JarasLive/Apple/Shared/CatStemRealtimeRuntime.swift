#if os(iOS)
import Foundation

enum CatStemRealtimeRuntime {
    static func modelURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: "CatStemHTDemucs6", withExtension: "mlmodelc") else {
            throw ProjectError.invalid(JarasLocalization.string("The CatStem Core ML model is missing from this installation."))
        }
        return url
    }
}
#endif
