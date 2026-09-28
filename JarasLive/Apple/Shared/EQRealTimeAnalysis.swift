import Foundation
import Combine
import Accelerate

struct EQSpectrum: Equatable, Sendable {
    static let binCount = 192
    static let minimumDB: Float = -96
    static let maximumDB: Float = 12
    var input = [Float](repeating: minimumDB, count: binCount)
    var output = [Float](repeating: minimumDB, count: binCount)
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
    init() { vDSP_hann_window(&window, vDSP_Length(Self.samples), Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(setup) }
    private func accumulate(_ data: Data?, rate: Double, into levels: inout [Float]) {
        guard rate.isFinite, rate >= 8000, let data, data.count == Self.samples * 2 * MemoryLayout<Float>.size else { return }
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
                    let frequency = EQSpectrum.frequency(at: bin)
                    guard frequency < rate / 2 else { continue }
                    let fftBin = min(Self.samples / 2 - 1, max(1, Int((frequency * Double(Self.samples) / rate).rounded())))
                    let power = powers[fftBin] / Float(Self.samples * Self.samples / 2)
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
    func update(frames: [EQAnalysisFrame]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !busy, now - lastUpdate >= 1.0 / 20 else { return }
        let elapsed = lastUpdate == 0 ? 1.0 / 15 : now - lastUpdate
        lastUpdate = now; busy = true
        let analyzer = analyzer
        worker.async { [weak self] in
            let next = analyzer.analyze(frames, elapsed: elapsed)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.spectrum != next { self.spectrum = next }
                self.busy = false
            }
        }
    }
}
