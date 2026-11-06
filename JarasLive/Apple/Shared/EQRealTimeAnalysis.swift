import Foundation
import SwiftUI
import Combine
import Accelerate

/// The response editor prepares coefficients once per redraw. Rebuilding every
/// band's biquads at every screen pixel made steep cuts expensive on Intel.
struct EQResponseCurve {
    private let coefficients: [[Double]]
    private let rate: Double
    init(coefficients: [[Double]], rate: Double) {
        self.coefficients = coefficients.filter { $0.count == 5 && $0.allSatisfy(\.isFinite) }
        self.rate = rate.isFinite && rate > 0 ? rate : 48000
    }
    func response(frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let cosine = cos(w), sine = sin(w), cosine2 = cos(2 * w), sine2 = sin(2 * w)
        var power = 1.0, decibels = 0.0
        for k in coefficients {
            let nr = k[0] + k[1] * cosine + k[2] * cosine2, ni = -k[1] * sine - k[2] * sine2
            let dr = 1 + k[3] * cosine + k[4] * cosine2, di = -k[3] * sine - k[4] * sine2
            power *= max(1e-20, (nr * nr + ni * ni) / max(1e-20, dr * dr + di * di))
            // Preserve the original per-stage floor without under/overflow in
            // a cascade of brickwall filters. Most pixels need one log only.
            if power < 1e-200 || power > 1e200 { decibels += 10 * log10(power); power = 1 }
        }
        return decibels + 10 * log10(power)
    }
}

struct EQSpectrum: Equatable, Sendable {
    static let binCount = 384
    static let minimumDB: Float = -96
    static let maximumDB: Float = 12
    var input = [Float](repeating: minimumDB, count: binCount)
    var output = [Float](repeating: minimumDB, count: binCount)
    static func smoothedBins(_ bins: [Float]) -> [Float] {
        guard !bins.isEmpty else { return [] }
        let weights: [Float] = [1, 6, 15, 20, 15, 6, 1]
        var levels = bins.map { $0.isFinite ? min(EQSpectrum.maximumDB, max(EQSpectrum.minimumDB, $0)) : EQSpectrum.minimumDB }
        // Two short Gaussian passes produce rounded hills across frequency,
        // keeping flat spectra flat and every value within the measured range.
        for _ in 0..<2 {
            var next = levels
            for index in levels.indices {
                var sum: Float = 0
                for offset in weights.indices {
                    sum += levels[min(levels.count - 1, max(0, index + offset - 3))] * weights[offset]
                }
                next[index] = sum / 64
            }
            levels = next
        }
        return levels
    }

    static func frequency(at index: Int) -> Double { 20 * pow(1000, Double(index) / Double(binCount - 1)) }
}

/// One worker owns all FFT storage. Audio callbacks only publish bounded PCM rings.
final class EQSpectrumAnalyzer: @unchecked Sendable {
    private static let samples = 2048
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: samples)
    private var work = [Float](repeating: 0, count: samples)
    private var real = [Float](repeating: 0, count: samples / 2)
    private var imaginary = [Float](repeating: 0, count: samples / 2)
    private var powers = [Float](repeating: 0, count: samples / 2)
    private var current = EQSpectrum()
    private struct Bin { let lower: Int; let upper: Int; let fraction: Float }
    private static let frequencies = (0..<EQSpectrum.binCount).map { EQSpectrum.frequency(at: $0) }
    private var binMaps: [Double: [Bin?]] = [:]
    init() { vDSP_hann_window(&window, vDSP_Length(Self.samples), Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(setup) }
    private func accumulate(_ data: Data?, rate: Double, into levels: inout [Float]) {
        guard rate.isFinite, rate >= 8000, let data, data.count == Self.samples * 2 * MemoryLayout<Float>.size else { return }
        let bins: [Bin?]
        if let cached = binMaps[rate] { bins = cached }
        else {
            bins = Self.frequencies.map { frequency in
                guard frequency < rate / 2 else { return nil }
                let position = min(Double(Self.samples / 2 - 1), max(1, frequency * Double(Self.samples) / rate))
                let lower = Int(position)
                return Bin(lower: lower, upper: min(Self.samples / 2 - 1, lower + 1), fraction: Float(position - Double(lower)))
            }
            // A handful of simultaneous sources can have different rates;
            // keep the lookup bounded across repeated device changes.
            if binMaps.count >= 8 { binMaps.removeAll(keepingCapacity: true) }
            binMaps[rate] = bins
        }
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Float.self)
            for channel in 0..<2 {
                vDSP_vmul(samples.baseAddress!.advanced(by: channel * Self.samples), 1, window, 1, &work, 1, vDSP_Length(Self.samples))
                real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    work.withUnsafeBufferPointer { buffer in
                        buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.samples / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.samples / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                    split.imagp[0] = 0
                    vDSP_zvmags(&split, 1, &powers, 1, vDSP_Length(Self.samples / 2))
                } }
                for bin in 0..<EQSpectrum.binCount {
                    guard let map = bins[bin] else { continue }
                    let power = (powers[map.lower] + (powers[map.upper] - powers[map.lower]) * map.fraction) / Float(Self.samples * Self.samples / 2)
                    if power.isFinite { levels[bin] += max(0, power) }
                }
            }
        }
    }
    func analyze(_ frames: [EQAnalysisFrame], elapsed: Double = 1.0 / 15.0) -> EQSpectrum {
        var input = [Float](repeating: 0, count: EQSpectrum.binCount)
        var output = input
        for frame in frames {
            accumulate(frame.input, rate: frame.sampleRate, into: &input)
            accumulate(frame.output, rate: frame.sampleRate, into: &output)
        }
        let fall = Float(min(0.25, max(0, elapsed.isFinite ? elapsed : 0)) * 72)
        for bin in 0..<EQSpectrum.binCount {
            let incoming = min(EQSpectrum.maximumDB, max(EQSpectrum.minimumDB, 10 * log10(max(1e-12, input[bin]))))
            let outgoing = min(EQSpectrum.maximumDB, max(EQSpectrum.minimumDB, 10 * log10(max(1e-12, output[bin]))))
            current.input[bin] = incoming > current.input[bin] ? incoming : max(incoming, current.input[bin] - fall)
            current.output[bin] = outgoing > current.output[bin] ? outgoing : max(outgoing, current.output[bin] - fall)
        }
        return current
    }
}

@MainActor final class EQSpectrumDisplay: ObservableObject {
    @Published private(set) var spectrum = EQSpectrum()
    private let worker = DispatchQueue(label: "live.jaras.eq.rta", qos: .utility)
    private let analyzer = EQSpectrumAnalyzer()
    private var busy = false
    private var lastUpdate = 0.0
    func update(frames read: () -> [EQAnalysisFrame]) {
        let now = ProcessInfo.processInfo.systemUptime
        // The UI timer already runs at 20 Hz. A strict 50 ms second gate
        // can reject alternating ticks arriving a fraction early due to jitter.
        guard !busy, now - lastUpdate >= 0.045 else { return }
        let elapsed = lastUpdate == 0 ? 1.0 / 15 : now - lastUpdate
        lastUpdate = now; busy = true
        // Snapshot PCM only when this worker can accept it. Previously every
        // timer tick allocated/captured audio even while analysis was busy.
        let frames = read()
        let analyzer = analyzer
        worker.async { [weak self] in
            var next = analyzer.analyze(frames, elapsed: elapsed)
            next.input = EQSpectrum.smoothedBins(next.input)
            next.output = EQSpectrum.smoothedBins(next.output)
            let rounded = next
            DispatchQueue.main.async {
                guard let self else { return }
                if self.spectrum != rounded { self.spectrum = rounded }
                self.busy = false
            }
        }
    }
}

/// Interpolate the display between completed FFTs, without requesting more FFTs.
struct EQSpectrumVector: VectorArithmetic {
    var values: [Double]
    init(_ spectrum: EQSpectrum) { values = (spectrum.input + spectrum.output).map(Double.init) }
    private init(values: [Double]) { self.values = values }
    static let zero = EQSpectrumVector(values: [])
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(values: (0..<max(lhs.values.count, rhs.values.count)).map { (lhs.values.indices.contains($0) ? lhs.values[$0] : 0) + (rhs.values.indices.contains($0) ? rhs.values[$0] : 0) })
    }
    static func - (lhs: Self, rhs: Self) -> Self {
        Self(values: (0..<max(lhs.values.count, rhs.values.count)).map { (lhs.values.indices.contains($0) ? lhs.values[$0] : 0) - (rhs.values.indices.contains($0) ? rhs.values[$0] : 0) })
    }
    mutating func scale(by rhs: Double) { for index in values.indices { values[index] *= rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    var spectrum: EQSpectrum {
        guard values.count == EQSpectrum.binCount * 2 else { return EQSpectrum() }
        return EQSpectrum(input: values.prefix(EQSpectrum.binCount).map(Float.init), output: values.suffix(EQSpectrum.binCount).map(Float.init))
    }
}
