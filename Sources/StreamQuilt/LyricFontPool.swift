import Foundation

/// Poster font sets for the lyric overlay. laya picks one per track at
/// classification time (track lane); the renderer switches immediately via
/// `LyricOverlayRenderer.applyFontSet`.
///
/// Each set carries separate latin / zh / ja faces (the renderer detects kana
/// in a lyric line and swaps the CJK run font to the ja face) plus a stroke
/// factor — thin calligraphy faces need much less stroke or their fill turns
/// hollow.
public struct LyricFontSet {
    public let id: String
    /// PostScript names: latin display face, zh face, ja face.
    public let latin: String
    public let zh: String
    public let ja: String
    /// Stroke width as a fraction of font size (negative-stroke attribute).
    public let strokeFactor: Float
    /// Short vibe description — embedded in the laya question instructions.
    public let vibe: String

    public init(id: String, latin: String, zh: String, ja: String,
                strokeFactor: Float, vibe: String) {
        self.id = id; self.latin = latin; self.zh = zh; self.ja = ja
        self.strokeFactor = strokeFactor; self.vibe = vibe
    }
}

public enum LyricFontPool {
    /// Cinzel (Trajan-style, OFL) lives in ~/Library/Fonts/Cinzel-Variable.ttf;
    /// when missing the renderer falls back to system black.
    public static let all: [LyricFontSet] = [
        LyricFontSet(id: "swiss", latin: "HelveticaNeue-CondensedBlack",
                     zh: "PingFangSC-Semibold", ja: "HiraginoSans-W7",
                     strokeFactor: 0.03, vibe: "现代极简,电子,流行"),
        LyricFontSet(id: "geometric", latin: "Futura-CondensedExtraBold",
                     zh: "HiraginoSansGB-W6", ja: "HiraginoSans-W6",
                     strokeFactor: 0.03, vibe: "几何,未来,合成器"),
        LyricFontSet(id: "din", latin: "DINCondensed-Bold",
                     zh: "PingFangSC-Medium", ja: "HiraginoSans-W6",
                     strokeFactor: 0.025, vibe: "工业,机能,冷静"),
        LyricFontSet(id: "brutalist", latin: "Impact",
                     zh: "STHeitiSC-Medium", ja: "HiraginoSans-W9",
                     strokeFactor: 0.03, vibe: "冲击,嘻哈,高能"),
        LyricFontSet(id: "modern", latin: "AvenirNextCondensed-Heavy",
                     zh: "PingFangSC-Semibold", ja: "HiraginoSans-W7",
                     strokeFactor: 0.03, vibe: "都市,人文,清爽"),
        LyricFontSet(id: "trajan-brush", latin: "CinzelRoman-Bold",
                     zh: "STXingkaiSC-Bold", ja: "YuMin-Extrabold",
                     strokeFactor: 0.015, vibe: "古典史诗,书法,电影感"),
        LyricFontSet(id: "trajan-pen", latin: "CinzelRoman-Black",
                     zh: "HanziPenSC-W5", ja: "HiraMinProN-W6",
                     strokeFactor: 0.015, vibe: "手写,私密,民谣"),
        LyricFontSet(id: "trajan-kai", latin: "CinzelRoman-Black",
                     zh: "STKaitiSC-Bold", ja: "YuMin-Demibold",
                     strokeFactor: 0.02, vibe: "典雅,国风,复古"),
        LyricFontSet(id: "copperplate", latin: "Copperplate-Bold",
                     zh: "HanziPenSC-W5", ja: "HiraMinProN-W6",
                     strokeFactor: 0.02, vibe: "华丽,戏剧,舞台"),
    ]

    public static func byID(_ id: String) -> LyricFontSet? { all.first { $0.id == id } }

    /// Compact id=vibe guide embedded in the laya fontset question — the
    /// track lane has a 1024-token budget shared with theme/emotion, keep
    /// this terse. Never route this question through the 96-token ANE line
    /// lane.
    public static let layaGuide = all.map { "\($0.id)=\($0.vibe)" }.joined(separator: ",")
}
