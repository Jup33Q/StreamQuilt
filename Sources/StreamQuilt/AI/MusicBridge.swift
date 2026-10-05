import Foundation

/// Apple Music linkage via Music.app AppleScript.
///
/// Apple Music PCM is DRM-protected — MusicKit cannot hand us audio buffers.
/// What we CAN do without touching audio:
///   - Now Playing metadata (track/artist/album/BPM field when present)
///   - player state + position (extrapolated between polls)
///   - playback control (play/pause/next/previous)
/// From BPM + position we synthesize a beat clock that drives shader uniforms.
public final class MusicBridge {
    public private(set) var line = ""        // "name — artist"
    public private(set) var trackName = ""
    public private(set) var artist = ""
    public private(set) var bpm = 0
    public private(set) var playing = false
    public private(set) var duration: Double = 0

    public init() {}
    private var positionAtPoll: Double = 0
    private var lastPollAt = Date.distantPast
    private var timer: Timer?

    /// Player position in seconds, extrapolated between AppleScript polls.
    public var position: Double {
        guard playing else { return positionAtPoll }
        return positionAtPoll + Date().timeIntervalSince(lastPollAt)
    }

    /// Continuous beat clock for epoch quantization (N4): (phase in beats,
    /// seconds per beat). nil when not playing.
    public var beatClock: (phase: Double, beatLen: Double)? {
        guard playing else { return nil }
        let b = Double(bpm > 0 ? bpm : 100)
        let len = 60.0 / b
        return (position / len, len)
    }

    /// Synthetic beat-synchronized features: (bass, mid, treble, beat).
    /// When BPM is unknown, falls back to a 100 BPM metronome while playing.
    /// v2 groove engine: distinct musical roles per band instead of three
    /// near-identical decaying pulses — an 8th-note walking kick (bass), a
    /// backbeat snare on beats 2/4 (mid), 16th-note hi-hat with alternating
    /// velocity that actually crosses zero (treble), all under an 8-beat
    /// phrase envelope so the whole scene breathes in builds and releases.
    public var features: SIMD4<Float> {
        guard playing else { return .zero }
        let b = Double(bpm > 0 ? bpm : 100)
        let beatLen = 60.0 / b
        let phase = position / beatLen
        let frac = Float(phase - phase.rounded(.down))       // 0..1 inside beat
        // kick: downbeat thump + softer 8th-note ghost -> low end walks
        let kick = exp(-6.0 * frac)
        let halfFrac = Float((phase * 2).truncatingRemainder(dividingBy: 1))
        let bass = min(kick + 0.45 * exp(-7.0 * halfFrac), 1)
        // snare/clap: backbeat on beats 2 & 4, light tap elsewhere
        let beatInBar = Int(phase.rounded(.down)) % 4
        let snareGate: Float = (beatInBar == 1 || beatInBar == 3) ? 1 : 0.25
        let mid = snareGate * exp(-7.0 * frac)
        // hi-hat: 16ths, alternating velocity, true zeros between hits
        let frac16 = Float((phase * 4).truncatingRemainder(dividingBy: 1))
        let step16 = Int((phase * 4).rounded(.down)) % 4
        let treble = (step16 % 2 == 0 ? 0.85 : 0.5) * exp(-9.0 * frac16)
        // 8-beat phrase envelope: slow build/release so motion never flatlines
        let phrase = Float(0.8 + 0.2 * sin(phase * .pi / 4))
        let beat = Float(exp(-6.0 * Double(frac)))
        return SIMD4(bass * phrase, mid * phrase, treble, beat)
    }

    public func start(pollInterval: TimeInterval = 2) {
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    public func stop() { timer?.invalidate() }

    // MARK: controls

    public func togglePlayPause() { run(script: #"tell application "Music" to playpause"#) }
    public func nextTrack() { run(script: #"tell application "Music" to next track"#); pollSoon() }
    public func previousTrack() { run(script: #"tell application "Music" to previous track"#); pollSoon() }

    private func pollSoon() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
    }

    // MARK: AppleScript plumbing

    private func poll() {
        DispatchQueue.global().async { [weak self] in
            guard let out = Self.run(script: """
                tell application "System Events" to if not (exists process "Music") then return ""
                tell application "Music"
                    if player state is playing or player state is paused then
                        set t to current track
                        return (player state as string) & "|" & player position & "|" & (time of t) & "|" & (name of t) & "|" & (artist of t) & "|" & (bpm of t)
                    end if
                end tell
                """) else { return }
            let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                if s.isEmpty {
                    self.playing = false; self.line = ""; self.bpm = 0
                    self.trackName = ""; self.artist = ""
                    return
                }
                let p = s.split(separator: "|").map(String.init)
                guard p.count >= 6 else { return }
                self.playing = p[0] == "playing"
                self.positionAtPoll = Double(p[1]) ?? 0
                self.lastPollAt = Date()
                self.duration = Self.parseMMSS(p[2])
                self.trackName = p[3]
                self.artist = p[4]
                self.line = p[3] + " — " + p[4]
                self.bpm = Int(p[5]) ?? 0
            }
        }
    }

    private static func parseMMSS(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        return Double(s) ?? 0
    }

    @discardableResult
    private static func run(script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard let _ = try? p.run() else { return nil }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func run(script: String) {
        DispatchQueue.global().async { Self.run(script: script) }
    }
}
