import Foundation
enum JarasLocalization { static func string(_ key: String) -> String { key } }
enum ProjectError: Error { case invalid(String) }
struct OutputDevice {
    let id: String, name: String
    let channels: Int
    let hardwareID: UInt32
}
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func set(_ value: Any, forKey key: String) { values[key] = value }
}
final class AVAudioSession {
    enum Category { case playback, playAndRecord }
    enum Mode { case `default` }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let defaultToSpeaker = Self(rawValue: 1)
        static let allowBluetooth = Self(rawValue: 2)
        static let mixWithOthers = Self(rawValue: 4)
        static let allowBluetoothA2DP = Self(rawValue: 8)
        static let allowAirPlay = Self(rawValue: 16)
    }
    enum PortType { case wired, bluetoothHFP }
    struct Port {
        let uid: String
        var portType = PortType.wired
        var portName: String { uid }
        var channels: [Int]? { [1] }
    }
    struct Route { var inputs: [Port] }
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    var category = Category.playback, mode = Mode.default
    var categoryOptions: CategoryOptions = []
    var categoryChanges = 0
    var ports = [Port(uid: "usb"), Port(uid: "builtin")]
    var availableInputs: [Port]? {
        category == .playAndRecord ? ports.filter { $0.portType != .bluetoothHFP || categoryOptions.contains(.allowBluetooth) } : []
    }
    var preferredInput: Port?
    var currentRoute = Route(inputs: [])
    var maximumOutputNumberOfChannels = 8, outputNumberOfChannels = 8, preferredOutputNumberOfChannels = 8
    var maximumInputNumberOfChannels = 8, preferredInputNumberOfChannels = 1
    var inputChannelChanges = 0
    var inputNumberOfChannels = 1
    var rejectNextActivation = false
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        self.category = category; self.mode = mode; categoryOptions = options; categoryChanges += 1
    }
    func setActive(_ active: Bool) throws {
        if rejectNextActivation { rejectNextActivation = false; throw ProjectError.invalid("Route unavailable") }
    }
    func setPreferredInput(_ port: Port?) throws {
        preferredInput = port; currentRoute.inputs = port.map { [$0] } ?? []
    }
    func setPreferredOutputNumberOfChannels(_ count: Int) throws { preferredOutputNumberOfChannels = count; outputNumberOfChannels = count }
    func setPreferredInputNumberOfChannels(_ count: Int) throws {
        preferredInputNumberOfChannels = count; inputChannelChanges += 1
    }
}
final class InputCatalogProbe {
    static let defaultMobileInput = "system"
    static let bluetoothMobileInput = "catlive.mobile.bluetooth-input"
    static let systemDefaultUID = "catlive.system-default"
    var localSessionEnabled = true, localSessionInterrupted = false, localSessionReconfiguring = false
    var inputUID = "", error = ""
    var followsSystemOutput = false
    struct Device { var id: String }
    var routeUID = "speaker", selectedUID = "speaker"
    var devices = [Device(id: "speaker")]
    var deviceChanged: (() -> Void)?
    func refresh() {
        devices = routeUID.isEmpty ? [] : [Device(id: routeUID)]
        if selectedUID != "none" { selectedUID = devices.first?.id ?? "" }
    }
    func refreshSampleRate() { }
    func refreshBuffer() { }
    func bindOutput(_ uid: String) {
        selectedUID = uid; UserDefaults.standard.set(uid, forKey: "jaras.audioOutputUID")
        error = ""; deviceChanged?()
    }
    func select(_ uid: String) { selectMobileOutput(uid) }
    func configure() throws { try configureMobileSession(input: inputUID) }
    func inputCatalog() -> [OutputDevice] { mobileInputDevices(AVAudioSession.sharedInstance()) }
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
precondition(session.preferredInputNumberOfChannels == 8, "Expose every input channel on a multichannel interface")
try probe.configure()
precondition(session.categoryChanges == 1, "Repeated route recovery must not generate category-change loops")
precondition(session.inputChannelChanges == 1, "Repeated configuration must not renegotiate unchanged input channels")
session.ports = [.init(uid: "builtin")]; session.currentRoute.inputs = [.init(uid: "builtin")]
try probe.configure()
precondition(probe.inputUID == "usb" && !probe.error.isEmpty, "Keep the missing input selected and report disconnection")
rejected { try probe.requireLocalInput() }
probe.inputUID = "builtin"; probe.localSessionReconfiguring = true
rejected { try probe.requireLocalInput() }
probe.localSessionReconfiguring = false; try probe.configure(); try probe.requireLocalInput(expectedUID: "builtin")
// Following the system route keeps the input catalog, USB recording and other
// apps' audio available without making Bluetooth prefer its call profile.
probe.followsSystemOutput = true; probe.inputUID = ""
try probe.configure()
precondition(session.categoryOptions.contains(.mixWithOthers), "Never interrupt other apps in system-default mode")
precondition(session.categoryOptions.contains(.allowBluetoothA2DP) && session.categoryOptions.contains(.allowAirPlay))
precondition(!session.categoryOptions.contains(.allowBluetooth) && !session.categoryOptions.contains(.defaultToSpeaker),
             "Do not force a call profile or override the default output")
precondition(session.availableInputs?.map(\.uid) == ["builtin"] && session.preferredInput == nil)
let configuredCategoryChanges = session.categoryChanges
try probe.configure()
precondition(session.categoryChanges == configuredCategoryChanges, "Repeated route recovery must not switch categories")
session.ports = [.init(uid: "usb"), .init(uid: "builtin")]
probe.inputUID = "usb"; try probe.configure(); try probe.requireLocalInput(expectedUID: "usb")
precondition(session.preferredInput?.uid == "usb" && session.categoryOptions.contains(.mixWithOthers))
probe.inputUID = ""
probe.select(InputCatalogProbe.systemDefaultUID)
precondition(probe.followsSystemOutput && probe.selectedUID == "speaker")
precondition(UserDefaults.standard.values["catlive.followSystemOutput"] as? Bool == true)
probe.routeUID = "bluetooth-stereo"; probe.refresh(); try probe.configure()
precondition(probe.followsSystemOutput && probe.selectedUID == "bluetooth-stereo", "System choice survives hardware UID changes")
let stereoCategoryChanges = session.categoryChanges
probe.select("bluetooth-stereo")
precondition(!probe.followsSystemOutput && probe.selectedUID == "bluetooth-stereo")
precondition(session.categoryOptions.contains(.allowBluetoothA2DP) && !session.categoryOptions.contains(.allowBluetooth),
             "Selecting Bluetooth by name must preserve stereo output, never enable the call profile")
precondition(session.categoryOptions.contains(.mixWithOthers), "Direct Bluetooth selection must keep other apps playing")
precondition(session.categoryChanges == stereoCategoryChanges,
             "Changing the output label must not renegotiate the Bluetooth profile or sample rate")
probe.select(InputCatalogProbe.systemDefaultUID)
precondition(session.categoryChanges == stereoCategoryChanges, "Returning to system default keeps the same audio route")
session.rejectNextActivation = true
probe.select("bluetooth-stereo")
precondition(probe.followsSystemOutput && !probe.error.isEmpty, "Rejected session changes roll back the visible selection")
precondition(UserDefaults.standard.values["catlive.followSystemOutput"] as? Bool == true)
probe.select("bluetooth-stereo")
precondition(!probe.followsSystemOutput && probe.error.isEmpty)
probe.select("none")
precondition(probe.selectedUID == "none" && !probe.followsSystemOutput)
probe.routeUID = ""; probe.refresh()
probe.select(InputCatalogProbe.systemDefaultUID)
precondition(probe.followsSystemOutput && probe.selectedUID.isEmpty, "System default is selectable even while no output is available")
probe.routeUID = "usb"; probe.refresh(); try probe.configure()
precondition(probe.followsSystemOutput && probe.selectedUID == "usb")
probe.localSessionEnabled = false
let changesBeforeRemote = session.categoryChanges
probe.select("usb")
precondition(session.categoryChanges == changesBeforeRemote, "The Remote UI must never activate a local audio session")
print("IPAD_SYSTEM_DEFAULT_STEREO_BLUETOOTH_MIXING_USB_CAPTURE_AND_RECOVERY_OPTIONS_OK")
print("IPAD_NAMED_BLUETOOTH_SELECTION_PRESERVES_STEREO_MIXING_AND_SESSION_CATEGORY_OK")
print("IPAD_USB_INPUT_CATALOG_WITH_NONE_CAPTURE_GATING_DISCONNECTION_AND_NO_IMPLICIT_MIC_SWITCH_OK")

// Listing an HFP-capable microphone must not degrade the A2DP output. Only
// selecting that input enables the call profile; None/USB restore music mode.
probe.localSessionEnabled = true
session.ports = [.init(uid: "usb"), .init(uid: "builtin"), .init(uid: "headset-mic", portType: .bluetoothHFP)]
probe.inputUID = ""; try probe.configure()
let musicCategoryChanges = session.categoryChanges
precondition(session.availableInputs?.contains(where: { $0.portType == .bluetoothHFP }) == false)
precondition(probe.inputCatalog().contains(where: { $0.id == InputCatalogProbe.bluetoothMobileInput }),
             "Bluetooth microphone must remain selectable before HFP is activated")
precondition(session.categoryChanges == musicCategoryChanges && !session.categoryOptions.contains(.allowBluetooth))
probe.inputUID = InputCatalogProbe.bluetoothMobileInput; try probe.configure()
precondition(session.categoryOptions.contains(.allowBluetooth) && session.categoryOptions.contains(.mixWithOthers))
precondition(session.preferredInput?.uid == "headset-mic")
try probe.requireLocalInput(expectedUID: InputCatalogProbe.bluetoothMobileInput)
precondition(!probe.inputCatalog().contains(where: { $0.id == "headset-mic" }), "Expose one stable Bluetooth choice")
let microphoneCategoryChanges = session.categoryChanges
try probe.configure()
probe.select(InputCatalogProbe.systemDefaultUID)
probe.select("usb")
precondition(session.categoryChanges == microphoneCategoryChanges,
             "Output selection must preserve an explicitly selected Bluetooth microphone")
session.ports.removeAll { $0.portType == .bluetoothHFP }
session.currentRoute.inputs = [.init(uid: "builtin")]
try probe.configure()
rejected { try probe.requireLocalInput() }
precondition(!probe.error.isEmpty, "A missing headset must never silently capture the built-in mic")
session.ports.append(.init(uid: "reconnected-mic", portType: .bluetoothHFP))
try probe.configure(); try probe.requireLocalInput()
precondition(session.preferredInput?.uid == "reconnected-mic", "Reconnect must resolve the current HFP port")
for input in ["", "usb", InputCatalogProbe.defaultMobileInput] {
    probe.inputUID = InputCatalogProbe.bluetoothMobileInput; try probe.configure()
    probe.inputUID = input; try probe.configure()
    precondition(!session.categoryOptions.contains(.allowBluetooth) && session.categoryOptions.contains(.allowBluetoothA2DP),
                 "Leaving the Bluetooth microphone must restore stereo music routing")
    if input == "usb" { try probe.requireLocalInput(); precondition(session.preferredInput?.uid == "usb") }
}
print("IPAD_BLUETOOTH_MIC_EXPLICIT_OPT_IN_CAPTURE_GUARD_RECONNECT_AND_STEREO_RESTORE_OK")
