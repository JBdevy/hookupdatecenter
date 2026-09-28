import Foundation
/// Bounded waveform history; growing recordings never copy an unbounded sample array.
public struct RecordingOverview: Sendable {
    public private(set) var peaks: [[Double]]
    private var current: [Double]
    private var remaining: Int
    private var binFrames: Int
    public init(channels: Int, sampleRate: Double) {
        peaks = Array(repeating: [],count: channels); current = Array(repeating: 0,count: channels)
        binFrames = max(1,Int(sampleRate/50)); remaining = binFrames
    }
    public mutating func append(_ sample: Float, channel: Int) { current[channel] = max(current[channel],min(1,Double(abs(sample)))) }
    public mutating func endFrame() {
        remaining -= 1
        guard remaining == 0 else { return }
        for ch in peaks.indices { peaks[ch].append(current[ch]); current[ch] = 0 }
        if peaks.first?.count == 1024 {
            for ch in peaks.indices { peaks[ch] = stride(from: 0,to: 1024,by: 2).map { max(peaks[ch][$0],peaks[ch][$0+1]) } }
            binFrames *= 2
        }
        remaining = binFrames
    }
    public var snapshot: [[Double]] { peaks.enumerated().map { index, values in values + [current[index]] } }
}
