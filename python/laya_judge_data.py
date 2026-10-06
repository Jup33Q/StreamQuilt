"""Answer-space tables for the laya judge fixture/eval — mirrors of
Sources/StreamQuilt/AI/ThemeLibrary.swift (Theme.all / SubjectPool) and
EmotionEngine.swift (Emotion.all). Keep in sync with the Swift sources:
the fixture labels and the eval questions must use the app's exact id lists.
"""

# (id, zh, SD prompt fragment) — Theme.all, 18 themes
THEMES = [
    ("synthwave", "蒸汽波", "synthwave retrowave valley, neon grid terrain, chrome sunset, magenta and cyan glow"),
    ("ink-wash", "水墨山水", "traditional Chinese ink wash painting, misty mountain ranges, flowing black ink gradients, rice paper texture, minimalist brush strokes"),
    ("cyberpunk-rain", "赛博雨夜", "cyberpunk city in the rain, wet neon reflections, electric blue and hot pink signage, moody drizzle haze"),
    ("ukiyoe", "浮世绘", "ukiyo-e woodblock print style, great wave curves, indigo and vermilion flat color blocks, bold contour lines"),
    ("ghibli-pastoral", "吉卜力田园", "ghibli-style pastoral landscape, lush green meadows, fluffy cumulus sky, warm sunlight, hand-painted softness"),
    ("retro-space", "复古航天", "retro 1960s space-age poster, atomic starbursts, cream and orange screen-print palette, optimistic futurism"),
    ("pixel-neon", "像素霓虹", "pixel-art neon arcade world, crisp 8-bit blocks, glow-grid horizon, saturated arcade cabinet colors"),
    ("impressionist", "印象派", "impressionist oil painting, visible brush strokes, dappled golden light, soft violet shadows, Monet garden atmosphere"),
    ("papercut", "剪纸", "layered papercut art, crisp paper silhouettes, festive red and gold layers, soft depth shadows between layers"),
    ("low-poly", "低多边形", "low-poly 3D render, faceted geometric terrain, flat-shaded pastel gradients, clean minimal polygons"),
    ("woodcut-bw", "黑白木刻", "black and white woodcut engraving, stark chiaroscuro contrast, carved line texture, dramatic monochrome"),
    ("dunhuang", "敦煌壁画", "Dunhuang mural fresco style, mineral pigment palette of malachite green and cinnabar, celestial apsara ribbons, weathered cave-wall texture"),
    ("art-nouveau", "新艺术", "art nouveau illustration, flowing organic lines, Alphonse Mucha elegance, muted gold and teal ornamental borders"),
    ("steampunk", "蒸汽朋克", "steampunk brass and copper machinery, victorian gears and steam pipes, warm amber workshop glow"),
    ("watercolor", "水彩", "loose watercolor painting, bleeding pigment washes, soft paper texture, airy translucent color layers"),
    ("stained-glass", "彩绘玻璃", "stained glass cathedral window, bold lead contours, jewel-toned ruby emerald and sapphire light"),
    ("origami", "折纸", "origami paper craft world, folded crisp paper facets, soft studio lighting, playful paper textures"),
    ("glitch", "故障艺术", "glitch art databending aesthetics, datamosh streaks, RGB channel splits, digital decay energy"),
]

# (id, zh) — Emotion.all, 14 emotions
EMOTIONS = [
    ("euphoric", "狂喜"), ("joyful", "欢快"), ("hopeful", "希望"), ("serene", "宁静"),
    ("dreamy", "梦幻"), ("nostalgic", "怀旧"), ("melancholic", "忧郁"), ("lonely", "孤独"),
    ("tense", "紧张"), ("dark", "阴暗"), ("romantic", "浪漫"), ("mystical", "神秘"),
    ("rebellious", "躁动"), ("epic", "史诗"),
]

# SubjectPool.categories order
CATEGORIES = ["people", "animal", "architecture", "vehicle", "food"]

# (id, zh, cat, EN subject fragment) — SubjectPool.all, 34 cards
SUBJECTS = [
    ("wanderer", "提灯旅人", "people", "a lone wanderer holding a glowing lantern"),
    ("dancer", "飘带舞者", "people", "a dancing girl with long flowing ribbons"),
    ("astronaut", "漂浮宇航员", "people", "an astronaut floating weightlessly"),
    ("samurai", "花瓣武士", "people", "a samurai standing in falling petals"),
    ("witch", "扫帚小魔女", "people", "a little witch flying on a broomstick"),
    ("diver", "深海潜水员", "people", "a deep-sea diver with a glowing helmet"),
    ("wyvern", "双足飞龙", "animal", "a soaring wyvern dragon with outstretched wings"),
    ("ninetails", "九尾狐", "animal", "a mystical nine-tailed fox spirit"),
    ("koi", "云中锦鲤", "animal", "a giant koi fish swimming through clouds"),
    ("crane", "丹顶鹤", "animal", "a red-crowned crane in graceful flight"),
    ("skywhale", "天鲸", "animal", "a sky whale drifting between mountains"),
    ("ninedeer", "九色鹿", "animal", "a celestial nine-colored deer"),
    ("pagoda", "多层宝塔", "architecture", "an ancient multi-tiered pagoda"),
    ("cathedral", "哥特教堂", "architecture", "a gothic cathedral with rose windows"),
    ("neontower", "霓虹高塔", "architecture", "a neon-lit vertical city tower"),
    ("skycastle", "天空城堡", "architecture", "a floating castle above the clouds"),
    ("ruins", "沙漠遗迹", "architecture", "overgrown ancient desert ruins"),
    ("torii", "海上鸟居", "architecture", "a seaside torii shrine gate"),
    ("biplane", "双翼飞机", "vehicle", "a vintage biplane trailing smoke"),
    ("steamtrain", "蒸汽火车", "vehicle", "a steam locomotive crossing a viaduct"),
    ("rocket", "复古火箭", "vehicle", "a retro chrome rocket spaceship"),
    ("zeppelin", "齐柏林飞艇", "vehicle", "a majestic zeppelin airship"),
    ("motorcycle", "未来摩托", "vehicle", "a futuristic motorcycle speeding forward"),
    ("sailboat", "光波帆船", "vehicle", "a tall sailboat on glowing waves"),
    ("candy", "缤纷糖果", "food", "giant colorful candies and lollipops"),
    ("cottoncandy", "棉花糖云", "food", "fluffy pink cotton candy clouds"),
    ("ricebowl", "热气盖饭", "food", "a bowl of steaming rice with rich toppings"),
    ("ramen", "蒸汽拉面", "food", "a bowl of ramen with swirling steam"),
    ("cake", "草莓蛋糕", "food", "a towering strawberry layer cake"),
    ("boba", "珍珠奶茶", "food", "a giant boba milk tea with pearls"),
    ("soysauce", "酱油瓶", "food", "a glossy soy sauce bottle"),
    ("cookingwine", "料酒瓶", "food", "a vintage cooking wine bottle"),
    ("nori", "海苔", "food", "crisp dark green nori seaweed sheets"),
    ("sushi", "寿司拼盘", "food", "an artful sushi platter with nigiri"),
]

THEME_IDS = [t[0] for t in THEMES]
EMOTION_IDS = [e[0] for e in EMOTIONS]
SUBJECT_IDS = [s[0] for s in SUBJECTS]
SUBJECT_CAT = {s[0]: s[2] for s in SUBJECTS}

# App-identical question instructions (EmotionEngine.classifyTrackLaya).
INS_THEME = "Pick the visual art theme that best fits this song."
INS_EMOTION = "Pick the dominant emotion of this song."
INS_SUBJECT_CAT = "Pick the foreground subject category that best fits this song's imagery."
INS_SUBJECT = "Pick the foreground subject that best fits this song's imagery."

# LyricFontPool.all ids + layaGuide (the app's 4th track-lane question; the
# eval includes it so the judge prompt is token-identical to the app's).
FONTSETS = [
    ("swiss", "现代极简,电子,流行"), ("geometric", "几何,未来,合成器"),
    ("din", "工业,机能,冷静"), ("brutalist", "冲击,嘻哈,高能"),
    ("modern", "都市,人文,清爽"), ("trajan-brush", "古典史诗,书法,电影感"),
    ("trajan-pen", "手写,私密,民谣"), ("trajan-kai", "典雅,国风,复古"),
    ("copperplate", "华丽,戏剧,舞台"),
]
FONTSET_IDS = [f[0] for f in FONTSETS]
LAYA_GUIDE = ",".join(f"{f}={v}" for f, v in FONTSETS)
INS_FONTSET = "Pick the lyric poster font style by mood: " + LAYA_GUIDE


def cards_of(cat):
    """Card ids of one category, pool order (app: SubjectPool.category)."""
    return [s[0] for s in SUBJECTS if s[2] == cat]


def track_text(name, artist, album, genre, lyric_lines):
    """App-identical judge text (EmotionEngine.classifyTrackLaya):
    "name by artist (album: X, genre: Y) / l1 / l2 / l3 / l4"."""
    text = f"{name} by {artist}"
    bits = []
    if album:
        bits.append(f"album: {album}")
    if genre:
        bits.append(f"genre: {genre}")
    if bits:
        text += " (" + ", ".join(bits) + ")"
    lines = [l for l in lyric_lines if l][:4]
    if lines:
        text += " / " + " / ".join(lines)
    return text
