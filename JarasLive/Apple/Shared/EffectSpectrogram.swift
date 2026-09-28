import SwiftUI
import Combine
import Accelerate

/// A serial analysis worker owns its FFT buffers. It never runs on the audio thread.
final class SpectrumRasterizer: @unchecked Sendable {
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0,count: 2048)
    private var work = [Float](repeating: 0,count: 2048)
    private var real = [Float](repeating: 0,count: 1024)
    private var imaginary = [Float](repeating: 0,count: 1024)
    private var power = [Float](repeating: 0,count: 1024)
    private var sum = [Float](repeating: 0,count: 1024)
    private var pixels = [UInt8](repeating: 0,count: 256*96*4)
    init() { vDSP_hann_window(&window,2048,Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(setup) }
    func render(_ data: Data?, rate: Double) -> CGImage? {
        sum.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        if let data, data.count == 4096*MemoryLayout<Float>.size {
            data.withUnsafeBytes { bytes in
                let input = bytes.bindMemory(to: Float.self)
                for channel in 0..<2 {
                    vDSP_vmul(input.baseAddress!.advanced(by: channel*2048),1,window,1,&work,1,2048)
                    real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!,imagp: i.baseAddress!)
                        work.withUnsafeBufferPointer { samples in samples.baseAddress!.withMemoryRebound(to: DSPComplex.self,capacity: 1024) { vDSP_ctoz($0,2,&split,1,1024) } }
                        vDSP_fft_zrip(setup,&split,1,11,FFTDirection(FFT_FORWARD))
                        split.imagp[0] = 0
                        vDSP_zvmags(&split,1,&power,1,1024)
                    } }
                    vDSP_vadd(sum,1,power,1,&sum,1,1024)
                }
            }
        }
        for y in 0..<96 {
            let frequency = 20*pow(min(20000,rate*0.48)/20,Double(95-y)/95)
            let bin = min(1023,max(1,Int(frequency*2048/rate)))
            let db = 10*log10(max(1e-12,sum[bin]/Float(2048*2048*2)))
            let value = min(1,max(0,(db+84)/78))
            let offset = y*256*4
            _ = pixels.withUnsafeMutableBytes { buffer in
                memmove(buffer.baseAddress!.advanced(by: offset),buffer.baseAddress!.advanced(by: offset+4),255*4)
            }
            let position = offset+255*4
            pixels[position] = UInt8(255*max(0,(value-0.5)*2))
            pixels[position+1] = UInt8(255*min(1,value*1.6))
            pixels[position+2] = UInt8(255*(value<0.5 ? value*1.8 : max(0,1-value)*1.8))
            pixels[position+3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: 256,height: 96,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 256*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent)
    }
}
@MainActor private final class SpectrumDisplay: ObservableObject {
    @Published var image: CGImage?
    private let worker = DispatchQueue(label: "live.jaras.spectrum",qos: .utility)
    private let rasterizer = SpectrumRasterizer()
    private var busy = false
    func update(_ data: Data?, rate: Double) {
        guard !busy else { return }; busy = true
        let rasterizer = rasterizer
        worker.async { [weak self] in
            let image = rasterizer.render(data,rate: rate)
            DispatchQueue.main.async { self?.image = image; self?.busy = false }
        }
    }
}
struct EffectSpectrogram: View {
    let track: UUID?
    let effect: String
    @StateObject private var display = SpectrumDisplay()
    private let clock = Timer.publish(every: 1.0/15,on: .main,in: .common).autoconnect()
    var body: some View {
        ZStack {
            JarasTheme.display
            if let image = display.image { Image(decorative: image,scale: 1).resizable().interpolation(.medium) }
            VStack {
                HStack { Text("20 kHz"); Spacer(); Text("OUTPUT · SPECTROGRAM") }
                Spacer()
                HStack { Text("20 Hz"); Spacer(); Text("17 s") }
            }.font(.system(size: 8,weight: .medium,design: .monospaced)).foregroundStyle(.white.opacity(0.55)).padding(8)
        }.frame(minHeight: 120,idealHeight: 155,maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(JarasTheme.line))
            .onReceive(clock) { _ in display.update(StemAudioPlayback.shared.spectrumFrame(track,effect: effect),rate: AudioDeviceSettings.shared.sampleRate) }
    }
}
