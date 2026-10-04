import Foundation

/// Time-synced lyrics for the Music.app current track, for lyric-driven
/// prompt modulation (L1/L3 in docs/lyrics-and-peek-plan.md).
///
/// Fetch order: Music.app `lyrics of current track` (AppleScript, plain text)
/// → LRCLIB (https://lrclib.net/api/get, syncedLyrics LRC or plainLyrics).
/// Sync uses MusicBridge.position (2s poll + extrapolation); plain lyrics are
/// spread evenly across the track duration.
final class LyricsService {
    struct Line {
        let t: Double
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var trackID = ""
    /// Current lyric line at the last-checked position ("" when none).
    private(set) var currentLine = ""
    private var timer: Timer?
    private var fetching = false
    /// Prompt-modulation throttle (plan L3: >= 2s between lyric-driven switches).
    private var lastSwitchAt = Date.distantPast

    /// Start tracking MusicBridge state. `onLine` fires (main thread) whenever
    /// the current line changes to a non-empty string.
    func attach(music: MusicBridge, onLine: @escaping (String) -> Void) {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak music] _ in
            guard let self, let music else { return }
            self.tick(music: music, onLine: onLine)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate() }

    private func tick(music: MusicBridge, onLine: (String) -> Void) {
        let id = music.trackName + " — " + music.artist
        if !music.playing || music.trackName.isEmpty {
            if !trackID.isEmpty { trackID = ""; lines = []; currentLine = "" }
            return
        }
        if id != trackID, !fetching {
            fetching = true
            let name = music.trackName, artist = music.artist, dur = music.duration
            DispatchQueue.global().async { [weak self] in
                let fetched = Self.fetchTrack(name: name, artist: artist, duration: dur)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fetching = false
                    // still the same track?
                    guard music.trackName + " — " + music.artist == id else { return }
                    self.trackID = id
                    self.lines = fetched
                    self.currentLine = ""
                    print("[lyrics] \(id): \(fetched.isEmpty ? "no lyrics" : "\(fetched.count) lines")")
                }
            }
            return
        }
        let line = lineAt(music.position)
        if line != currentLine {
            currentLine = line
            // throttle >=2s, skip blank lines (plan L3)
            if !line.isEmpty, Date().timeIntervalSince(lastSwitchAt) >= 2 {
                lastSwitchAt = Date()
                onLine(line)
            }
        }
    }

    /// Last line whose timestamp <= position + 0.2s lookahead.
    func lineAt(_ position: Double) -> String {
        var result = ""
        for l in lines {
            if l.t <= position + 0.2 { result = l.text } else { break }
        }
        return result
    }

    // MARK: - Fetching

    private static func fetchTrack(name: String, artist: String, duration: Double) -> [Line] {
        // 1. Music.app local lyrics field (plain text, no timestamps)
        if let raw = run(script: """
            tell application "System Events" to if not (exists process "Music") then return ""
            tell application "Music" to if player state is playing or player state is paused then return lyrics of current track
            """) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let lrc = parseLRC(text)
                if !lrc.isEmpty { return lrc }
                return spreadPlain(text, duration: duration)
            }
        }
        // 2. LRCLIB fallback (direct connection verified on this machine)
        var comp = URLComponents(string: "https://lrclib.net/api/get")!
        comp.queryItems = [
            URLQueryItem(name: "track_name", value: name),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        guard let url = comp.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("lkg-metal-quilt lyric-prompt", forHTTPHeaderField: "User-Agent")
        // blocking call — always invoked on a background queue from tick()
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data
            sem.signal()
        }.resume()
        guard sem.wait(timeout: .now() + 12) == .success, let data = result else { return [] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if obj["instrumental"] as? Bool == true { return [] }
        if let synced = obj["syncedLyrics"] as? String {
            let lrc = parseLRC(synced)
            if !lrc.isEmpty { return lrc }
        }
        if let plain = obj["plainLyrics"] as? String {
            return spreadPlain(plain, duration: duration)
        }
        return []
    }

    /// Parse LRC: `[mm:ss.xx]text`, possibly several timestamps per line;
    /// `[ar:...]` metadata tags ignored.
    static func parseLRC(_ text: String) -> [Line] {
        var out: [Line] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var s = rawLine
            var stamps: [Double] = []
            while s.hasPrefix("["), let close = s.firstIndex(of: "]") {
                let tag = String(s[s.index(after: s.startIndex)..<close])
                if let t = parseStamp(tag) {
                    stamps.append(t)
                    s = String(s[s.index(after: close)...])
                } else { break }
            }
            let body = s.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            for t in stamps { out.append(Line(t: t, text: body)) }
        }
        return out.sorted { $0.t < $1.t }
    }

    private static func parseStamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    }

    /// Plain lyrics: non-empty lines spread evenly over the track duration.
    private static func spreadPlain(_ text: String, duration: Double) -> [Line] {
        let rows = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rows.isEmpty, duration > 0 else { return [] }
        let step = duration / Double(rows.count)
        return rows.enumerated().map { Line(t: Double($0.offset) * step, text: $0.element) }
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
}
