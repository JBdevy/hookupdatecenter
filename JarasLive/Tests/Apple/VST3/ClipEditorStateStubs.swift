import Foundation
import SwiftUI
import AVFoundation
public enum ProjectError: Error { case invalid(String) }
struct TestClip { let id: UUID; var fx: NativeFXSettings? }
struct TestTrack { enum Kind { case standard }; var id = UUID(); var kind = Kind.standard; var clips: [TestClip] = [] }
struct TestSong { var tracks: [TestTrack] = [] }
struct TestProject { var id = UUID(); var clips: [UUID: TestClip] = [:] }
struct TestSnapshot { var project = TestProject() }
struct AutomationTarget { enum Kind { case externalFX }; init(_ kind: Kind, plugin: String, parameter: UInt32) {} }
@MainActor final class ShowController {
    var snapshot = TestSnapshot(), current: TestSong?
    var trackSettings: [UUID: NativeFXSettings] = [:], masterSettings = NativeFXSettings()
    var clipWrites: [UUID] = [], trackWrites = 0, automationWrites = 0
    func fxSettings(_ track: UUID?) -> NativeFXSettings { track.flatMap { trackSettings[$0] } ?? masterSettings }
    func clipFXSettings(_ clip: UUID) -> NativeFXSettings { snapshot.project.clips[clip]!.fx! }
    func previewClipFX(_ clip: UUID, settings: NativeFXSettings) { snapshot.project.clips[clip]!.fx = settings; clipWrites.append(clip) }
    func previewFX(_ track: UUID?, settings: NativeFXSettings) { trackWrites += 1; if let track { trackSettings[track] = settings } else { masterSettings = settings } }
    func commitFX() {}
    func recordAutomationControl(_ track: UUID?, target: AutomationTarget, value: Double) { automationWrites += 1 }
    func endAutomationTouch(_ track: UUID?) {}
}
enum FXModelLookup { static func clip(_ id: UUID, in project: TestProject) -> TestClip? { project.clips[id] } }
@MainActor final class NativeEffectsChain {
    let node: AVAudioUnitEffect; var externalError: Error?
    init(node: AVAudioUnitEffect) { self.node = node }
    func externalNode(_ id: String) -> AVAudioUnitEffect? { node }
}
@MainActor final class StemAudioPlayback {
    static let shared = StemAudioPlayback()
    var chains: [UUID: NativeEffectsChain] = [:], observed: Set<UUID> = [], lookups = 0
    func effects(for target: UUID?) -> NativeEffectsChain? { lookups += 1; return target.flatMap { chains[$0] } }
    func observeEffect(_ target: UUID?, effect: String, active: Bool) { if let target { if active { observed.insert(target) } else { observed.remove(target) } } }
}
enum JarasTheme { static let panel = Color.black, text = Color.white }
