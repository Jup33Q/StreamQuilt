import Foundation

/// Visual theme library (E3): each theme is a complete SD style-prompt
/// fragment plus a scene palette anchor (hueBias) and per-element gains for
/// the raymarched scene. Themes are the *choice criteria* for the laya
/// track-level classification; per-line lyric updates re-rank the active
/// pool's sampling weights (see TrackThemeEngine).
///
/// Prompt composition contract: theme prompt + emotion style + lyric line +
/// `qualityTail`. Control tokens ("masterpiece" etc.) live ONLY in
/// `qualityTail` — never inside theme fragments, so library sampling stays
/// orthogonal to quality steering.
public struct Theme {
    public let id: String
    public let zh: String
    /// SD style-prompt fragment (palette + atmosphere + medium).
    public let prompt: String
    /// Hue re-anchor (-0.5...0.5, negative = cool, positive = warm).
    public let hueBias: Float
    /// Element gains 0.3...2.0 (shader theme uniform y/z/w).
    public let crystalGain: Float
    public let columnGain: Float
    public let emberGain: Float

    public init(id: String, zh: String, prompt: String, hueBias: Float,
                crystalGain: Float, columnGain: Float, emberGain: Float) {
        self.id = id
        self.zh = zh
        self.prompt = prompt
        self.hueBias = hueBias
        self.crystalGain = crystalGain
        self.columnGain = columnGain
        self.emberGain = emberGain
    }

    public static let all: [Theme] = [
        Theme(id: "synthwave", zh: "蒸汽波",
              prompt: "synthwave retrowave valley, neon grid terrain, chrome sunset, magenta and cyan glow",
              hueBias: 0.05, crystalGain: 1.2, columnGain: 1.3, emberGain: 1.0),
        Theme(id: "ink-wash", zh: "水墨山水",
              prompt: "traditional Chinese ink wash painting, misty mountain ranges, flowing black ink gradients, rice paper texture, minimalist brush strokes",
              hueBias: -0.06, crystalGain: 0.8, columnGain: 0.7, emberGain: 0.5),
        Theme(id: "cyberpunk-rain", zh: "赛博雨夜",
              prompt: "cyberpunk city in the rain, wet neon reflections, electric blue and hot pink signage, moody drizzle haze",
              hueBias: -0.10, crystalGain: 1.3, columnGain: 1.6, emberGain: 1.1),
        Theme(id: "ukiyoe", zh: "浮世绘",
              prompt: "ukiyo-e woodblock print style, great wave curves, indigo and vermilion flat color blocks, bold contour lines",
              hueBias: 0.02, crystalGain: 0.9, columnGain: 1.0, emberGain: 0.8),
        Theme(id: "ghibli-pastoral", zh: "吉卜力田园",
              prompt: "ghibli-style pastoral landscape, lush green meadows, fluffy cumulus sky, warm sunlight, hand-painted softness",
              hueBias: 0.08, crystalGain: 0.7, columnGain: 0.8, emberGain: 1.2),
        Theme(id: "retro-space", zh: "复古航天",
              prompt: "retro 1960s space-age poster, atomic starbursts, cream and orange screen-print palette, optimistic futurism",
              hueBias: 0.12, crystalGain: 1.1, columnGain: 1.0, emberGain: 1.3),
        Theme(id: "pixel-neon", zh: "像素霓虹",
              prompt: "pixel-art neon arcade world, crisp 8-bit blocks, glow-grid horizon, saturated arcade cabinet colors",
              hueBias: 0.0, crystalGain: 1.0, columnGain: 1.5, emberGain: 1.2),
        Theme(id: "impressionist", zh: "印象派",
              prompt: "impressionist oil painting, visible brush strokes, dappled golden light, soft violet shadows, Monet garden atmosphere",
              hueBias: 0.06, crystalGain: 0.9, columnGain: 0.7, emberGain: 1.4),
        Theme(id: "papercut", zh: "剪纸",
              prompt: "layered papercut art, crisp paper silhouettes, festive red and gold layers, soft depth shadows between layers",
              hueBias: 0.14, crystalGain: 0.8, columnGain: 1.1, emberGain: 0.9),
        Theme(id: "low-poly", zh: "低多边形",
              prompt: "low-poly 3D render, faceted geometric terrain, flat-shaded pastel gradients, clean minimal polygons",
              hueBias: 0.0, crystalGain: 1.4, columnGain: 0.9, emberGain: 0.7),
        Theme(id: "woodcut-bw", zh: "黑白木刻",
              prompt: "black and white woodcut engraving, stark chiaroscuro contrast, carved line texture, dramatic monochrome",
              hueBias: -0.02, crystalGain: 1.1, columnGain: 1.2, emberGain: 0.4),
        Theme(id: "dunhuang", zh: "敦煌壁画",
              prompt: "Dunhuang mural fresco style, mineral pigment palette of malachite green and cinnabar, celestial apsara ribbons, weathered cave-wall texture",
              hueBias: 0.10, crystalGain: 1.2, columnGain: 0.8, emberGain: 1.5),
    ]

    public static func byID(_ id: String) -> Theme? { all.first { $0.id == id } }

    /// Fixed control tail for every composed prompt — quality/behavior tokens
    /// are never sampled, only the library content is (user requirement).
    public static let qualityTail = "clean bold shapes, vivid colors, masterpiece"
}
