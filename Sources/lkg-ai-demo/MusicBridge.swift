import Foundation

/// Apple Music linkage via Music.app AppleScript.
///
/// Apple Music PCM is DRM-protected — MusicKit cannot hand us audio buffers.
/// What we CAN do without touching audio:
///   - Now Playing metadata (track/artist/album/BPM field when present)
///   - player state + position (extrapolated between polls)
///   - playback control (play/pause/next/previous)
/// From BPM + position we synthesize a beat clock that drives shader uniforms.
final class MusicBridge {
    private(set) var line = ""        // "name — artist"
    private(set) var trackName = ""
    private(set) var artist = ""
    private(set) var bpm = 0
    private(set) var playing = false
    private(set) var duration: Double = 0
    private var positionAtPoll: Double = 0
    private var lastPollAt = Date.distantPast
    private var timer: Timer?

    /// Player position in seconds, extrapolated between AppleScript polls.
    var position: Double {
        guard playing else { return positionAtPoll }
        return positionAtPoll + Date().timeIntervalSince(lastPollAt)
    }

    /// Continuous beat clock for epoch quantization (N4): (phase in beats,
    /// seconds per beat). nil when not playing.
    var beatClock: (phase: Double, beatLen: Double)? {
        guard playing else { return nil }
        let b = Double(bpm > 0 ? bpm : 100)
        let len = 60.0 / b
        return (position / len, len)
    }

    /// Synthetic beat-synchronized features: (bass, mid, treble, beat).
    /// When BPM is unknown, falls back to a 100 BPM metronome while playing.
    var features: SIMD4<Float> {
        guard playing else { return .zero }
        let b = Double(bpm > 0 ? bpm : 100)
        let beatLen = 60.0 / b
        let phase = position / beatLen
        let frac = phase - phase.rounded(.down)          // 0..1 inside beat
        let beatPulse = Float(exp(-6.0 * frac))           // decaying onset pulse
        let offPhase = (phase + 0.5).truncatingRemainder(dividingBy: 1)
        let offPulse = Float(exp(-8.0 * offPhase))        // offbeat (mid)
        let shimmer = Float(0.5 + 0.5 * sin(phase * .pi * 4)) // 2x per beat (treble)
        return SIMD4(beatPulse, offPulse, shimmer, beatPulse)
    }

    func start(pollInterval: TimeInterval = 2) {
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() { timer?.invalidate() }

    // MARK: controls

    func togglePlayPause() { run(script: #"tell application "Music" to playpause"#) }
    func nextTrack() { run(script: #"tell application "Music" to next track"#); pollSoon() }
    func previousTrack() { run(script: #"tell application "Music" to previous track"#); pollSoon() }

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
