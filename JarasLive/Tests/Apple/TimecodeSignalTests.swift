import Foundation
import AVFoundation
import CoreMIDI

for sampleRate in [44100.0,48000.0] {
    for fps in [24.0,25,29.97,30] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,channels: 2)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline,format: format,maximumFrameCount: 512)
        let signal = JarasTimecodeGenerator(format: format)
        engine.attach(signal.node); engine.connect(signal.node,to: engine.mainMixerNode,format: format)
        signal.configurePosition(0,end: 10,hostTime: mach_absolute_time(),rate: fps,mode: "ltc",running: true,destination: 0)
        try engine.start()
        let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 512)!
        var pcm: [Float] = []
        for _ in 0..<Int(sampleRate/512) {
            let status = try engine.renderOffline(512,to: buffer)
            precondition(status == .success)
            pcm += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],count: Int(buffer.frameLength)))
        }
        let edges = (1..<pcm.count).filter { (pcm[$0] > 0) != (pcm[$0-1] > 0) }
        precondition(abs(signal.takePeak() - 0.25) < 0.00001, "LTC meter reports the actual rendered signal peak")
        precondition(signal.takePeak() == 0, "the meter consumes each peak once")
        let half = sampleRate / ((fps == 29.97 ? 30000/1001 : fps) * 160)
        let lengths = zip(edges,edges.dropFirst()).map { Double($1-$0)/half }
        precondition(lengths.allSatisfy { abs($0-1) < 0.13 || abs($0-2) < 0.13 }, "LTC uses one or two half-bit intervals at the selected rate")
        var bits: [Int] = []; var index=0
        while index < lengths.count {
            if lengths[index] > 1.5 { bits.append(0); index += 1 }
            else if index+1 < lengths.count && lengths[index+1] < 1.5 { bits.append(1); index += 2 }
            else if index+1 == lengths.count { break }
            else { bits.removeAll(); index += 1 }
        }
        let sync = (0..<16).map { (0xbffc >> $0) & 1 }
        let syncs = (0..<max(0,bits.count-16)).filter { Array(bits[$0..<$0+16]) == sync }
        precondition(syncs.count >= Int(fps)-3, "LTC waveform must decode into complete frames")
        precondition(zip(syncs,syncs.dropFirst()).allSatisfy { $1-$0 == 80 }, "LTC has exactly 80 bits per frame")
        signal.configurePosition(1,end: 10,hostTime: mach_absolute_time(),rate: fps,mode: "ltc",running: false,destination: 0)
        let status = try engine.renderOffline(512,to: buffer)
        precondition(status == .success && (0..<512).allSatisfy { abs(buffer.floatChannelData![0][$0]) < 0.00001 }, "Stop and Mute silence LTC immediately")
        precondition(signal.takePeak() == 0, "stopped and muted Timecode meters show no audio")
        signal.configurePosition(1,end: 10,hostTime: mach_absolute_time(),rate: fps,mode: "mtc",running: true,destination: 0)
        let mtcStatus = try engine.renderOffline(512,to: buffer)
        precondition(mtcStatus == .success)
        precondition(signal.takePeak() == 0 && (0..<512).allSatisfy { abs(buffer.floatChannelData![0][$0]) < 0.00001 }, "MTC is MIDI only and never drives an audio meter")
        engine.stop()
    }
}
print("TIMECODE_LTC_PCM_DECODE_44100_48000_ALL_RATES_AND_STOP_OK")

final class ReceivedMTC: @unchecked Sendable {
    let lock = NSLock()
    var messages: [(UInt64,[UInt8])] = []
    let complete = DispatchSemaphore(value: 0)
    func accept(_ list: UnsafePointer<MIDIPacketList>) {
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<list.pointee.numPackets {
            let bytes = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
            messages.append((packet.pointee.timeStamp,Array(UnsafeBufferPointer(start: bytes,count: Int(packet.pointee.length)))))
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        if messages.filter({ $0.1.first == 0xf1 }).count >= 8 { complete.signal() }
    }
}
let receiver = ReceivedMTC()
var client: MIDIClientRef = 0, destination: MIDIEndpointRef = 0
precondition(MIDIClientCreateWithBlock("Jaras Test Receiver" as CFString,&client,nil) == noErr)
precondition(MIDIDestinationCreateWithBlock(client,"Jaras Test MTC" as CFString,&destination,{ packets,_ in receiver.accept(packets) }) == noErr)
defer { MIDIEndpointDispose(destination); MIDIClientDispose(client) }
var uid: Int32 = 0
MIDIObjectGetIntegerProperty(destination,kMIDIPropertyUniqueID,&uid)
let sourceCount = MIDIGetNumberOfSources()
let generator = JarasTimecodeGenerator(format: AVAudioFormat(standardFormatWithSampleRate: 48000,channels: 2)!)
precondition(MIDIGetNumberOfSources() == sourceCount, "MTC uses existing destinations without publishing a virtual MIDI source")
generator.configurePosition(3601.5,end: 3610,hostTime: mach_absolute_time(),rate: 30,mode: "mtc",running: true,destination: uid)
precondition(receiver.complete.wait(timeout: .now()+3) == .success,"MTC quarter frames reach the selected MIDI endpoint")
generator.configurePosition(3602,end: 3610,hostTime: mach_absolute_time(),rate: 30,mode: "",running: false,destination: uid)
Thread.sleep(forTimeInterval: 0.05)
receiver.lock.lock(); let messages = receiver.messages; receiver.lock.unlock()
let full = messages.first { $0.1.first == 0xf0 }!.1
precondition(full == [0xf0,0x7f,0x7f,1,1,0x61,0,1,15,0xf7],"MTC full-frame locate contains exact HH:MM:SS:FF and rate")
let quarters = messages.filter { $0.1.first == 0xf1 }
precondition(Array(quarters.prefix(8)).enumerated().allSatisfy { Int($0.element.1[1] >> 4) == $0.offset },"MTC transmits all eight quarter-frame pieces in order")
Thread.sleep(forTimeInterval: 0.05)
receiver.lock.lock(); let stoppedCount = receiver.messages.count; receiver.lock.unlock()
precondition(stoppedCount == messages.count,"Mute stops MIDI output as well as LTC")
print("TIMECODE_MTC_ENDPOINT_FULL_FRAME_QUARTERS_AND_MUTE_OK")
generator.configurePosition(1,end: 10,hostTime: mach_absolute_time(),rate: 30,mode: "mtc",running: true,destination: 0)
Thread.sleep(forTimeInterval: 0.1)
receiver.lock.lock(); let noOutputCount = receiver.messages.count; receiver.lock.unlock()
precondition(noOutputCount == stoppedCount, "None must not fall back to another MIDI destination")
let ids = Set(JarasTimecodeGenerator.destinations().compactMap { ($0["id"] as? NSNumber)?.int32Value })
let unknown = (1...Int32.max).first { !ids.contains($0) }!
generator.configurePosition(1,end: 10,hostTime: mach_absolute_time(),rate: 30,mode: "mtc",running: true,destination: unknown)
Thread.sleep(forTimeInterval: 0.1)
receiver.lock.lock(); let missingOutputCount = receiver.messages.count; receiver.lock.unlock()
precondition(missingOutputCount == stoppedCount, "an unavailable endpoint must not send to an unrelated device")
print("TIMECODE_EXISTING_OUTPUT_ONLY_NO_VIRTUAL_SOURCE_OR_FALLBACK_OK")
