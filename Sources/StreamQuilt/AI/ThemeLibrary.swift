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
        Theme(id: "art-nouveau", zh: "新艺术",
              prompt: "art nouveau illustration, flowing organic lines, Alphonse Mucha elegance, muted gold and teal ornamental borders",
              hueBias: 0.07, crystalGain: 1.1, columnGain: 0.8, emberGain: 1.2),
        Theme(id: "steampunk", zh: "蒸汽朋克",
              prompt: "steampunk brass and copper machinery, victorian gears and steam pipes, warm amber workshop glow",
              hueBias: 0.13, crystalGain: 1.2, columnGain: 1.4, emberGain: 0.9),
        Theme(id: "watercolor", zh: "水彩",
              prompt: "loose watercolor painting, bleeding pigment washes, soft paper texture, airy translucent color layers",
              hueBias: 0.03, crystalGain: 0.7, columnGain: 0.6, emberGain: 1.0),
        Theme(id: "stained-glass", zh: "彩绘玻璃",
              prompt: "stained glass cathedral window, bold lead contours, jewel-toned ruby emerald and sapphire light",
              hueBias: -0.04, crystalGain: 1.3, columnGain: 1.1, emberGain: 1.3),
        Theme(id: "origami", zh: "折纸",
              prompt: "origami paper craft world, folded crisp paper facets, soft studio lighting, playful paper textures",
              hueBias: 0.06, crystalGain: 0.9, columnGain: 1.0, emberGain: 0.8),
        Theme(id: "glitch", zh: "故障艺术",
              prompt: "glitch art databending aesthetics, datamosh streaks, RGB channel splits, digital decay energy",
              hueBias: -0.06, crystalGain: 1.4, columnGain: 1.2, emberGain: 1.5),
    ]

    public static func byID(_ id: String) -> Theme? { all.first { $0.id == id } }

    /// Fixed control tail for every composed prompt — quality/behavior tokens
    /// are never sampled, only the library content is (user requirement).
    public static let qualityTail = "clean bold shapes, vivid colors, masterpiece"
}


/// Subject card pools (S6.2): concrete foreground subjects — people, animals
/// (incl. dragons), architecture, vehicles — injected between the theme
/// fragment and the emotion style in the composed prompt. Track-level laya
/// arbitration picks one card per track (1024-token lane; the 96-token ANE
/// line lane never sees the criteria list); within a track the card slowly
/// rotates inside its category every few lyric lines for evolution over time.
public struct SubjectCard {
    public let id: String
    public let zh: String
    public let cat: String   // people | animal | architecture | vehicle
    /// SD subject fragment (kept short — CLIP budget after theme+emotion+lyric).
    public let prompt: String

    public init(_ id: String, _ zh: String, _ cat: String, _ prompt: String) {
        self.id = id; self.zh = zh; self.cat = cat; self.prompt = prompt
    }
}

public enum SubjectPool {
    public static let all: [SubjectCard] = [
        // people
        SubjectCard("wanderer", "提灯旅人", "people", "a lone wanderer holding a glowing lantern"),
        SubjectCard("dancer", "飘带舞者", "people", "a dancing girl with long flowing ribbons"),
        SubjectCard("astronaut", "漂浮宇航员", "people", "an astronaut floating weightlessly"),
        SubjectCard("samurai", "花瓣武士", "people", "a samurai standing in falling petals"),
        SubjectCard("witch", "扫帚小魔女", "people", "a little witch flying on a broomstick"),
        SubjectCard("diver", "深海潜水员", "people", "a deep-sea diver with a glowing helmet"),
        // animals
        SubjectCard("wyvern", "双足飞龙", "animal", "a soaring wyvern dragon with outstretched wings"),
        SubjectCard("ninetails", "九尾狐", "animal", "a mystical nine-tailed fox spirit"),
        SubjectCard("koi", "云中锦鲤", "animal", "a giant koi fish swimming through clouds"),
        SubjectCard("crane", "丹顶鹤", "animal", "a red-crowned crane in graceful flight"),
        SubjectCard("skywhale", "天鲸", "animal", "a sky whale drifting between mountains"),
        SubjectCard("ninedeer", "九色鹿", "animal", "a celestial nine-colored deer"),
        // architecture
        SubjectCard("pagoda", "多层宝塔", "architecture", "an ancient multi-tiered pagoda"),
        SubjectCard("cathedral", "哥特教堂", "architecture", "a gothic cathedral with rose windows"),
        SubjectCard("neontower", "霓虹高塔", "architecture", "a neon-lit vertical city tower"),
        SubjectCard("skycastle", "天空城堡", "architecture", "a floating castle above the clouds"),
        SubjectCard("ruins", "沙漠遗迹", "architecture", "overgrown ancient desert ruins"),
        SubjectCard("torii", "海上鸟居", "architecture", "a seaside torii shrine gate"),
        // food
        SubjectCard("candy", "缤纷糖果", "food", "giant colorful candies and lollipops"),
        SubjectCard("cottoncandy", "棉花糖云", "food", "fluffy pink cotton candy clouds"),
        SubjectCard("ricebowl", "热气盖饭", "food", "a bowl of steaming rice with rich toppings"),
        SubjectCard("ramen", "蒸汽拉面", "food", "a bowl of ramen with swirling steam"),
        SubjectCard("cake", "草莓蛋糕", "food", "a towering strawberry layer cake"),
        SubjectCard("boba", "珍珠奶茶", "food", "a giant boba milk tea with pearls"),
        SubjectCard("soysauce", "酱油瓶", "food", "a glossy soy sauce bottle"),
        SubjectCard("cookingwine", "料酒瓶", "food", "a vintage cooking wine bottle"),
        SubjectCard("nori", "海苔", "food", "crisp dark green nori seaweed sheets"),
        SubjectCard("sushi", "寿司拼盘", "food", "an artful sushi platter with nigiri"),
        // vehicles
        SubjectCard("biplane", "双翼飞机", "vehicle", "a vintage biplane trailing smoke"),
        SubjectCard("steamtrain", "蒸汽火车", "vehicle", "a steam locomotive crossing a viaduct"),
        SubjectCard("rocket", "复古火箭", "vehicle", "a retro chrome rocket spaceship"),
        SubjectCard("zeppelin", "齐柏林飞艇", "vehicle", "a majestic zeppelin airship"),
        SubjectCard("motorcycle", "未来摩托", "vehicle", "a futuristic motorcycle speeding forward"),
        SubjectCard("sailboat", "光波帆船", "vehicle", "a tall sailboat on glowing waves"),
    ]

    /// Category ids in pool order (people/animal/architecture/vehicle/food).
    public static let categories = ["people", "animal", "architecture", "vehicle", "food"]

    public static func byID(_ id: String) -> SubjectCard? { all.first { $0.id == id } }
    public static func category(_ cat: String) -> [SubjectCard] { all.filter { $0.cat == cat } }
}
