import AVFoundation
import Accelerate
import Foundation

/// Mic-listening audio analyzer: FFT band energies + spectral-flux beat pulse.
/// Drives shader uniforms each audio callback (~43 Hz at 1024-sample buffers).
///
/// Note: Apple Music's PCM is DRM-protected — MusicKit cannot hand us audio.
/// Listening through the mic works with any source (incl. Apple Music playback);
/// pair with NowPlayingReader for track metadata/BPM.
final class AudioAnalyzer {
    struct Features {
        var bass: Float = 0   // ~20-150 Hz
        var mid: Float = 0    // ~150-2000 Hz
        var treble: Float = 0 // ~2k-8k Hz
        var beat: Float = 0   // decaying onset pulse 0..1
    }

    private let engine = AVAudioEngine()
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private let n = 1024
    private var window: [Float] = []
    private var prevMagnitudes: [Float] = []
    private var fluxSmooth: Float = 0
    private var bandPeak: (Float, Float, Float) = (0.01, 0.01, 0.01)

    private let lock = NSLock()
    private var features = Features()

    var current: Features {
        lock.lock(); defer { lock.unlock() }
        return features
    }

    var isRunning = false

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                print("[audio] mic access denied — audio-reactive disabled")
                return
            }
            do {
                try self.startEngine()
            } catch {
                print("[audio] engine failed: \(error)")
            }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP.FFT(log2n: vDSP_Length(log2(Float(n))), radix: .radix2, ofType: DSPSplitComplex.self)
        prevMagnitudes = [Float](repeating: 0, count: n / 2)

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(n), format: fmt) { [weak self] buffer, _ in
            self?.process(buffer: buffer, sampleRate: Float(fmt.sampleRate))
        }
        try engine.start()
        isRunning = true
        print("[audio] mic analyzer running (\(Int(fmt.sampleRate)) Hz)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func process(buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let fft = fftSetup, let ch = buffer.floatChannelData else { return }
        let count = min(Int(buffer.frameLength), n)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<count { samples[i] = ch[0][i] * window[i] }

        // real FFT via split complex
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        samples.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                var split = DSPSplitComplex(realp: &real, imagp: &imag)
                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                fft.forward(input: split, output: &split)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        let hzPerBin = sampleRate / Float(n)
        func band(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / hzPerBin)), b = min(n / 2 - 1, Int(hi / hzPerBin))
            guard b > a else { return 0 }
            var s: Float = 0
            vDSP_sve(Array(mags[a...b]), 1, &s, vDSP_Length(b - a))
            return s / Float(b - a)
        }
        var b = band(20, 150), m = band(150, 2000), tr = band(2000, 8000)

        // adaptive peak normalization (fast attack, slow decay)
        bandPeak.0 = max(b, bandPeak.0 * 0.995)
        bandPeak.1 = max(m, bandPeak.1 * 0.995)
        bandPeak.2 = max(tr, bandPeak.2 * 0.995)
        b = min(1, b / bandPeak.0); m = min(1, m / bandPeak.1); tr = min(1, tr / bandPeak.2)

        // spectral flux beat detection
        var flux: Float = 0
        for i in 1..<(n / 2) {
            let d = mags[i] - prevMagnitudes[i]
            if d > 0 { flux += d }
        }
        prevMagnitudes = mags
        flux /= Float(n / 2)
        fluxSmooth = fluxSmooth * 0.95 + flux * 0.05
        lock.lock()
        var f = features
        let onset = flux > fluxSmooth * 1.6 && flux > 0.001
        f.beat = onset ? 1.0 : f.beat * 0.88
        f.bass = f.bass * 0.6 + b * 0.4
        f.mid = f.mid * 0.6 + m * 0.4
        f.treble = f.treble * 0.6 + tr * 0.4
        features = f
        lock.unlock()
    }
}
