// Render the LKG Studio app icon: dark rounded square, diagonal lenticular
// stripe field (cyan->magenta->amber), glass pane parallelogram + gloss.
// Usage: swift scripts/render_icon.swift <out.png> [size]
import CoreGraphics
import ImageIO
import Foundation

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "AppIcon.png"
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let S = CGFloat(size)

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no ctx") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// MARK: rounded-square clip (macOS icon grid radius)
let radius = S * 0.2237
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// MARK: background — deep navy -> violet diagonal
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(0.16, 0.05, 0.34), rgb(0.03, 0.05, 0.16)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: S, y: S), end: CGPoint(x: 0, y: 0), options: [])

// MARK: lenticular stripe field — slanted bars, hue sweeps cyan->magenta->amber
ctx.saveGState()
ctx.translateBy(x: S / 2, y: S / 2)
ctx.rotate(by: -.pi / 10)            // -18°
let period = S * 0.075               // stripe pitch
let barW = period * 0.62
// palette stops by x position across the (generous) rotated field
func stripeColor(_ t: CGFloat) -> CGColor {
    // t in 0...1: cyan -> magenta -> amber
    let c0 = (r: CGFloat(0.10), g: CGFloat(0.85), b: CGFloat(1.00))
    let c1 = (r: CGFloat(1.00), g: CGFloat(0.20), b: CGFloat(0.80))
    let c2 = (r: CGFloat(1.00), g: CGFloat(0.75), b: CGFloat(0.25))
    if t < 0.5 {
        let u = t * 2
        return rgb(c0.r + (c1.r - c0.r) * u, c0.g + (c1.g - c0.g) * u, c0.b + (c1.b - c0.b) * u, 0.92)
    }
    let u = (t - 0.5) * 2
    return rgb(c1.r + (c2.r - c1.r) * u, c1.g + (c2.g - c1.g) * u, c1.b + (c2.b - c1.b) * u, 0.92)
}
let span = S * 1.6
let n = Int(span / period) + 2
for i in 0..<n {
    let x = -span / 2 + CGFloat(i) * period
    let t = CGFloat(i) / CGFloat(max(n - 1, 1))
    ctx.setFillColor(stripeColor(t))
    // slight per-bar vertical wobble for a light-field shimmer
    let wob = sin(CGFloat(i) * 1.7) * S * 0.01
    ctx.fill(CGRect(x: x, y: -span / 2 + wob, width: barW, height: span))
}
ctx.restoreGState()

// darken stripes toward edges so the pane pops
let shade = CGGradient(colorsSpace: cs,
                       colors: [rgb(0, 0, 0, 0.34), rgb(0, 0, 0, 0.0),
                                rgb(0, 0, 0, 0.0), rgb(0, 0, 0, 0.34)] as CFArray,
                       locations: [0, 0.35, 0.65, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// MARK: glass pane — off-axis parallelogram ("looking glass" sheet)
let pane = CGMutablePath()
let px = S * 0.22, py = S * 0.20, pw = S * 0.56, ph = S * 0.60, skew = S * 0.10
pane.move(to: CGPoint(x: px + skew, y: py + ph))        // top-left (skewed)
pane.addLine(to: CGPoint(x: px + pw + skew, y: py + ph))// top-right
pane.addLine(to: CGPoint(x: px + pw, y: py))            // bottom-right
pane.addLine(to: CGPoint(x: px, y: py))                 // bottom-left
pane.closeSubpath()

ctx.saveGState()
ctx.addPath(pane)
ctx.clip()
// glass fill: faint white + diagonal gloss streak
ctx.setFillColor(rgb(1, 1, 1, 0.16))
ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
let gloss = CGGradient(colorsSpace: cs,
                       colors: [rgb(1, 1, 1, 0.0), rgb(1, 1, 1, 0.42), rgb(1, 1, 1, 0.0)] as CFArray,
                       locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gloss,
                       start: CGPoint(x: px, y: py + ph * 0.15),
                       end: CGPoint(x: px + pw * 0.75, y: py + ph * 0.95),
                       options: [])
ctx.restoreGState()

// pane edge: bright rim, stronger on top-left (key light)
ctx.addPath(pane)
ctx.setStrokeColor(rgb(1, 1, 1, 0.85))
ctx.setLineWidth(S * 0.012)
ctx.strokePath()
let rim = CGMutablePath()
rim.move(to: CGPoint(x: px, y: py))
rim.addLine(to: CGPoint(x: px + skew, y: py + ph))
rim.addLine(to: CGPoint(x: px + pw + skew, y: py + ph))
ctx.addPath(rim)
ctx.setStrokeColor(rgb(0.55, 0.95, 1.0, 0.95))
ctx.setLineWidth(S * 0.02)
ctx.setLineCap(.round)
ctx.strokePath()

// MARK: write PNG
guard let img = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)
else { fatalError("no dest") }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed") }
print("wrote \(outPath) (\(size)x\(size))")
