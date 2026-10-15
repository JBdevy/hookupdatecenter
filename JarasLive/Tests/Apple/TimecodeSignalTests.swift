import Foundation
import AVFoundation
import CoreMIDI

// Decode the actual PCM independently of Core/Timecode/Timecode.hpp.
// SMPTE ST 12-1: 80-bit words, BCD fields, DF skip rules and even polarity.
// See https://pub.smpte.org/doc/st12-1/20140220-pub/st0012-1-2014.pdf.
for sampleRate in [44100.0,48000.0] {
    for fps in [24.0,25,29.97,30] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,channels: 2)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline,format: format,maximumFrameCount: 512)
        let signal = JarasTimecodeGenerator(format: format)
        engine.attach(signal.node); engine.connect(signal.node,to: engine.mainMixerNode,format: format)
        try engine.start()
        let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 512)!
        let rate = fps == 29.97 ? 30000.0/1001.0 : fps
        let nominal = Int(fps.rounded())
        let dayFrames = fps == 29.97 ? 2589408 : nominal * 86400
        // Each reconfiguration is also a seek. Include minute, ten-minute,
        // hour and midnight boundaries, plus a nonzero absolute hour offset.
        for position in [0.0, 59.8, 599.8, 3599.8, 3601.5, 86399.8] {
            let anchor = mach_absolute_time()
            signal.configurePosition(position,end: position + 10,hostTime: anchor,rate: fps,mode: "ltc",running: true,destination: 0)
            var pcm: [Float] = []
            let beforeRender = AVAudioTime.seconds(forHostTime: mach_absolute_time() - anchor)
            var afterFirstRender = beforeRender
            for block in 0..<Int(sampleRate/512) {
                let status = try engine.renderOffline(512,to: buffer)
                precondition(status == .success)
                if block == 0 { afterFirstRender = AVAudioTime.seconds(forHostTime: mach_absolute_time() - anchor) }
                precondition((0..<Int(buffer.frameLength)).allSatisfy {
                    buffer.floatChannelData![0][$0] == buffer.floatChannelData![1][$0]
                }, "LTC stereo outputs carry identical timecode")
                pcm += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],count: Int(buffer.frameLength)))
            }
            let edges = (1..<pcm.count).filter { (pcm[$0] > 0) != (pcm[$0-1] > 0) }
            precondition(abs(signal.takePeak() - 0.25) < 0.00001, "LTC meter reports the actual rendered signal peak")
            precondition(signal.takePeak() == 0, "the meter consumes each peak once")
            let half = sampleRate / (rate * 160)
            let lengths = zip(edges,edges.dropFirst()).map { Double($1-$0)/half }
            precondition(lengths.allSatisfy { abs($0-1) < 0.13 || abs($0-2) < 0.13 }, "LTC uses one or two half-bit intervals at the selected rate")
            var bits: [Int] = [], starts: [Int] = []; var index=0
            while index < lengths.count {
                if lengths[index] > 1.5 { bits.append(0); starts.append(edges[index]); index += 1 }
                else if index+1 < lengths.count && lengths[index+1] < 1.5 { bits.append(1); starts.append(edges[index]); index += 2 }
                else if index+1 == lengths.count { break }
                else { bits.removeAll(); starts.removeAll(); index += 1 }
            }
            let sync = (0..<16).map { (0xbffc >> $0) & 1 }
            let syncs = (0..<max(0,bits.count-16)).filter { Array(bits[$0..<$0+16]) == sync }
            precondition(syncs.count >= Int(fps)-3, "LTC waveform must decode into complete frames")
            precondition(zip(syncs,syncs.dropFirst()).allSatisfy { $1-$0 == 80 }, "LTC has exactly 80 bits per frame")
            var previous: Int?
            for syncIndex in syncs where syncIndex >= 64 {
                let at = syncIndex - 64
                func value(_ offset: Int, _ width: Int) -> Int {
                    (0..<width).reduce(0) { $0 | (bits[at + offset + $1] << $1) }
                }
                let frame = value(0,4) + 10 * value(8,2)
                let second = value(16,4) + 10 * value(24,3)
                let minute = value(32,4) + 10 * value(40,3)
                let hour = value(48,4) + 10 * value(56,2)
                precondition([0,16,32,48].allSatisfy { value($0,4) <= 9 } &&
                    frame < nominal && second < 60 && minute < 60 && hour < 24, "LTC fields contain valid BCD time")
                precondition(bits[at + 10] == (fps == 29.97 ? 1 : 0), "LTC drop-frame flag matches the selected rate")
                precondition(bits[at..<at+80].reduce(0,+) % 2 == 0, "LTC polarity correction keeps every word even")
                if fps == 29.97 && minute % 10 != 0 && second == 0 {
                    precondition(frame >= 2, "DF skips frame labels 00 and 01 except every tenth minute")
                }
                let totalMinutes = hour * 60 + minute
                let dropped = fps == 29.97 ? 2 * (totalMinutes - totalMinutes / 10) : 0
                let serial = ((hour * 3600 + minute * 60 + second) * nominal + frame) - dropped
                if let previous {
                    precondition(serial == (previous + 1) % dayFrames, "decoded LTC advances exactly one frame across clock rollovers")
                } else {
                    // Bound the first native callback's wall-clock anchor, then
                    // locate this frame by its first bit in the captured PCM.
                    let sampleTime = Double(starts[at]) / sampleRate
                    let lower = Int(floor((position + beforeRender + sampleTime) * rate))
                    let upper = Int(ceil((position + afterFirstRender + sampleTime) * rate))
                    precondition((lower-1...upper+1).contains { ($0 % dayFrames) == serial },
                        "decoded LTC carries the requested absolute time after seeking")
                }
                previous = serial
            }
            precondition(previous != nil, "decode complete time addresses, not just sync markers")
        }
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
print("TIMECODE_LTC_PCM_DECODE_ABSOLUTE_TIME_SEEK_DF_ROLLOVERS_STEREO_44100_48000_ALL_RATES_AND_STOP_OK")

final class ReceivedMTC: @unchecked Sendable {
    let lock = NSLock()
    var messages: [(UInt64,[UInt8])] = []
    let complete = DispatchSemaphore(value: 0)
    let completionCount: Int
    init(completionCount: Int = 8) { self.completionCount = completionCount }
    func accept(_ list: UnsafePointer<MIDIPacketList>) {
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<list.pointee.numPackets {
            let bytes = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
            messages.append((packet.pointee.timeStamp,Array(UnsafeBufferPointer(start: bytes,count: Int(packet.pointee.length)))))
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        if messages.filter({ $0.1.first == 0xf1 }).count >= completionCount { complete.signal() }
    }
}
let receiver = ReceivedMTC()
var client: MIDIClientRef = 0, destination: MIDIEndpointRef = 0
precondition(MIDIClientCreateWithBlock("CatLive Test Receiver" as CFString,&client,nil) == noErr)
precondition(MIDIDestinationCreateWithBlock(client,"CatLive Test MTC" as CFString,&destination,{ packets,_ in receiver.accept(packets) }) == noErr)
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

// Verify actual CoreMIDI endpoint traffic, including the payload and the
// timestamp interval (not just the order of quarter-frame type nibbles).
// https://midi.org/midi-time-code
for (fps, rateCode) in [(24.0,0), (25.0,1), (29.97,2), (30.0,3)] {
    let received = ReceivedMTC(completionCount: 16)
    var endpoint: MIDIEndpointRef = 0
    precondition(MIDIDestinationCreateWithBlock(client,"CatLive Rate Test" as CFString,&endpoint,
        { packets,_ in received.accept(packets) }) == noErr)
    defer { MIDIEndpointDispose(endpoint) }
    var identifier: Int32 = 0
    MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&identifier)
    let source = JarasTimecodeGenerator(format: AVAudioFormat(standardFormatWithSampleRate: 48000,channels: 2)!)
    let anchor = mach_absolute_time()
    source.configurePosition(3600,end: 3610,hostTime: anchor,rate: fps,mode: "mtc",running: true,destination: identifier)
    precondition(received.complete.wait(timeout: .now()+3) == .success, "all rates deliver two complete MTC cycles")
    source.configurePosition(3600,end: 3610,hostTime: mach_absolute_time(),rate: fps,mode: "",running: false,destination: identifier)
    Thread.sleep(forTimeInterval: 0.05)
    received.lock.lock(); let traffic = received.messages; received.lock.unlock()
    let full = traffic.first { $0.1.first == 0xf0 }!.1
    precondition(full == [0xf0,0x7f,0x7f,1,1,UInt8(1 | (rateCode << 5)),0,0,0,0xf7],
        "MTC locate transmits the requested hour and the correct rate code")
    let quarters = Array(traffic.filter { $0.1.first == 0xf1 }.prefix(16))
    let rate = fps == 29.97 ? 30000.0/1001.0 : fps
    precondition(quarters.count == 16)
    for (index, packet) in quarters.enumerated() {
        precondition(packet.1.count == 2 && Int(packet.1[1] >> 4) == index % 8,
            "quarter frames preserve all eight message types across cycles")
        let elapsed = AVAudioTime.seconds(forHostTime: packet.0 - anchor)
        precondition(abs(elapsed - Double(index)/(rate*4)) < 0.00001,
            "quarter-frame timestamps follow the selected physical rate")
    }
    for cycle in 0..<2 {
        let n = quarters[(cycle*8)..<(cycle*8+8)].map { Int($0.1[1] & 0xf) }
        precondition(n[0] | (n[1] << 4) == cycle*2 && n[2] | (n[3] << 4) == 0 &&
            n[4] | (n[5] << 4) == 0 && n[6] | ((n[7] & 1) << 4) == 1 && n[7] >> 1 == rateCode,
            "a complete MTC cycle encodes one coherent address and advances two frames")
    }
    Thread.sleep(forTimeInterval: 0.05)
    received.lock.lock(); let finalCount = received.messages.count; received.lock.unlock()
    precondition(finalCount == traffic.count, "stopping prevents subsequent quarter-frame traffic")
}
print("TIMECODE_MTC_ALL_RATES_DECODED_ADDRESSES_TWO_FRAME_CYCLES_TIMESTAMPS_AND_STOP_OK")
