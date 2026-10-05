import Accelerate
import Foundation
import QuartzCore

/// Shared analysis chain for the mic and system-audio paths: 2048-sample
/// Hann-windowed FFT band energies + spectral-flux beat pulse + autocorrelation
/// pitch detection. Feed arbitrary-length mono float32 chunks from any audio
/// callback; analysis runs once per 1024 new samples over the latest 2048
/// (~43 Hz at 48 kHz, 43 ms window — 80 Hz fundamentals stay detectable).
///
/// v5 normalization fix: band energy is the per-band PEAK magnitude
/// (vDSP_maxv), not the mean — real drum transients are ~2 analysis frames
/// wide and a band mean kept bass at 0.01-0.39; peak-per-band + instant-attack
/// output smoothing lets real kicks hit 1.0.
///
/// Pitch: partial autocorrelation over lags for 80–1200 Hz via pointer-offset
/// `vDSP_dotpr` (no per-lag allocation), zero-lag-energy normalized for the
/// confidence score, parabolic interpolation for sub-sample lag. Updates are
/// confidence-gated (> 0.35) and exponentially smoothed (α = 0.25) on the MIDI
/// number; below the gate the last value HELD — returning to 0 would read as
/// a hue jump (N-series flicker lesson).
public final class AudioDSP {
    public struct Output {
        public var bass: Float = 0   // ~20-150 Hz, adaptive-peak normalized
        public var mid: Float = 0    // ~150-2000 Hz
        public var treble: Float = 0 // ~2k-8k Hz
        public var beat: Float = 0   // decaying onset pulse 0..1
        public var pitchHz: Float = 0        // 0 = no confident pitch this frame
        public var pitchTurns: Float = 0     // smoothed MIDI/12 -> hue turns; holds last
        public var pitchConfidence: Float = 0
    }

    private let n = 2048
    private let hop = 1024
    private var ring: [Float]
    private var writePos = 0
    private var sinceAnalysis = 0
    private var window: [Float]
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var prevMagnitudes: [Float]
    private var corrs: [Float]          // reusable autocorrelation scratch
    private var fluxSmooth: Float = 0
    private var bandPeak: (Float, Float, Float) = (0.01, 0.01, 0.01)
    private var smoothedMidi: Float = 0
    private var hasPitch = false

    private let lock = NSLock()
    private var output = Output()

    public init() {
        ring = [Float](repeating: 0, count: n)
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP.FFT(log2n: vDSP_Length(log2(Float(n))), radix: .radix2,
                            ofType: DSPSplitComplex.self)
        prevMagnitudes = [Float](repeating: 0, count: n / 2)
        corrs = [Float](repeating: 0, count: n / 2 + 2)
    }

    /// Latest analysis, thread-safe against the audio callback.
    public var current: Output {
        lock.lock(); defer { lock.unlock() }
        return output
    }

    /// Feed mono float32 samples (called from realtime audio callbacks).
    public func feed(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        guard count > 0 else { return }
        if count >= n {
            // chunk larger than the window: only the tail matters
            ring.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, samples + (count - n), n * MemoryLayout<Float>.size)
            }
            writePos = 0
        } else {
            let first = min(count, n - writePos)
            ring.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress! + writePos, samples, first * MemoryLayout<Float>.size)
                if count > first {
                    memcpy(dst.baseAddress!, samples + first, (count - first) * MemoryLayout<Float>.size)
                }
            }
            writePos = (writePos + count) % n
        }
        sinceAnalysis += count
        guard sinceAnalysis >= hop else { return }
        sinceAnalysis = 0
        analyze(sampleRate: sampleRate)
    }

    private func analyze(sampleRate: Float) {
        guard let fft = fftSetup else { return }
        // linearize the ring: oldest sample first
        var samples = [Float](repeating: 0, count: n)
        ring.withUnsafeBufferPointer { r in
            samples.withUnsafeMutableBufferPointer { s in
                let first = n - writePos
                memcpy(s.baseAddress!, r.baseAddress! + writePos, first * MemoryLayout<Float>.size)
                memcpy(s.baseAddress! + first, r.baseAddress!, writePos * MemoryLayout<Float>.size)
            }
        }

        // ---- pitch: autocorrelation on the RAW (unwindowed) frame ----
        let minLag = max(1, Int(sampleRate / 1200))
        let maxLag = min(n / 2 - 2, Int(sampleRate / 80))
        var energy: Float = 0
        var bestLag = 0
        var bestCorr: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            vDSP_dotpr(base, 1, base, 1, &energy, vDSP_Length(n))
            if energy > 1e-6 {
                for lag in minLag...maxLag {
                    var c: Float = 0
                    vDSP_dotpr(base, 1, base + lag, 1, &c, vDSP_Length(n - lag))
                    corrs[lag] = c / energy
                    if corrs[lag] > bestCorr { bestCorr = corrs[lag]; bestLag = lag }
                }
            }
        }
        var pitchHz: Float = 0
        if bestLag > 0 {
            // parabolic interpolation around the peak for sub-sample lag
            var lagF = Float(bestLag)
            if bestLag > minLag, bestLag < maxLag {
                let y1 = corrs[bestLag - 1], y2 = corrs[bestLag], y3 = corrs[bestLag + 1]
                let denom = y1 - 2 * y2 + y3
                if abs(denom) > 1e-9 { lagF += 0.5 * (y1 - y3) / denom }
            }
            pitchHz = sampleRate / max(lagF, 1)
        }

        // ---- spectrum: Hann window + split-complex FFT ----
        samples.withUnsafeMutableBufferPointer { s in
            vDSP_vmul(s.baseAddress!, 1, window, 1, s.baseAddress!, 1, vDSP_Length(n))
        }
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
        // v5: per-band PEAK magnitude — transients (kick) survive; a band mean
        // smeared 2-frame drum hits into the adaptive-peak floor
        func band(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / hzPerBin)), b = min(n / 2 - 1, Int(hi / hzPerBin))
            guard b > a else { return 0 }
            var s: Float = 0
            mags.withUnsafeBufferPointer { ptr in
                vDSP_maxv(ptr.baseAddress! + a, 1, &s, vDSP_Length(b - a))
            }
            return s
        }
        var b = band(20, 150), m = band(150, 2000), tr = band(2000, 8000)

        // adaptive peak normalization (fast attack, slow decay)
        bandPeak.0 = max(b, bandPeak.0 * 0.995)
        bandPeak.1 = max(m, bandPeak.1 * 0.995)
        bandPeak.2 = max(tr, bandPeak.2 * 0.995)
        b = min(1, b / bandPeak.0); m = min(1, m / bandPeak.1); tr = min(1, tr / bandPeak.2)

        // spectral flux beat detection
        var flux: Float = 0
        mags.withUnsafeBufferPointer { mptr in
            prevMagnitudes.withUnsafeBufferPointer { pptr in
                for i in 1..<(n / 2) {
                    let d = mptr[i] - pptr[i]
                    if d > 0 { flux += d }
                }
            }
        }
        prevMagnitudes = mags
        flux /= Float(n / 2)
        fluxSmooth = fluxSmooth * 0.95 + flux * 0.05

        lock.lock()
        var o = output
        let onset = flux > fluxSmooth * 1.6 && flux > 0.001
        o.beat = onset ? 1.0 : o.beat * 0.88
        // instant attack + smoothed release: kicks must hit full amplitude the
        // frame they land, decay stays gentle so the scene doesn't strobe
        o.bass = b > o.bass ? b : o.bass * 0.6 + b * 0.4
        o.mid = m > o.mid ? m : o.mid * 0.6 + m * 0.4
        o.treble = tr > o.treble ? tr : o.treble * 0.6 + tr * 0.4
        o.pitchConfidence = bestLag > 0 ? bestCorr : 0
        if bestLag > 0, bestCorr > 0.35 {
            let midi = 69 + 12 * log2(pitchHz / 440)
            if !hasPitch { smoothedMidi = midi; hasPitch = true } else {
                smoothedMidi = smoothedMidi * 0.75 + midi * 0.25
            }
            o.pitchHz = pitchHz
            o.pitchTurns = smoothedMidi / 12
        } else {
            o.pitchHz = 0
            // pitchTurns holds its last value — no hue snap back to 0
        }
        output = o
        lock.unlock()
    }
}

/// v5 fast/slow split (docs/scene-v5-groove-plan.md): img2img is a lossy
/// channel — fast hue/brightness modulation does not survive diffusion, so
/// fast variables go to the display layer and SLOW variables (phrase energy,
/// 2-8 s) drive scene GEOMETRY. This envelope derives both scene inputs from
/// the same features that feed the audio uniform:
///   - slowEnergy: ~3 s EMA of weighted bass/mid — phrase-level energy
///   - kick: re-triggered on beat rising edges, slow attack / fast release
///     (camera push-ins must not snap, or they read as motion sickness)
/// Fed from the audioProvider closures (every scene encode, ~60-90 Hz);
/// unfed or silent input decays both outputs to exactly 0 (bitwise-neutral).
public final class GrooveEnvelope {
    public private(set) var slowEnergy: Float = 0
    public private(set) var kick: Float = 0
    private var lastT: CFTimeInterval?
    private var prevBeat: Float = 0
    private var kickT: CFTimeInterval = -10

    public init() {}

    @discardableResult
    public func push(bass: Float, mid: Float, beat: Float,
                     at t: CFTimeInterval = CACurrentMediaTime()) -> (slow: Float, kick: Float) {
        defer { lastT = t; prevBeat = beat }
        guard let lt = lastT else { return (0, 0) }   // first sample: no history yet
        let dt = max(0, Float(t - lt))
        let e = min(1, max(0, bass * 0.75 + mid * 0.5))
        slowEnergy += (e - slowEnergy) * (1 - exp(-dt / 3))
        if beat > 0.55, prevBeat <= 0.55 { kickT = t }
        let kdt = max(0, Float(t - kickT))
        kick = (1 - exp(-kdt / 0.14)) * exp(-max(0, kdt - 0.14) / 0.20)
        return (slowEnergy, kick)
    }
}
