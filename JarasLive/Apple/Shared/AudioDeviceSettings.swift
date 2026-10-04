import SwiftUI
import AVFoundation
import CoreMIDI
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

struct OutputDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var channels: Int
    var hardwareID: UInt32
}

struct MIDIInputDevice: Identifiable, Equatable {
    let id: Int32
    let name: String
}
@MainActor final class AudioDeviceSettings: ObservableObject {
    static let shared = AudioDeviceSettings()
    @Published private(set) var inputDevices: [OutputDevice] = []
    @Published private(set) var inputUID = UserDefaults.standard.string(forKey: "catlive.audioInputUID") ?? ""
    var inputDeviceChanged: (() -> Void)?
    var inputDevice: OutputDevice? { inputDevices.first { $0.id == inputUID } }
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var selectedUID = UserDefaults.standard.string(forKey: "jaras.audioOutputUID") ?? ""
    @Published private(set) var channels = 0
    @Published var error = ""
    @Published private(set) var sampleRate = 48000.0
    @Published private(set) var sampleRateChoices: [Double] = [44100, 48000]
    @Published private(set) var bufferFrames = 512
    @Published private(set) var bufferChoices: [Int] = [64, 128, 256, 512, 1024]
    @Published private(set) var midiSources: [String] = []
    @Published private(set) var midiDevices: [MIDIInputDevice] = []
    @Published private(set) var midiOutputs: [MIDIInputDevice] = []
    @Published private(set) var midiOutput = (UserDefaults.standard.object(forKey: "jaras.midiOutput") as? NSNumber)?.int32Value ?? 0
    @Published private(set) var midiSlots: [Int32] = {
        let stored = (UserDefaults.standard.array(forKey: "jaras.midiSlots") as? [NSNumber])?.map(\.int32Value) ?? []
        return Array((stored + [0,0,0]).prefix(3))
    }()
    private var midiNames = UserDefaults.standard.dictionary(forKey: "jaras.midiNames") as? [String:String] ?? [:]
    let engine = AVAudioEngine()
    var deviceChanged: (() -> Void)?
    private var midiClient: MIDIClientRef = 0
    private var configuredUID: String?
    #if os(macOS)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var listeningAddresses: [AudioObjectPropertyAddress] = []
    #endif
    var deviceName: String { devices.first { $0.id == selectedUID }?.name ?? JarasLocalization.string("No output device") }
    private init() {
        MIDIClientCreateWithBlock("CatLive Devices" as CFString, &midiClient) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMIDI() }
        }
        refresh()
        refreshMIDI()
        #if os(macOS)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh() } }
        deviceListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr { listeningAddresses.append(address) }
        }
        #endif
    }
    func refreshMIDI() {
        let inputs = (0..<MIDIGetNumberOfSources()).compactMap { index -> MIDIInputDevice? in
            let source = MIDIGetSource(index)
            var offline: Int32 = 0, uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyOffline, &offline)
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            guard offline == 0, uniqueID != 0 else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            return MIDIInputDevice(id: uniqueID, name: name?.takeRetainedValue() as String? ?? "MIDI \(index + 1)")
        }
        let names = inputs.map(\.name)
        let outputs = (0..<MIDIGetNumberOfDestinations()).compactMap { index -> MIDIInputDevice? in
            let destination = MIDIGetDestination(index)
            var offline: Int32 = 0, uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyOffline, &offline)
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &uniqueID)
            guard offline == 0, uniqueID != 0 else { return nil }
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(destination, kMIDIPropertyDisplayName, &name)
            return MIDIInputDevice(id: uniqueID, name: name?.takeRetainedValue() as String? ?? "MIDI \(index + 1)")
        }
        // Device notifications can contain several events for the same ports.
        // Publish only a changed catalog, so open routing menus remain stable.
        if midiDevices != inputs { midiDevices = inputs }
        if midiSources != names { midiSources = names }
        if midiOutputs != outputs { midiOutputs = outputs }
        var remembered = midiNames
        for device in inputs { remembered[String(device.id)] = device.name }
        for device in outputs { remembered[String(device.id)] = device.name }
        if remembered != midiNames {
            midiNames = remembered
            UserDefaults.standard.set(midiNames, forKey: "jaras.midiNames")
        }
        if UserDefaults.standard.object(forKey: "jaras.midiSlots") == nil, let first = midiDevices.first { selectMIDI(first.id, slot: 0) }
        if UserDefaults.standard.object(forKey: "jaras.midiOutput") == nil, let first = midiOutputs.first { selectMIDIOutput(first.id) }
    }
    func selectMIDIOutput(_ id: Int32) {
        guard id == 0 || midiOutputs.contains(where: { $0.id == id }) else { return }
        midiOutput = id; UserDefaults.standard.set(NSNumber(value: id), forKey: "jaras.midiOutput")
    }
    var midiOutputTitle: String {
        midiOutput == 0 ? JarasLocalization.string("None") : midiOutputs.first(where: { $0.id == midiOutput })?.name ?? ((midiNames[String(midiOutput)] ?? "MIDI") + " — " + JarasLocalization.string("Disconnected"))
    }
    func resolvedMIDIDestination(_ requested: Int32) -> Int32 {
        let id = requested == 0 ? midiOutput : requested
        return midiOutputs.contains(where: { $0.id == id }) ? id : 0
    }
    func selectMIDI(_ id: Int32, slot: Int) {
        guard midiSlots.indices.contains(slot), id == 0 || midiDevices.contains(where: { $0.id == id }),
              id == 0 || !midiSlots.enumerated().contains(where: { $0.offset != slot && $0.element == id }) else { return }
        midiSlots[slot] = id
        UserDefaults.standard.set(midiSlots.map(NSNumber.init(value:)), forKey: "jaras.midiSlots")
    }
    func midiSlotTitle(_ slot: Int) -> String {
        guard midiSlots.indices.contains(slot) else { return "MIDI" }
        let id = midiSlots[slot]
        let name = id == 0 ? JarasLocalization.string("None") : midiDevices.first(where: { $0.id == id })?.name ?? ((midiNames[String(id)] ?? "MIDI") + " — " + JarasLocalization.string("Disconnected"))
        return "MIDI \(slot + 1) · " + name
    }
    func refresh() {
        #if os(macOS)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr else { error = "Unable to list audio devices"; return }
        var ids = Array(repeating: AudioDeviceID(0), count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, $0.baseAddress!) }
        guard result == noErr else { error = "Unable to list audio devices"; return }
        devices = ids.compactMap { id in
            let count = outputChannels(id)
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            let name = stringProperty(id, kAudioObjectPropertyName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard count > 0, !name.isEmpty, !uid.isEmpty, isSelectableOutput(id, uid: uid) else { return nil }
            return OutputDevice(id: uid, name: name, channels: count, hardwareID: id)
        }
        inputDevices = ids.compactMap { id in
            let count = outputChannels(id, scope: kAudioDevicePropertyScopeInput)
            guard count > 0 else { return nil }
            return OutputDevice(id: stringProperty(id, kAudioDevicePropertyDeviceUID), name: stringProperty(id, kAudioObjectPropertyName), channels: count, hardwareID: id)
        }
        inputDeviceChanged?()
        if selectedUID == "none" { channels = 0; return }
        if let selected = devices.first(where: { $0.id == selectedUID }) { channels = selected.channels; if configuredUID != selected.id { select(selected.id) } }
        else {
            var defaultID: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &defaultID)
            if let device = devices.first(where: { $0.hardwareID == defaultID }) ?? devices.first { select(device.id) }
            else { selectedUID = ""; channels = 0 }
        }
        #else
        let session = AVAudioSession.sharedInstance()
        devices = session.currentRoute.outputs.map { OutputDevice(id: $0.uid, name: $0.portName, channels: $0.channels?.count ?? 2, hardwareID: 0) }
        selectedUID = devices.first?.id ?? ""; channels = devices.first?.channels ?? 0
        #endif
    }
    func selectInput(_ uid: String) {
        guard uid.isEmpty || inputDevices.contains(where: { $0.id == uid }) else { return }
        inputUID = uid; UserDefaults.standard.set(uid, forKey: "catlive.audioInputUID")
        inputDeviceChanged?()
    }
    func select(_ uid: String) {
        if uid == "none" {
            selectedUID = uid; channels = 0; configuredUID = nil
            UserDefaults.standard.set(uid, forKey: "jaras.audioOutputUID")
            engine.mainMixerNode.outputVolume = 0; deviceChanged?(); return
        }
        guard let device = devices.first(where: { $0.id == uid }) else { return }
        if configuredUID == uid {
            if !engine.isRunning { deviceChanged?() }
            return
        }
        #if os(macOS)
        guard let unit = engine.outputNode.audioUnit else { error = "Audio output is unavailable"; return }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        var id = AudioDeviceID(device.hardwareID)
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else {
            error = "Unable to open audio device (\(result))"
            // A rejected selection must not leave the previous output stopped.
            if wasRunning { deviceChanged?() }
            return
        }
        #endif
        configuredUID = uid; selectedUID = uid; channels = device.channels; error = ""
        UserDefaults.standard.set(uid, forKey: "jaras.audioOutputUID")
        refreshSampleRate()
        refreshBuffer()
        let savedBuffer = UserDefaults.standard.integer(forKey: "jaras.audioBufferFrames")
        if savedBuffer > 0, bufferChoices.contains(savedBuffer), savedBuffer != bufferFrames { setBuffer(savedBuffer) }
        deviceChanged?()
    }
    func refreshSampleRate() {
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = 0.0
        var bytes = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, &rate) == noErr else { return }
        sampleRate = rate
        address.mSelector = kAudioDevicePropertyAvailableNominalSampleRates
        guard AudioObjectGetPropertyDataSize(device.hardwareID, &address, 0, nil, &bytes) == noErr else { sampleRateChoices = [rate]; return }
        var ranges = Array(repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: Int(bytes) / MemoryLayout<AudioValueRange>.size)
        let result = ranges.withUnsafeMutableBytes { AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, $0.baseAddress!) }
        if result == noErr { sampleRateChoices = Array(Set([44100.0,48000.0].filter { candidate in ranges.contains { candidate >= $0.mMinimum && candidate <= $0.mMaximum } } + [rate])).sorted() }
        #else
        sampleRate = AVAudioSession.sharedInstance().sampleRate
        sampleRateChoices = Array(Set([44100,48000,sampleRate])).sorted()
        #endif
    }
    func setSampleRate(_ rate: Double) {
        guard sampleRateChoices.contains(rate) else { return }
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        engine.stop()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var requested = rate
        let result = AudioObjectSetPropertyData(device.hardwareID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &requested)
        if result != noErr { error = "Unable to change sample rate (\(result))"; refreshSampleRate(); deviceChanged?(); return }
        error = ""
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.refreshSampleRate(); self?.refreshBuffer()
            if let self { UserDefaults.standard.set(self.sampleRate, forKey: "jaras.audioSampleRate"); self.deviceChanged?() }
        }
        #else
        do {
            try AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
            refreshSampleRate(); refreshBuffer(); error = ""
        } catch { self.error = error.localizedDescription }
        #endif
    }
    func refreshBuffer() {
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, &frames) == noErr else { return }
        bufferFrames = Int(frames)
        address.mSelector = kAudioDevicePropertyBufferFrameSizeRange
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        bytes = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(device.hardwareID, &address, 0, nil, &bytes, &range) == noErr {
            bufferChoices = Array(Set([32,64,128,256,512,1024,2048,4096].filter { Double($0) >= range.mMinimum && Double($0) <= range.mMaximum } + [bufferFrames])).sorted()
        } else { bufferChoices = [bufferFrames] }
        #else
        let session = AVAudioSession.sharedInstance()
        bufferFrames = Int((session.ioBufferDuration * session.sampleRate).rounded())
        bufferChoices = Array(Set([64,128,256,512,1024,2048,bufferFrames])).sorted()
        #endif
    }
    func setBuffer(_ frames: Int) {
        guard bufferChoices.contains(frames) else { return }
        #if os(macOS)
        guard let device = devices.first(where: { $0.id == selectedUID }) else { return }
        let running = engine.isRunning
        if running { engine.stop() }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(frames)
        let result = AudioObjectSetPropertyData(device.hardwareID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        refreshBuffer()
        if result == noErr {
            UserDefaults.standard.set(bufferFrames, forKey: "jaras.audioBufferFrames"); error = ""
        } else { error = "Unable to change buffer (\(result))" }
        deviceChanged?()
        #else
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(Double(frames) / session.sampleRate)
            refreshBuffer()
            UserDefaults.standard.set(bufferFrames, forKey: "jaras.audioBufferFrames"); error = ""
        } catch { self.error = error.localizedDescription }
        #endif
    }
    #if os(macOS)
    private func isSelectableOutput(_ id: AudioDeviceID, uid: String) -> Bool {
        // AVAudioEngine creates this temporary input/output aggregate itself.
        // Selecting it as an output creates a dependency on the engine being rebuilt.
        guard !uid.hasPrefix("CADefaultDeviceAggregate-") else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &hidden) == noErr, hidden != 0 { return false }
        address.mSelector = kAudioObjectPropertyClass
        var deviceClass: AudioClassID = 0; bytes = UInt32(MemoryLayout<AudioClassID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &deviceClass) == noErr,
              deviceClass == kAudioAggregateDeviceClassID else { return true }
        address.mSelector = kAudioAggregateDevicePropertyComposition
        var composition: Unmanaged<CFDictionary>?
        bytes = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any] else { return true }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue != true
    }
    private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var text: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &text) == noErr else { return "Device \(id)" }
        return text as String
    }
    private func outputChannels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    #endif
}
