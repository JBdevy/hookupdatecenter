import SwiftUI

struct FXParameterMapping: Codable, Equatable {
    var clip: UUID?
    var parameter: NativeFXParameter
    func sameControl(as other: FXParameterMapping?) -> Bool {
        guard let other else { return false }
        return clip == other.clip && parameter.effect == other.parameter.effect && parameter.key == other.parameter.key && parameter.band == other.parameter.band
    }
}
struct FXMIDIScope {
    let track: UUID?
    let clip: UUID?
    let effect: String
}
private struct FXMIDIScopeKey: EnvironmentKey { static let defaultValue: FXMIDIScope? = nil }
extension EnvironmentValues {
    var fxMIDIScope: FXMIDIScope? { get { self[FXMIDIScopeKey.self] } set { self[FXMIDIScopeKey.self] = newValue } }
}
private struct FXParameterMappingModifier: ViewModifier {
    @Environment(\.fxMIDIScope) private var scope
    @ObservedObject private var mappings = ControlMappings.shared
    let key: NativeFXParameter.Key
    let name: String
    let range: ClosedRange<Double>
    let logarithmic: Bool
    let band: UUID?
    let choices: [String]?
    private var parameter: FXParameterMapping? {
        scope.map { FXParameterMapping(clip: $0.clip, parameter: NativeFXParameter(effect: $0.effect, key: key, band: band, name: name, range: range, logarithmic: logarithmic, choices: choices)) }
    }
    func body(content: Content) -> some View {
        content.contextMenu {
            if let scope, let parameter {
                Button("Map MIDI") { mappings.beginFX(track: scope.track, parameter: parameter) }
            }
        }.sheet(isPresented: Binding(get: {
            parameter != nil && mappings.editing?.fxParameter == parameter && mappings.editing?.track == scope?.track
        }, set: { if !$0, mappings.editing?.fxParameter == parameter { mappings.editing = nil } })) {
            ControlMappingEditor()
        }
    }
}
extension View {
    func mapFXMIDI(_ key: NativeFXParameter.Key, name: String, range: ClosedRange<Double>, logarithmic: Bool = false, band: UUID? = nil, choices: [String]? = nil) -> some View {
        modifier(FXParameterMappingModifier(key: key, name: name, range: range, logarithmic: logarithmic, band: band, choices: choices))
    }
}
