import Foundation

/// Emotion table for the local "emotion engine": each emotion carries an SD
/// style-prompt fragment, a scene hue re-anchor (hueBias) and per-element
/// strength gains for the raymarched scene (crystal / columns / embers).
public struct Emotion {
    public let id: String
    public let zh: String
    public let stylePrompt: String
    /// Hue re-anchor applied on top of the audio-driven hueShift (-0.5...0.5).
    public let hueBias: Float
    /// Base energy 0...1 (scales beatGlow; short-term chorus boost adds on top).
    public let energy: Float
    /// Element gains 0.3...2.0 (shader theme uniform y/z/w).
    public let crystalGain: Float
    public let columnGain: Float
    public let emberGain: Float

    public init(id: String, zh: String, stylePrompt: String, hueBias: Float,
                energy: Float, crystalGain: Float, columnGain: Float, emberGain: Float) {
        self.id = id
        self.zh = zh
        self.stylePrompt = stylePrompt
        self.hueBias = hueBias
        self.energy = energy
        self.crystalGain = crystalGain
        self.columnGain = columnGain
        self.emberGain = emberGain
    }

    public static let all: [Emotion] = [
        Emotion(id: "euphoric", zh: "狂喜",
                stylePrompt: "euphoric ecstatic mood, blazing gold and hot magenta palette, radiant festival glow",
                hueBias: 0.12, energy: 0.95, crystalGain: 1.4, columnGain: 1.5, emberGain: 1.8),
        Emotion(id: "joyful", zh: "欢快",
                stylePrompt: "joyful upbeat mood, sunny yellow and sky blue palette, playful bright atmosphere",
                hueBias: 0.08, energy: 0.85, crystalGain: 1.1, columnGain: 1.4, emberGain: 1.5),
        Emotion(id: "hopeful", zh: "希望",
                stylePrompt: "hopeful uplifting mood, soft dawn gold and teal palette, morning light breaking through",
                hueBias: 0.06, energy: 0.7, crystalGain: 1.0, columnGain: 1.2, emberGain: 1.1),
        Emotion(id: "serene", zh: "宁静",
                stylePrompt: "serene tranquil mood, muted jade and pale lavender palette, calm drifting mist",
                hueBias: -0.05, energy: 0.3, crystalGain: 0.8, columnGain: 0.7, emberGain: 0.5),
        Emotion(id: "dreamy", zh: "梦幻",
                stylePrompt: "dreamy ethereal mood, pastel pink and iridescent violet palette, floating soft haze",
                hueBias: 0.0, energy: 0.5, crystalGain: 1.3, columnGain: 0.8, emberGain: 1.0),
        Emotion(id: "nostalgic", zh: "怀旧",
                stylePrompt: "nostalgic faded-memory mood, warm sepia amber film palette, golden hour glow",
                hueBias: 0.10, energy: 0.45, crystalGain: 0.9, columnGain: 0.9, emberGain: 1.0),
        Emotion(id: "melancholic", zh: "忧郁",
                stylePrompt: "somber melancholic mood, muted blue-grey palette, soft rain atmosphere",
                hueBias: -0.15, energy: 0.3, crystalGain: 0.7, columnGain: 0.8, emberGain: 0.6),
        Emotion(id: "lonely", zh: "孤独",
                stylePrompt: "lonely desolate mood, cold steel blue palette, empty night city atmosphere",
                hueBias: -0.12, energy: 0.25, crystalGain: 0.8, columnGain: 0.6, emberGain: 0.4),
        Emotion(id: "tense", zh: "紧张",
                stylePrompt: "tense unsettling mood, harsh crimson and acid green palette, strobe flicker unease",
                hueBias: -0.02, energy: 0.8, crystalGain: 1.2, columnGain: 1.6, emberGain: 1.3),
        Emotion(id: "dark", zh: "阴暗",
                stylePrompt: "dark ominous mood, deep black and blood red palette, heavy smoke atmosphere",
                hueBias: -0.05, energy: 0.4, crystalGain: 1.1, columnGain: 1.2, emberGain: 0.4),
        Emotion(id: "romantic", zh: "浪漫",
                stylePrompt: "romantic warm mood, rose pink and candlelit amber palette, soft intimate glow",
                hueBias: 0.09, energy: 0.55, crystalGain: 1.2, columnGain: 0.9, emberGain: 1.2),
        Emotion(id: "mystical", zh: "神秘",
                stylePrompt: "mystical arcane mood, deep violet and ghostly cyan palette, fog with glowing runes",
                hueBias: -0.08, energy: 0.6, crystalGain: 1.5, columnGain: 1.1, emberGain: 1.1),
        Emotion(id: "rebellious", zh: "躁动",
                stylePrompt: "rebellious aggressive mood, acid green and violent magenta palette, glitch chaos energy",
                hueBias: 0.05, energy: 0.9, crystalGain: 1.3, columnGain: 1.8, emberGain: 1.7),
        Emotion(id: "epic", zh: "史诗",
                stylePrompt: "epic heroic mood, imperial gold and deep crimson palette, cinematic monumental scale",
                hueBias: 0.04, energy: 0.85, crystalGain: 1.2, columnGain: 1.8, emberGain: 1.4),
    ]

    public static func byID(_ id: String) -> Emotion? { all.first { $0.id == id } }
}

/// Track theme engine: classifies the current song (title/artist + first lyric
/// lines) via a local Ollama model into one of the 14 emotions, merges the
/// LLM result with the static emotion table, and exposes the merged style
/// prompt + scene theme gains. Rule-based (no LLM): lyric pace and chorus
/// detection feed a short-term energy boost for beatGlow scaling.
///
/// Threading: all state lives on the main run loop (0.5s timer); the Ollama
/// round trip runs on a background queue and hops back to main before
/// touching state. Never blocks the render hot path; a track-name hash
/// fallback guarantees a theme even when Ollama is down.
public final class TrackThemeEngine {
    public struct ThemeOutput {
        public let emotionID: String
        public let emotionZH: String
        public let themeEN: String
        /// Merged style-prompt middle section (table fragment + LLM style + theme).
        public let prompt: String
        public let hueBias: Float
        public let energy: Float
        public let crystalGain: Float
        public let columnGain: Float
        public let emberGain: Float
    }

    /// Ollama endpoint; nil disables LLM queries (hash fallback still works).
    public var ollama: OllamaClient?

    /// Combined prompt middle section ("" until the first theme is produced).
    public private(set) var currentTheme = ""
    public private(set) var currentHueBias: Float = 0
    public private(set) var currentEnergy: Float = 0
    /// (crystal, column, ember) gains for the shader theme uniform.
    public private(set) var currentGains = SIMD3<Float>(1, 1, 1)
    public private(set) var currentEmotionID = ""
    public private(set) var currentThemeEN = ""
    /// Fires on the main thread whenever a new theme is produced.
    public var onTheme: ((ThemeOutput) -> Void)?

    // lyric pace / chorus (rule-based)
    /// Line switches per minute over the trailing 30s window, clamped 0..1.
    public private(set) var lyricPace: Float = 0
    /// Short-term chorus boost (decays to 0); added to energy for beatGlow.
    public private(set) var chorusBoost: Float = 0
    /// Energy including the short-term chorus boost (clamped 0..1).
    public var effectiveEnergy: Float { min(currentEnergy + chorusBoost, 1) }

    private var timer: Timer?
    private var lastTrackID = ""
    private var currentMusicID = ""   // latest id seen in tick (stale-result check)
    private var pendingTrackID: String?
    private var pendingSince = Date.distantPast
    private var inFlightTrackID: String?
    private var lineSwitches: [Date] = []
    private var lastObservedLine = ""

    public init(ollama: OllamaClient? = nil) { self.ollama = ollama }

    /// Poll MusicBridge/LyricsService state on a 0.5s main-runloop timer.
    public func attach(music: MusicBridge, lyrics: LyricsService) {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self, weak music, weak lyrics] _ in
            guard let self, let music, let lyrics else { return }
            self.tick(music: music, lyrics: lyrics)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate() }

    // MARK: - Tick (main thread)

    private func tick(music: MusicBridge, lyrics: LyricsService) {
        updateLyricStats(lyrics: lyrics)

        let id = music.trackName + " — " + music.artist
        if !music.playing || music.trackName.isEmpty {
            currentMusicID = ""
            if !lastTrackID.isEmpty {
                lastTrackID = ""; pendingTrackID = nil
                currentTheme = ""; currentEmotionID = ""; currentThemeEN = ""
                currentHueBias = 0; currentEnergy = 0; currentGains = SIMD3(1, 1, 1)
            }
            return
        }
        currentMusicID = id
        guard id != lastTrackID, id != inFlightTrackID else { return }
        if pendingTrackID != id {
            pendingTrackID = id
            pendingSince = Date()
            return
        }        // Wait up to ~5s for the first lyric lines to land, then classify
        // with whatever we have (metadata alone is fine).
        let lines = lyrics.trackID == id ? lyrics.lines.prefix(8).map { $0.text } : []
        guard !lines.isEmpty || Date().timeIntervalSince(pendingSince) >= 5 else { return }
        pendingTrackID = nil
        inFlightTrackID = id
        classify(track: id, name: music.trackName, artist: music.artist,
                 lines: Array(lines))
    }

    // MARK: - Classification

    private func classify(track id: String, name: String, artist: String, lines: [String]) {
        guard let ollama else {
            applyFallback(track: id, name: name)
            return
        }
        let lyricBlock = lines.isEmpty ? "(no lyrics available yet)" : lines.joined(separator: " / ")
        let user = """
            Track: "\(name)" by \(artist).
            First lyrics: \(lyricBlock)
            """
        print("[emotion] classifying \(id)...")
        ollama.chat(system: Self.systemPrompt, user: user) { [weak self] json in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightTrackID = nil
                // drop stale results: track changed / playback stopped in flight
                guard self.currentMusicID == id else { return }
                guard let json, let out = Self.parse(json: json, fallbackName: name) else {
                    print("[emotion] ollama failed/timeout for \(id) — hash fallback")
                    self.applyFallback(track: id, name: name)
                    return
                }
                self.lastTrackID = id
                self.apply(out)
            }
        }
    }

    /// Strict-JSON system prompt; the model must pick one of the 14 ids.
    static let systemPrompt = """
        You classify the emotional mood and theme of a song for a real-time music visualizer. \
        Reply with ONLY a JSON object, no markdown, no prose:
        {"emotion":"<exactly one of: euphoric, joyful, hopeful, serene, dreamy, nostalgic, melancholic, lonely, tense, dark, romantic, mystical, rebellious, epic>","theme_en":"<3-8 word English theme phrase>","style_en":"<one English style prompt sentence describing palette and atmosphere>","hue_bias":<float from -0.3 to 0.3, negative=cool palette, positive=warm palette>,"energy":<float from 0 to 1>}
        """

    static func parse(json: [String: Any], fallbackName: String) -> ThemeOutput? {
        guard let rawID = json["emotion"] as? String else { return nil }
        let emo = Emotion.byID(rawID.lowercased().trimmingCharacters(in: .whitespaces))
            ?? Emotion.all[stableIndex(fallbackName)]
        let themeEN = (json["theme_en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleEN = (json["style_en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let llmHue = (json["hue_bias"] as? Double).map { Float($0) }
            ?? (json["hue_bias"] as? NSNumber)?.floatValue ?? 0
        let llmEnergy = (json["energy"] as? Double).map { Float($0) }
            ?? (json["energy"] as? NSNumber)?.floatValue ?? emo.energy
        // merge: table anchors, LLM nudges (clamped)
        let hue = min(max((emo.hueBias + min(max(llmHue, -0.3), 0.3)) / 2, -0.5), 0.5)
        let energy = min(max((emo.energy + min(max(llmEnergy, 0), 1)) / 2, 0), 1)
        let theme = (themeEN?.isEmpty == false) ? themeEN! : fallbackName
        var prompt = emo.stylePrompt
        if let styleEN, !styleEN.isEmpty { prompt += ", " + styleEN }
        prompt += ", " + theme
        return ThemeOutput(emotionID: emo.id, emotionZH: emo.zh, themeEN: theme,
                           prompt: prompt, hueBias: hue, energy: energy,
                           crystalGain: emo.crystalGain, columnGain: emo.columnGain,
                           emberGain: emo.emberGain)
    }

    /// Ollama down/timeout: deterministic emotion picked by track-name hash.
    private func applyFallback(track id: String, name: String) {
        let emo = Emotion.all[Self.stableIndex(id)]
        let out = ThemeOutput(emotionID: emo.id, emotionZH: emo.zh, themeEN: name,
                              prompt: emo.stylePrompt + ", " + name,
                              hueBias: emo.hueBias, energy: emo.energy,
                              crystalGain: emo.crystalGain, columnGain: emo.columnGain,
                              emberGain: emo.emberGain)
        lastTrackID = id
        apply(out)
    }

    private func apply(_ t: ThemeOutput) {
        currentTheme = t.prompt
        currentHueBias = t.hueBias
        currentEnergy = t.energy
        currentGains = SIMD3(t.crystalGain, t.columnGain, t.emberGain)
        currentEmotionID = t.emotionID
        currentThemeEN = t.themeEN
        print("[emotion] \(t.emotionID) \(t.emotionZH) | “\(t.themeEN)” | hue \(String(format: "%+.2f", t.hueBias)) energy \(String(format: "%.2f", t.energy))")
        onTheme?(t)
    }

    /// djb2 over the track id — stable across launches.
    static func stableIndex(_ s: String) -> Int {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % UInt64(Emotion.all.count))
    }

    // MARK: - Lyric pace / chorus (rule-based)

    private func updateLyricStats(lyrics: LyricsService) {
        let now = Date()
        lineSwitches.removeAll { now.timeIntervalSince($0) > 30 }
        let line = lyrics.currentLine
        if line != lastObservedLine {
            let prev = lastObservedLine
            lastObservedLine = line
            if !line.isEmpty {
                lineSwitches.append(now)
                // chorus heuristic: consecutive identical / highly similar lines
                if !prev.isEmpty, Self.similar(prev, line) {
                    chorusBoost = 0.3
                }
            }
        }
        chorusBoost = max(0, chorusBoost - 0.015)   // ~10s decay at 2 Hz ticks
        lyricPace = min(Float(lineSwitches.count) / 15.0, 1) // 15 switches/30s = a line every 2s
    }

    /// Equal strings or token-set Jaccard >= 0.6.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ta = Set(a.lowercased().split { !$0.isLetter && !$0.isNumber })
        let tb = Set(b.lowercased().split { !$0.isLetter && !$0.isNumber })
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union > 0 && Double(inter) / Double(union) >= 0.6
    }
}
