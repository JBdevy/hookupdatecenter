import Foundation
enum JarasLocalization { static func string(_ key: String) -> String { key } }
enum ProjectError: Error { case invalid(String) }
final class AVAudioSession {
    enum Category { case playback, playAndRecord }
    enum Mode { case `default` }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let defaultToSpeaker = Self(rawValue: 1)
        static let allowBluetooth = Self(rawValue: 2)
        static let mixWithOthers = Self(rawValue: 4)
    }
    struct Port { let uid: String }
    struct Route { var inputs: [Port] }
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    var category = Category.playback, mode = Mode.default
    var categoryOptions: CategoryOptions = []
    var categoryChanges = 0
    var ports = [Port(uid: "usb"), Port(uid: "builtin")]
    var availableInputs: [Port]? { category == .playAndRecord ? ports : [] }
    var preferredInput: Port?
    var currentRoute = Route(inputs: [])
    var maximumOutputNumberOfChannels = 8, outputNumberOfChannels = 8, preferredOutputNumberOfChannels = 8
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        self.category = category; self.mode = mode; categoryOptions = options; categoryChanges += 1
    }
    func setActive(_ active: Bool) throws { }
    func setPreferredInput(_ port: Port?) throws {
        preferredInput = port; currentRoute.inputs = port.map { [$0] } ?? []
    }
    func setPreferredOutputNumberOfChannels(_ count: Int) throws { preferredOutputNumberOfChannels = count; outputNumberOfChannels = count }
}
final class InputCatalogProbe {
    static let defaultMobileInput = "system"
    var localSessionEnabled = true, localSessionInterrupted = false, localSessionReconfiguring = false
    var inputUID = "", error = ""
    func configure() throws { try configureMobileSession(input: inputUID) }
    // PRODUCTION_SESSION_METHODS
}
func rejected(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Capture accepted a disabled or disconnected input") }
    catch { }
}
let probe = InputCatalogProbe(), session = AVAudioSession.sharedInstance()
precondition(session.availableInputs?.isEmpty == true)
try probe.configure()
precondition(session.availableInputs?.map(\.uid) == ["usb", "builtin"], "USB input must be discoverable even when input selection is None")
precondition(probe.inputUID.isEmpty && session.preferredInput == nil, "Listing inputs must not enable recording")
rejected { try probe.requireLocalInput() }
probe.inputUID = "usb"; try probe.configure(); try probe.requireLocalInput(expectedUID: "usb")
precondition(session.preferredInput?.uid == "usb")
try probe.configure()
precondition(session.categoryChanges == 1, "Repeated route recovery must not generate category-change loops")
session.ports = [.init(uid: "builtin")]; session.currentRoute.inputs = [.init(uid: "builtin")]
try probe.configure()
precondition(probe.inputUID == "usb" && !probe.error.isEmpty, "Keep the missing input selected and report disconnection")
rejected { try probe.requireLocalInput() }
probe.inputUID = "builtin"; probe.localSessionReconfiguring = true
rejected { try probe.requireLocalInput() }
probe.localSessionReconfiguring = false; try probe.configure(); try probe.requireLocalInput(expectedUID: "builtin")
print("IPAD_USB_INPUT_CATALOG_WITH_NONE_CAPTURE_GATING_DISCONNECTION_AND_NO_IMPLICIT_MIC_SWITCH_OK")
