import AppKit
import CoreGraphics
import Metal

/// Renders the current lyric line into a full-screen RGBA8 "movie poster"
/// overlay that the lenticular interlace pass samples with per-view parallax
/// (`LenticularUniforms.overlayShift` / `encodeLenticular(overlay:)`).
///
/// Layout (top-down, full bleed):
///   - top-left: tracked caps subtitle (track — artist) with a vertical tick
///   - lower third: the lyric line in heavy multi-line type, left-aligned,
///     over a subtle bottom scrim gradient for legibility; the sung prefix
///     sweeps bright over a dim base (karaoke coverage)
///   - footer: full-width hairline MUSIC progress bar + monospaced timecode
///
/// Direction pitfall: CGContext is bottom-up, Metal textures are top-down.
/// The context is flipped (`translate(0,h) + scale(1,-1)`) before drawing and
/// AppKit text runs inside `NSGraphicsContext(cgContext:flipped: true)` —
/// NSString.draw is a silent no-op without a current NSGraphicsContext in CLI
/// processes. Verify with `--overlay-dump` before trusting it on hardware.
///
/// The texture stores premultiplied RGBA; the interlace shader's
/// `mix(out, ov.rgb, ov.a)` is then exactly "over" compositing.
public final class LyricOverlayRenderer {
    public private(set) var texture: MTLTexture?

    private let device: MTLDevice
    private var ctx: CGContext?
    private var ctxData: UnsafeMutableRawPointer?
    private var size: CGSize = .zero
    /// (title, subtitle) currently baked into the texture (nil = not rendered).
    private var renderedContent: (String, String)?
    /// Title line layout cached by the poster render, for cheap karaoke
    /// coverage redraws (dim base + bright sung prefix swept per line).
    private struct TitleLayout {
        var dim: [NSAttributedString] = []    // stroked translucent base
        var bright: [NSAttributedString] = [] // stroke-less fill (glass gradient mask)
        var rim: [NSAttributedString] = []    // stroke-only glass edge
        var widths: [CGFloat] = []
        var lineH: CGFloat = 0
        var origin: CGPoint = .zero
        var strip: CGRect = .zero
    }
    private var titleLayout: TitleLayout?
    /// Title-strip pixels right after the poster render (pre-text), restored
    /// before each coverage redraw.
    private var titleBackup: [UInt8] = []
    private var coverageState: Float = -1
    /// Footer pixels right after the last full render (bar/timecode area
    /// clean), restored before each footer-only redraw.
    private var footerBackup: [UInt8] = []
    private var footerStrip: CGRect = .zero
    private var footerState: (progress: Float, timecode: String) = (-1, "￼")

    public init(device: MTLDevice) { self.device = device }

    /// PostScript font names for the poster title: latin glyphs come from the
    /// latin face, CJK glyphs from the zh face — or the ja face when the line
    /// contains kana (per-token font runs, no cascade — cascades render CJK
    /// at mismatching weights).
    public var titleLatinFontName = "HelveticaNeue-CondensedBlack"
    public var titleCJKFontName = "PingFangSC-Semibold"
    public var titleJPFontName = "HiraginoSans-W7"
    /// Stroke width as a fraction of font size. Legacy: the karaoke glass
    /// title renders stroke-less; kept for font-set API compatibility.
    public var strokeFactor: Float = 0.03

    /// Switch the whole font set (laya per-track arbitration). Forces a
    /// poster re-render on the next update.
    public func applyFontSet(_ s: LyricFontSet) {
        titleLatinFontName = s.latin
        titleCJKFontName = s.zh
        titleJPFontName = s.ja
        strokeFactor = s.strokeFactor
        renderedContent = nil
        footerState = (-1, "\u{FFFC}")
    }

    private func latinFont(size: CGFloat) -> NSFont {
        NSFont(name: titleLatinFontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .black)
    }
    private func cjkFont(size: CGFloat) -> NSFont {
        NSFont(name: titleCJKFontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
    private func jpFont(size: CGFloat) -> NSFont {
        NSFont(name: titleJPFontName, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    /// One word token from the system segmenter.
    private struct WordToken {
        let text: String
        let gapBefore: String  // whitespace between the previous token and this one
        let cjk: Bool
    }

    /// Word-tokenize a lyric line with the system segmenter
    /// (CFStringTokenizer: real CJK words, not per-character splits;
    /// language-agnostic, handles mixed zh/en lines in one pass).
    private static func tokenize(_ s: String) -> [WordToken] {
        let ns = s as NSString
        guard ns.length > 0,
              let tz = CFStringTokenizerCreate(nil, s as CFString, CFRangeMake(0, ns.length),
                                               kCFStringTokenizerUnitWord, nil)
        else { return s.isEmpty ? [] : [WordToken(text: s, gapBefore: "", cjk: containsCJK(s))] }
        var out: [WordToken] = []
        var prevEnd = 0
        while CFStringTokenizerAdvanceToNextToken(tz).rawValue != 0 {
            let r = CFStringTokenizerGetCurrentTokenRange(tz)
            guard r.location >= 0, r.location + r.length <= ns.length else { break }
            let text = ns.substring(with: NSRange(location: r.location, length: r.length))
            let gap = r.location > prevEnd
                ? ns.substring(with: NSRange(location: prevEnd, length: r.location - prevEnd)) : ""
            out.append(WordToken(text: text, gapBefore: gap, cjk: containsCJK(text)))
            prevEnd = r.location + r.length
        }
        return out
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value)        // CJK radicals … unified ideographs
                || (0xF900...0xFAFF).contains($0.value) // compatibility ideographs
                || (0xFF00...0xFF65).contains($0.value) // fullwidth forms / halfwidth kana
                || (0x20000...0x2FA1F).contains($0.value) // extension B+
        }
    }

    /// Liquid-glass text: glyph shapes painted with a vertical specular
    /// gradient (transparency layer + .sourceIn) — bright top highlight,
    /// translucent cool-tinted bottom. Callers must have a flipped
    /// NSGraphicsContext.current set.
    private func drawGlass(_ astr: NSAttributedString, at point: CGPoint, in ctx: CGContext) {
        let s = astr.size()
        let rect = CGRect(x: point.x, y: point.y - s.height * 0.08,
                          width: s.width, height: s.height * 1.16)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        astr.draw(at: point)
        ctx.setBlendMode(.sourceIn)
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [NSColor(white: 1.0, alpha: 0.98).cgColor,
                                       NSColor(white: 1.0, alpha: 0.86).cgColor,
                                       NSColor(red: 0.82, green: 0.90, blue: 1.0, alpha: 0.62).cgColor,
                                       NSColor(red: 0.68, green: 0.78, blue: 1.0, alpha: 0.46).cgColor] as CFArray,
                              locations: [0, 0.18, 0.55, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.minX, y: rect.maxY), options: [])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Hiragana/katakana present → the line is Japanese; CJK tokens should use
    /// the ja face (kanji glyphs differ subtly between zh/ja fonts).
    private static func containsKana(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
        }
    }

    /// Closing punctuation that must not start a wrapped line (kinsoku).
    private static let noLineStart: Set<String> = [
        "，", "。", "！", "？", "；", "：", "、", "”", "’", "）", "】", "》",
        ",", ".", "!", "?", ";", ":", ")", "]",
    ]

    /// Feed the current line. Cheap when nothing changed: a full poster
    /// redraw happens only on title/subtitle/size change, otherwise just the
    /// karaoke coverage sweep (title strip) and the footer strip are
    /// re-uploaded.
    /// - `progress`: MUSIC track progress 0..1 → the footer bar.
    /// - `coverage`: lyric line progress 0..1 → karaoke highlight sweep over
    ///   the title text (pass 0 for instrumental / track-title display).
    /// `drawableSize` = the device view's drawable size in pixels (lazily
    /// allocates the texture on first call).
    public func update(title: String, subtitle: String = "",
                       progress: Float, coverage: Float = 0, timecode: String = "",
                       drawableSize: CGSize) {
        let sizeChanged = drawableSize != size
        if sizeChanged || ctx == nil {
            guard drawableSize.width >= 8, drawableSize.height >= 8 else { return }
            allocate(size: drawableSize)
        }
        if sizeChanged || renderedContent == nil || renderedContent! != (title, subtitle) {
            renderPoster(title: title, subtitle: subtitle)
            renderedContent = (title, subtitle)
            footerState = (-1, "￼")
            coverageState = -1
        }
        let cov = min(max(coverage, 0), 1)
        if cov != coverageState {
            renderCoverage(cov)
            coverageState = cov
        }
        let p = min(max(progress, 0), 1)
        if (p, timecode) != footerState {
            renderFooter(progress: p, timecode: timecode)
            footerState = (p, timecode)
        }
    }

    /// Release the texture/context (next update reallocates).
    public func reset() {
        texture = nil
        ctx = nil
        ctxData = nil
        size = .zero
        renderedContent = nil
        titleLayout = nil
        titleBackup = []
        coverageState = -1
        footerBackup = []
        footerState = (-1, "￼")
    }

    /// "1:23 / 3:45" for the footer.
    public static func timecode(position: Double, duration: Double) -> String {
        func mmss(_ t: Double) -> String {
            let s = max(0, Int(t.rounded()))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return duration > 0 ? mmss(position) + " / " + mmss(duration) : mmss(position)
    }

    // MARK: - Allocation

    private func allocate(size: CGSize) {
        reset()
        self.size = size
        let w = Int(size.width), h = Int(size.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        texture = device.makeTexture(descriptor: d)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let data = malloc(w * h * 4),
              let c = CGContext(data: data, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: cs, bitmapInfo: info.rawValue)
        else { return }
        // flip to top-down so layout matches Metal texture row order
        c.translateBy(x: 0, y: size.height)
        c.scaleBy(x: 1, y: -1)
        ctx = c
        ctxData = data

        // footer strip: progress bar + timecode, bottom ~4% of the screen
        let footerH = size.height * 0.042
        footerStrip = CGRect(x: 0, y: size.height - footerH, width: size.width, height: footerH)
        footerBackup = [UInt8](repeating: 0, count: Int(footerStrip.width * footerStrip.height) * 4)
    }

    // MARK: - Full poster render

    private func renderPoster(title: String, subtitle: String) {
        guard let ctx, let data = ctxData else { return }
        let w = Int(size.width), h = Int(size.height)
        ctx.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard !title.isEmpty else {
            titleLayout = nil
            titleBackup = []
            snapshotFooter()
            upload(data: data, region: CGRect(x: 0, y: 0, width: w, height: h))
            return
        }
        let margin = size.width * 0.075

        // cinematic scrim: transparent at mid-height → dark at the bottom
        let scrim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [NSColor.black.withAlphaComponent(0).cgColor,
                                        NSColor.black.withAlphaComponent(0.42).cgColor] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(scrim,
                               start: CGPoint(x: 0, y: size.height * 0.48),
                               end: CGPoint(x: 0, y: size.height),
                               options: [])

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        // header: two-line lockup — track name in large glass type over a
        // tracked caps artist line, with a full-height gradient tick
        if !subtitle.isEmpty {
            let parts = subtitle.components(separatedBy: " — ")
            let trackT = parts.first ?? subtitle
            let artistT = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : ""
            let nameFont = NSFont.systemFont(ofSize: size.width * 0.042, weight: .bold)
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: nameFont,
                .foregroundColor: NSColor.white,
            ]
            let nameY = size.height * 0.062
            let nameSize = (trackT as NSString).size(withAttributes: nameAttrs)
            var tickH = nameSize.height
            var artistH: CGFloat = 0
            var artistAttrs: [NSAttributedString.Key: Any] = [:]
            if !artistT.isEmpty {
                let artFont = NSFont.systemFont(ofSize: size.width * 0.024, weight: .semibold)
                artistAttrs = [
                    .font: artFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.62),
                    .kern: artFont.pointSize * 0.24,
                ]
                artistH = (artistT.uppercased() as NSString).size(withAttributes: artistAttrs).height
                tickH += artistH * 1.35
            }
            let tick = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [NSColor(white: 1.0, alpha: 0.95).cgColor,
                                           NSColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 0.35).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.saveGState()
            ctx.clip(to: CGRect(x: margin, y: nameY, width: size.width * 0.006, height: tickH))
            ctx.drawLinearGradient(tick, start: CGPoint(x: margin, y: nameY),
                                   end: CGPoint(x: margin, y: nameY + tickH), options: [])
            ctx.restoreGState()
            let textX = margin + size.width * 0.024
            drawGlass(NSAttributedString(string: trackT, attributes: nameAttrs),
                      at: CGPoint(x: textX, y: nameY), in: ctx)
            if !artistT.isEmpty {
                (artistT.uppercased() as NSString).draw(
                    at: CGPoint(x: textX, y: nameY + nameSize.height * 1.2),
                    withAttributes: artistAttrs)
            }
        }

        // main title: word-tokenized by the system segmenter (CJK words stay
        // intact), greedy-wrapped with per-token latin/CJK font runs,
        // shrink-to-fit in the lower third; karaoke coverage = dim translucent
        // base + liquid-glass bright sweep (drawGlass) + stroke-less rim
        let maxW = size.width - margin * 2
        let maxH = size.height * 0.30
        let tokens = Self.tokenize(title)
        let jpLine = Self.containsKana(title)
        var fontSize = size.height * 0.105
        var lines: [[WordToken]] = []
        var lineH: CGFloat = 0
        for _ in 0..<10 {
            let lf = latinFont(size: fontSize)
            let cf = jpLine ? jpFont(size: fontSize) : cjkFont(size: fontSize)
            func tokenWidth(_ t: WordToken) -> CGFloat {
                NSAttributedString(string: t.text,
                                   attributes: [.font: t.cjk ? cf : lf]).size().width
            }
            let spaceW = NSAttributedString(string: " ", attributes: [.font: lf]).size().width
            lines = []
            var cur: [WordToken] = []
            var curW: CGFloat = 0
            var singleTokenOverflow = false
            for t in tokens {
                let tw = tokenWidth(t)
                if tw > maxW { singleTokenOverflow = true }
                let gapW = cur.isEmpty ? 0 : (t.gapBefore.isEmpty ? 0 : spaceW)
                if !cur.isEmpty && curW + gapW + tw > maxW && !Self.noLineStart.contains(t.text) {
                    lines.append(cur)
                    cur = [t]
                    curW = tw
                } else {
                    curW += gapW + tw
                    cur.append(t)
                }
            }
            if !cur.isEmpty { lines.append(cur) }
            lineH = max(lf.ascender - lf.descender, cf.ascender - cf.descender) * 1.14
            let totalH = lineH * CGFloat(lines.count)
            if (totalH <= maxH && lines.count <= 3 && !singleTokenOverflow) || fontSize <= 14 { break }
            fontSize *= min(0.92, max(0.5, maxH / totalH * 0.96))
        }
        let lf = latinFont(size: fontSize)
        let cf = jpLine ? jpFont(size: fontSize) : cjkFont(size: fontSize)
        let y0 = size.height * 0.80 - lineH * CGFloat(lines.count)
        // Cache per-line dim/bright runs + a clean strip backup so karaoke
        // coverage redraws never re-run the layout, then leave the actual
        // text drawing to renderCoverage (called right after by update()).
        var layout = TitleLayout()
        layout.lineH = lineH
        layout.origin = CGPoint(x: margin, y: y0)
        let pad = lineH * 0.15
        let stripY = max(0, y0 - pad)
        layout.strip = CGRect(x: 0, y: stripY, width: size.width,
                              height: min(size.height - stripY,
                                          lineH * CGFloat(lines.count) + pad * 2))
        for line in lines {
            func makeRun(fill: NSColor, strokeW: CGFloat, strokeC: NSColor) -> NSMutableAttributedString {
                let astr = NSMutableAttributedString()
                for (i, t) in line.enumerated() {
                    astr.append(NSAttributedString(string: (i > 0 ? t.gapBefore : "") + t.text,
                                                   attributes: [
                                                       .font: t.cjk ? cf : lf,
                                                       .foregroundColor: fill,
                                                       .strokeColor: strokeC,
                                                       .strokeWidth: strokeW,
                                                   ]))
                }
                return astr
            }
            // karaoke glass: translucent dim base (stroke-less); bright
            // stroke-less fill (the glass gradient's alpha mask); stroke-only
            // white rim as the glass edge highlight
            let bright = makeRun(fill: NSColor.white, strokeW: 0, strokeC: NSColor.clear)
            layout.bright.append(bright)
            layout.dim.append(makeRun(fill: NSColor.white.withAlphaComponent(0.42),
                                      strokeW: 0, strokeC: NSColor.clear))
            layout.rim.append(makeRun(fill: NSColor.clear, strokeW: max(1.5, fontSize * 0.02),
                                      strokeC: NSColor.white.withAlphaComponent(0.55)))
            layout.widths.append(bright.size().width)
        }
        titleLayout = layout
        snapshotTitleStrip()

        NSGraphicsContext.restoreGraphicsState()

        snapshotFooter()
        upload(data: data, region: CGRect(x: 0, y: 0, width: w, height: h))
    }

    // MARK: - Karaoke coverage sweep (title strip), redrawn per feed tick

    /// Dims the whole title, then re-draws the sung prefix bright: coverage
    /// maps linearly over the summed line widths, line by line.
    private func renderCoverage(_ cov: Float) {
        guard let ctx, let data = ctxData, let layout = titleLayout, !titleBackup.isEmpty else { return }
        let w = Int(size.width)
        let sy = Int(layout.strip.minY), sh = Int(layout.strip.height)
        titleBackup.withUnsafeBytes { src in
            for row in 0..<sh {
                memcpy(data.advanced(by: (sy + row) * w * 4),
                       src.baseAddress!.advanced(by: row * w * 4), w * 4)
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let totalW = layout.widths.reduce(0, +)
        var covered = CGFloat(cov) * totalW
        var y = layout.origin.y
        for i in 0..<layout.dim.count {
            layout.dim[i].draw(at: CGPoint(x: layout.origin.x, y: y))
            covered -= layout.widths[i]
            y += layout.lineH
        }
        // bright pass: liquid-glass gradient fill + rim, clipped to the sung
        // prefix (clip is plain CG state, so it composes with text drawing)
        covered = CGFloat(cov) * totalW
        y = layout.origin.y
        for i in 0..<layout.bright.count {
            let cw = min(max(covered, 0), layout.widths[i])
            if cw > 0 {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: layout.origin.x, y: y - layout.lineH * 0.08,
                                    width: cw, height: layout.lineH * 1.16))
                drawGlass(layout.bright[i], at: CGPoint(x: layout.origin.x, y: y), in: ctx)
                layout.rim[i].draw(at: CGPoint(x: layout.origin.x, y: y))
                ctx.restoreGState()
            }
            covered -= layout.widths[i]
            y += layout.lineH
        }
        NSGraphicsContext.restoreGraphicsState()
        upload(data: data.advanced(by: sy * w * 4), region: layout.strip)
    }

    // MARK: - Footer (progress bar + timecode), redrawn per feed tick

    private func renderFooter(progress: Float, timecode: String) {
        guard let ctx, let data = ctxData, !footerBackup.isEmpty else { return }
        let w = Int(size.width)
        let sy = Int(footerStrip.minY), sh = Int(footerStrip.height)
        footerBackup.withUnsafeBytes { src in
            for row in 0..<sh {
                memcpy(data.advanced(by: (sy + row) * w * 4),
                       src.baseAddress!.advanced(by: row * w * 4), w * 4)
            }
        }

        let barH = max(4, round(size.height * 0.0045))
        if progress > 0 {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.fill(CGRect(x: 0, y: size.height - barH,
                            width: size.width * CGFloat(progress), height: barH))
            ctx.restoreGState()
        }
        if !timecode.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let font = NSFont.monospacedDigitSystemFont(ofSize: size.width * 0.024, weight: .medium)
            let tcAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.65),
            ]
            let tcSize = (timecode as NSString).size(withAttributes: tcAttrs)
            (timecode as NSString).draw(
                at: CGPoint(x: size.width - size.width * 0.075 - tcSize.width,
                            y: size.height - barH - tcSize.height * 1.5),
                withAttributes: tcAttrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        upload(data: data.advanced(by: sy * w * 4),
               region: CGRect(x: 0, y: sy, width: w, height: sh))
    }

    // MARK: - Footer strip backup / texture upload

    private func snapshotTitleStrip() {
        guard let data = ctxData, let layout = titleLayout else { return }
        let w = Int(size.width)
        let sy = Int(layout.strip.minY), sh = Int(layout.strip.height)
        titleBackup = [UInt8](repeating: 0, count: w * sh * 4)
        titleBackup.withUnsafeMutableBytes { dst in
            for row in 0..<sh {
                memcpy(dst.baseAddress!.advanced(by: row * w * 4),
                       data.advanced(by: (sy + row) * w * 4), w * 4)
            }
        }
    }

    private func snapshotFooter() {
        guard let data = ctxData else { return }
        let w = Int(size.width)
        let sy = Int(footerStrip.minY), sh = Int(footerStrip.height)
        footerBackup.withUnsafeMutableBytes { dst in
            for row in 0..<sh {
                memcpy(dst.baseAddress!.advanced(by: row * w * 4),
                       data.advanced(by: (sy + row) * w * 4), w * 4)
            }
        }
    }

    private func upload(data: UnsafeRawPointer, region: CGRect) {
        guard let texture else { return }
        texture.replace(region: MTLRegionMake2D(Int(region.minX), Int(region.minY),
                                               Int(region.width), Int(region.height)),
                        mipmapLevel: 0, withBytes: data,
                        bytesPerRow: Int(size.width) * 4)
    }

    deinit { if let ctxData { free(ctxData) } }
}
