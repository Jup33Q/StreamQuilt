import AVFoundation
import Foundation

/// Mic-listening audio analyzer: tap buffers feed the shared AudioDSP chain
/// (FFT band energies + spectral-flux beat + autocorrelation pitch).
///
/// Note: Apple Music's PCM is DRM-protected — MusicKit cannot hand us audio.
/// Listening through the mic works with any source (incl. Apple Music playback);
/// pair with NowPlayingReader for track metadata/BPM. For a direct feed of the
/// playback output itself, see SystemAudioAnalyzer (ScreenCaptureKit).
public final class AudioAnalyzer {
    public struct Features {
        public var bass: Float = 0   // ~20-150 Hz
        public var mid: Float = 0    // ~150-2000 Hz
        public var treble: Float = 0 // ~2k-8k Hz
        public var beat: Float = 0   // decaying onset pulse 0..1
        public var pitchHz: Float = 0        // 0 = no confident pitch
        public var pitchTurns: Float = 0     // smoothed MIDI/12 -> hue turns; holds last
        public var pitchConfidence: Float = 0
    }

    public init() {}

    private let engine = AVAudioEngine()
    private let dsp = AudioDSP()

    public var current: Features {
        let o = dsp.current
        return Features(bass: o.bass, mid: o.mid, treble: o.treble, beat: o.beat,
                        pitchHz: o.pitchHz, pitchTurns: o.pitchTurns,
                        pitchConfidence: o.pitchConfidence)
    }

    public private(set) var isRunning = false

    public func start() {
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
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData else { return }
            self.dsp.feed(ch[0], count: Int(buffer.frameLength),
                          sampleRate: Float(fmt.sampleRate))
        }
        try engine.start()
        isRunning = true
        print("[audio] mic analyzer running (\(Int(fmt.sampleRate)) Hz)")
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
