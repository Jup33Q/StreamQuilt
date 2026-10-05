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

/// Track theme engine: classifies the current song into one of the 14
/// emotions and ranks the 12-theme visual library, then keeps re-ranking
/// the active pool per lyric line. Two brains:
///
/// - **laya** (default): track-level theme+emotion choice with probabilities
///   (1024-token lane); the top-5 themes by probability become the active
///   pool. Every lyric-line switch fires a line-level choice (ANE lane) over
///   the pool + emotions, EMA-blends the pool weights, and re-composes the
///   prompt by weighted-random sampling the pool. Per-line emotion switches
///   use hysteresis (+0.15) to avoid jitter.
/// - **ollama**: legacy free-text route (theme sentence from an LLM).
///
/// Prompt contract: sampled theme fragment + emotion style + lyric line +
/// `Theme.qualityTail` — control tokens are never sampled.
///
/// Threading: all state lives on the main run loop (0.5s timer); laya/ollama
/// round trips run off-main and hop back before touching state. Never blocks
/// the render hot path; a track-name hash fallback guarantees a theme even
/// when both brains are down.
public final class TrackThemeEngine {
    public enum Brain: String { case laya, ollama }

    public struct ThemeOutput {
        public let emotionID: String
        public let emotionZH: String
        public let themeID: String
        public let themeZH: String
        public let themeEN: String
        /// Merged style-prompt middle section (theme fragment + emotion style).
        public let prompt: String
        public let hueBias: Float
        public let energy: Float
        public let crystalGain: Float
        public let columnGain: Float
        public let emberGain: Float
    }

    public var brain: Brain = .laya
    /// Ollama endpoint (used when brain == .ollama, or as nothing — laya
    /// falls back to the deterministic hash path, not to Ollama).
    public var ollama: OllamaClient?
    /// laya sidecar client; nil disables laya queries (hash fallback works).
    public var laya: LayaClient?

    /// Combined prompt middle section ("" until the first theme is produced).
    public private(set) var currentTheme = ""
    public private(set) var currentHueBias: Float = 0
    public private(set) var currentEnergy: Float = 0
    /// (crystal, column, ember) gains for the shader theme uniform.
    public private(set) var currentGains = SIMD3<Float>(1, 1, 1)
    public private(set) var currentEmotionID = ""
    public private(set) var currentThemeID = ""
    public private(set) var currentThemeZH = ""
    public private(set) var currentThemeEN = ""
    /// Per-line emotion (hysteresis-switched); falls back to track emotion.
    public private(set) var lineEmotionID = ""
    /// laya-picked lyric-overlay font set id (per track; hash pick as fallback).
    public private(set) var currentFontSetID = ""
    /// Fires on the main thread whenever a new track theme is produced.
    public var onTheme: ((ThemeOutput) -> Void)?
    /// Fires on the main thread when a font set is picked for the current
    /// track (laya arbitration or deterministic hash fallback).
    public var onFontSet: ((String) -> Void)?
    /// Fires on the main thread (beat-snapped) whenever a fresh prompt should
    /// be pushed to the diffusion workers (track theme applied, or lyric-line
    /// switch with updated pool weights).
    public var onPrompt: ((String) -> Void)?

    /// Active sampling pool: top-5 themes by weight (EMA-blended per line).
    public private(set) var pool: [(theme: Theme, weight: Float)] = []

    // lyric pace / chorus (rule-based)
    /// Line switches per minute over the trailing 30s window, clamped 0..1.
    public private(set) var lyricPace: Float = 0
    /// Short-term chorus boost (decays to 0); added to energy for beatGlow.
    public private(set) var chorusBoost: Float = 0
    /// Energy including the short-term chorus boost (clamped 0..1).
    public var effectiveEnergy: Float { min(currentEnergy + chorusBoost, 1) }

    private var timer: Timer?
    private weak var music: MusicBridge?
    private var lastTrackID = ""
    private var currentMusicID = ""   // latest id seen in tick (stale-result check)
    private var pendingTrackID: String?
    private var pendingSince = Date.distantPast
    private var inFlightTrackID: String?
    private var lineSwitches: [Date] = []
    private var lastObservedLine = ""
    private var trackEmotion: Emotion?
    private var lineEmotion: Emotion?
    private var lineEmotionProb: Float = 0
    private var inFlightLine = false
    private var lastPromptAt = Date.distantPast
    /// Current track's pool came from the deterministic hash (brains were not
    /// ready) — re-classify as soon as laya reports ready.
    private var usedHashFallback = false

    /// laya sidecar finished loading (wire to LayaClient.onReady). If the
    /// current track was hash-fallback, drop it so the next tick reclassifies
    /// with real probabilities (top-5 pool instead of a single theme).
    public func layaReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.usedHashFallback, !self.currentMusicID.isEmpty else { return }
            print("[emotion] laya ready — reclassifying current track")
            self.usedHashFallback = false
            self.lastTrackID = ""
            self.pendingTrackID = nil
            self.inFlightTrackID = nil
        }
    }

    public init(ollama: OllamaClient? = nil) { self.ollama = ollama }

    /// Poll MusicBridge/LyricsService state on a 0.5s main-runloop timer.
    public func attach(music: MusicBridge, lyrics: LyricsService) {
        self.music = music
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
        updateLyricStats(music: music, lyrics: lyrics)

        let id = music.trackName + " — " + music.artist
        if !music.playing || music.trackName.isEmpty {
            currentMusicID = ""
            if !lastTrackID.isEmpty {
                lastTrackID = ""; pendingTrackID = nil
                currentTheme = ""; currentEmotionID = ""; currentThemeID = ""
                currentThemeZH = ""; currentThemeEN = ""; lineEmotionID = ""
                currentHueBias = 0; currentEnergy = 0; currentGains = SIMD3(1, 1, 1)
                currentFontSetID = ""
                trackEmotion = nil; lineEmotion = nil; lineEmotionProb = 0; pool = []
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
        classifyTrack(id: id, name: music.trackName, artist: music.artist,
                      lines: Array(lines))
    }

    // MARK: - Track classification

    private func classifyTrack(id: String, name: String, artist: String, lines: [String]) {
        switch brain {
        case .laya:
            if let laya, laya.ready, laya.lanes.contains(.track) {
                classifyTrackLaya(laya, id: id, name: name, artist: artist, lines: lines)
            } else {
                applyFallback(track: id, name: name)
            }
        case .ollama:
            classifyTrackOllama(id: id, name: name, artist: artist, lines: lines)
        }
    }

    private func classifyTrackLaya(_ laya: LayaClient, id: String, name: String,
                                   artist: String, lines: [String]) {
        let lyricBlock = lines.isEmpty ? "" : " / " + lines.prefix(4).joined(separator: " / ")
        let text = "\(name) by \(artist)\(lyricBlock)"
        print("[emotion] laya classifying \(id)...")
        laya.predict(lane: .track, text: text, questions: [
            "theme": ["type": "choice", "criteria": Theme.all.map { $0.id },
                      "instructions": "Pick the visual art theme that best fits this song."],
            "emotion": ["type": "choice", "criteria": Emotion.all.map { $0.id },
                        "instructions": "Pick the dominant emotion of this song."],
            // 1024-token track lane only — the 96-token ANE line lane would
            // overflow on the criteria list alone.
            "fontset": ["type": "choice", "criteria": LyricFontPool.all.map { $0.id },
                        "instructions": "Pick the lyric poster font style by mood: "
                            + LyricFontPool.layaGuide],
        ]) { [weak self] resp in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightTrackID = nil
                guard self.currentMusicID == id else { return }   // stale
                guard let resp, let emoID = resp.answers["emotion"],
                      let emo = Emotion.byID(emoID) else {
                    print("[emotion] laya failed for \(id) — hash fallback")
                    self.applyFallback(track: id, name: name)
                    return
                }
                if resp.truncated { print("[emotion] note: track request was token-truncated") }
                // top-5 pool by probability (missing probs -> chosen = 1.0)
                let probs = resp.probabilities["theme"] ?? [:]
                let ranked = Theme.all
                    .map { (theme: $0, weight: probs[$0.id] ?? 0) }
                    .sorted { $0.weight > $1.weight }
                var top = Array(ranked.prefix(5))
                if top.allSatisfy({ $0.weight == 0 }), let chosen = resp.answers["theme"],
                   let t = Theme.byID(chosen) {
                    top = [(theme: t, weight: Float(1.0))]
                }
                self.pool = Self.normalized(top)
                self.trackEmotion = emo
                self.lineEmotion = nil; self.lineEmotionProb = 0; self.lineEmotionID = ""
                self.usedHashFallback = false
                self.lastTrackID = id
                // font arbitration: laya's pick, hash-stable pick if it
                // answered with an unknown id
                let fsID = resp.answers["fontset"].flatMap { LyricFontPool.byID($0)?.id }
                    ?? LyricFontPool.all[Self.stableIndex("font:" + id,
                                                          modulo: LyricFontPool.all.count)].id
                self.currentFontSetID = fsID
                self.onFontSet?(fsID)
                print("[emotion] fontset: \(fsID)")
                self.applyCurrent(lyricLine: "")
                print("[emotion] pool: " + self.pool.map {
                    "\($0.theme.id) \(String(format: "%.2f", $0.weight))" }.joined(separator: " | "))
            }
        }
    }

    private func classifyTrackOllama(id: String, name: String, artist: String, lines: [String]) {
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
                self.applyOllama(out)
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
            ?? Emotion.all[stableIndex(fallbackName, modulo: Emotion.all.count)]
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
        return ThemeOutput(emotionID: emo.id, emotionZH: emo.zh,
                           themeID: "", themeZH: "", themeEN: theme,
                           prompt: prompt, hueBias: hue, energy: energy,
                           crystalGain: emo.crystalGain, columnGain: emo.columnGain,
                           emberGain: emo.emberGain)
    }

    /// All brains down: deterministic emotion+theme picked by track-name hash.
    private func applyFallback(track id: String, name: String) {
        let emo = Emotion.all[Self.stableIndex(id, modulo: Emotion.all.count)]
        let theme = Theme.all[Self.stableIndex("theme:" + id, modulo: Theme.all.count)]
        pool = [(theme: theme, weight: 1.0)]
        trackEmotion = emo
        lineEmotion = nil; lineEmotionProb = 0; lineEmotionID = ""
        usedHashFallback = true
        inFlightTrackID = nil   // fallback completes synchronously — never in flight
        lastTrackID = id
        let fsID = LyricFontPool.all[Self.stableIndex("font:" + id,
                                                      modulo: LyricFontPool.all.count)].id
        currentFontSetID = fsID
        onFontSet?(fsID)
        applyCurrent(lyricLine: "")
    }

    // MARK: - Apply / compose (main thread)

    /// Ollama path keeps its free-text theme (no library pool sampling).
    private func applyOllama(_ t: ThemeOutput) {
        pool = []
        usedHashFallback = false
        let fsID = LyricFontPool.all[Self.stableIndex("font:" + currentMusicID,
                                                      modulo: LyricFontPool.all.count)].id
        currentFontSetID = fsID
        onFontSet?(fsID)
        trackEmotion = Emotion.byID(t.emotionID)
        currentTheme = t.prompt
        currentHueBias = t.hueBias
        currentEnergy = t.energy
        currentGains = SIMD3(t.crystalGain, t.columnGain, t.emberGain)
        currentEmotionID = t.emotionID
        currentThemeID = ""; currentThemeZH = ""
        currentThemeEN = t.themeEN
        print("[emotion] \(t.emotionID) \(t.emotionZH) | “\(t.themeEN)” | hue \(String(format: "%+.2f", t.hueBias)) energy \(String(format: "%.2f", t.energy))")
        onTheme?(t)
        emitPrompt(lyricLine: lastObservedLine)
    }

    /// laya/hash path: palette anchors from the pool's top theme, energy from
    /// the (line- or track-level) emotion; fires onTheme + a fresh prompt.
    private func applyCurrent(lyricLine: String) {
        guard let top = pool.first?.theme, let emo = lineEmotion ?? trackEmotion else { return }
        currentHueBias = min(max((top.hueBias + emo.hueBias) / 2, -0.5), 0.5)
        currentEnergy = emo.energy
        currentGains = SIMD3(top.crystalGain, top.columnGain, top.emberGain)
        currentEmotionID = emo.id
        currentThemeID = top.id
        currentThemeZH = top.zh
        currentThemeEN = top.id
        let out = ThemeOutput(emotionID: emo.id, emotionZH: emo.zh,
                              themeID: top.id, themeZH: top.zh, themeEN: top.id,
                              prompt: top.prompt + ", " + emo.stylePrompt,
                              hueBias: currentHueBias, energy: currentEnergy,
                              crystalGain: top.crystalGain, columnGain: top.columnGain,
                              emberGain: top.emberGain)
        currentTheme = out.prompt
        print("[emotion] \(emo.id) \(emo.zh) | theme \(top.id) \(top.zh) | hue \(String(format: "%+.2f", currentHueBias)) energy \(String(format: "%.2f", currentEnergy))")
        onTheme?(out)
        emitPrompt(lyricLine: lyricLine)
    }

    /// Weighted-random theme pick from the pool (probabilities ∝ weights),
    /// then compose: theme + emotion style + lyric line + fixed quality tail.
    private func composePrompt(lyricLine: String) -> String? {
        guard let theme = Self.weightedSample(pool), let emo = lineEmotion ?? trackEmotion
        else { return nil }
        var p = theme.prompt + ", " + emo.stylePrompt
        let line = lyricLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { p += ", " + String(line.prefix(60)) }
        p += ", " + Theme.qualityTail
        return p
    }

    /// Beat-snapped prompt push (2s throttle shared with the lyric switch).
    private func emitPrompt(lyricLine: String) {
        guard let onPrompt, let p = composePrompt(lyricLine: lyricLine) else { return }
        let fire = {
            print("[emotion-prompt] \(p.prefix(110))")
            onPrompt(p)
        }
        if let bc = music?.beatClock {
            let toNextBeat = (1 - (bc.phase - bc.phase.rounded(.down))) * bc.beatLen
            if toNextBeat > 0.1, toNextBeat < 1.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + toNextBeat) { fire() }
                return
            }
        }
        fire()
    }

    static func normalized(_ pool: [(theme: Theme, weight: Float)])
        -> [(theme: Theme, weight: Float)] {
        let sum = pool.reduce(Float(0)) { $0 + $1.weight }
        guard sum > 0 else { return pool }
        return pool.map { (theme: $0.theme, weight: $0.weight / sum) }
    }

    static func weightedSample(_ pool: [(theme: Theme, weight: Float)]) -> Theme? {
        guard !pool.isEmpty else { return nil }
        var r = Float.random(in: 0..<1)
        for e in pool {
            r -= e.weight
            if r <= 0 { return e.theme }
        }
        return pool.last?.theme
    }

    // MARK: - Lyric line updates (laya line lane, weight re-rank)

    private func updateLyricStats(music: MusicBridge, lyrics: LyricsService) {
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
                // lyric line switch -> laya line lane -> pool weight update
                // (2s throttle, same as the prompt modulation contract)
                if brain == .laya, Date().timeIntervalSince(lastPromptAt) >= 2 {
                    lastPromptAt = now
                    classifyLine(line)
                }
            }
        }
        chorusBoost = max(0, chorusBoost - 0.015)   // ~10s decay at 2 Hz ticks
        lyricPace = min(Float(lineSwitches.count) / 15.0, 1) // 15 switches/30s = a line every 2s
    }

    /// Per-line choice over the active pool + 14 emotions on the ANE lane
    /// (96-token budget: short instructions, lyric truncated to 40 chars).
    private func classifyLine(_ line: String) {
        guard let laya, laya.ready, laya.lanes.contains(.line),
              !inFlightLine, !pool.isEmpty else {
            // no laya line lane (or mid-request): still refresh the prompt so
            // the lyric line itself reaches the workers
            emitPrompt(lyricLine: line)
            return
        }
        inFlightLine = true
        let text = String(line.prefix(40))
        let trackID = currentMusicID
        let poolIDs = pool.map { $0.theme.id }
        laya.predict(lane: .line, text: text, questions: [
            "pick": ["type": "choice", "criteria": poolIDs,
                     "instructions": "Best matching visual theme?"],
            "emotion": ["type": "choice", "criteria": Emotion.all.map { $0.id },
                        "instructions": "Dominant emotion?"],
        ]) { [weak self] resp in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightLine = false
                guard self.currentMusicID == trackID, !trackID.isEmpty else { return }
                guard let resp else {
                    self.emitPrompt(lyricLine: line)
                    return
                }
                if resp.truncated { print("[emotion] note: line request was token-truncated") }
                // weight update: EMA toward the line-level distribution
                if let dist = resp.probabilities["pick"], !dist.isEmpty {
                    self.pool = Self.normalized(self.pool.map { e in
                        (theme: e.theme, weight: 0.55 * e.weight + 0.45 * (dist[e.theme.id] ?? 0))
                    })
                }
                // per-line emotion with +0.15 hysteresis
                if let emoID = resp.answers["emotion"], let emo = Emotion.byID(emoID) {
                    let probs = resp.probabilities["emotion"] ?? [:]
                    let newP = probs[emoID] ?? 1
                    let curP = self.lineEmotion.map { probs[$0.id] ?? 0 } ?? 0
                    if self.lineEmotion == nil || newP > curP + 0.15 {
                        self.lineEmotion = emo
                        self.lineEmotionProb = newP
                        self.lineEmotionID = emo.id
                    }
                }
                self.applyCurrent(lyricLine: line)
            }
        }
    }

    /// djb2 over the track id — stable across launches. `modulo` must match
    /// the table being indexed (Emotion.all.count vs Theme.all.count differ —
    /// a mismatch here is an index-out-of-range trap).
    static func stableIndex(_ s: String, modulo n: Int) -> Int {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % UInt64(n))
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
