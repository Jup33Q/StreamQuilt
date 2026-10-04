// M3 spike: full SDXS img2img in pure Swift + CoreML (no Python).
//
//   swiftc -O scripts/coreml_spike.swift -o /tmp/coreml_spike -framework CoreML -framework CoreImage
//   /tmp/coreml_spike /tmp/lkg_spike
//
// Reads: <dir>/input.png, prompt_embeds.npy, fixed_noise.npy, sched.json
// Uses: models/taesd_encoder_384.mlpackage, unet_sdxs_384.mlpackage, taesd_decoder_384.mlpackage
// Writes: <dir>/output.png; prints per-stage timings.

import CoreML
import Foundation
import CoreGraphics
import ImageIO
import AppKit

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/lkg_spike"
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let modelsDir = repoRoot.path + "/models"

// --- npy loader (little-endian fp16) ---
func loadNpyFloat16(_ path: String) -> (MLMultiArray, [Int]) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    precondition(data[0] == 0x93 && data[1] == 0x4E, "bad npy magic")
    let hlen = Int(data[8]) | Int(data[9]) << 8
    let header = String(data: data[10..<10 + hlen], encoding: .utf8)!
    let shapePart = header.components(separatedBy: "'shape':")[1]
    let dims = shapePart.components(separatedBy: "(")[1].components(separatedBy: ")")[0]
        .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let shape = dims.map { NSNumber(value: $0) }
    let arr = try! MLMultiArray(shape: shape, dataType: .float16)
    let body = data.subdata(in: (10 + hlen)..<data.count)
    body.withUnsafeBytes { src in
        memcpy(arr.dataPointer, src.baseAddress!, src.count)
    }
    return (arr, dims)
}

func ms(_ t: CFAbsoluteTime) -> String { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t) * 1000) }

// --- load input image -> (1,3,S,S) fp16 in [-1,1] ---
func loadImage(_ path: String, size: Int) -> MLMultiArray {
    let img = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &rgba, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let arr = try! MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float16)
    let ptr = arr.dataPointer.assumingMemoryBound(to: Float16.self)
    for c in 0..<3 {
        for y in 0..<size {
            for x in 0..<size {
                let px = rgba[(y * size + x) * 4 + c]
                ptr[c * size * size + y * size + x] = Float16(Float(px) / 127.5 - 1.0)
            }
        }
    }
    return arr
}

let sched = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: dir + "/sched.json"))) as! [String: Any]
let renderSize = (sched["render_size"] as! Int)
let latentSize = (sched["latent_size"] as! Int)
let sqrtA = Float16(sched["sqrt_a"] as! Double)
let sqrt1ma = Float16(sched["sqrt_1ma"] as! Double)
let timestepVal = Float16(sched["timestep"] as! Double)

let cfg = MLModelConfiguration()
cfg.computeUnits = .cpuAndGPU

// Swift CoreML needs compiled (.mlmodelc) bundles; compile once and cache.
func compiledModel(_ name: String) throws -> MLModel {
    let pkg = URL(fileURLWithPath: modelsDir + "/\(name).mlpackage")
    let compiledDir = URL(fileURLWithPath: modelsDir + "/compiled")
    try? FileManager.default.createDirectory(at: compiledDir, withIntermediateDirectories: true)
    let dst = compiledDir.appendingPathComponent("\(name).mlmodelc")
    if !FileManager.default.fileExists(atPath: dst.path) {
        let tmp = try MLModel.compileModel(at: pkg)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }
    return try MLModel(contentsOf: dst, configuration: cfg)
}

print("loading CoreML models ...")
var t = CFAbsoluteTimeGetCurrent()
let vaeEnc = try! compiledModel("taesd_encoder_384")
let unet = try! compiledModel("unet_sdxs_384")
let vaeDec = try! compiledModel("taesd_decoder_384")
print("  load: \(ms(t)) ms")

let image = loadImage(dir + "/input.png", size: renderSize)
if true {
    let p = image.dataPointer.assumingMemoryBound(to: Float16.self)
    var s: Float = 0
    for i in 0..<image.count { s += Float(p[i]) }
    print(String(format: "swift input buf sum %.3f (python: 49664.000)", s))
}
let (embeds, _) = loadNpyFloat16(dir + "/prompt_embeds.npy")
let (noise, _) = loadNpyFloat16(dir + "/fixed_noise.npy")
if true {
    func fsum(_ a: MLMultiArray) -> Float {
        let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
        var s: Float = 0
        for i in 0..<a.count { s += Float(p[i]) }
        return s
    }
    print(String(format: "swift noise sum %.3f (py -1.227) | embeds sum %.1f (py -13064.0)",
                 fsum(noise), fsum(embeds)))
}
let timestep = try! MLMultiArray(shape: [1], dataType: .float16)
timestep.dataPointer.assumingMemoryBound(to: Float16.self)[0] = timestepVal

func predict(_ model: MLModel, _ inputs: [String: MLMultiArray]) throws -> MLMultiArray {
    let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
    let out = try model.prediction(from: provider)
    return out.featureValue(for: out.featureNames.first!)!.multiArrayValue!
}

// warmup
_ = try! predict(vaeDec, ["latent": noise])

let iterations = 20
var tEnc = 0.0, tUnet = 0.0, tDec = 0.0, tAll = CFAbsoluteTimeGetCurrent()
var output: MLMultiArray = noise
var savedOutput = [Float](repeating: 0, count: renderSize * renderSize * 3)
for iter in 0..<iterations {
    t = CFAbsoluteTimeGetCurrent()
    let clean = try! predict(vaeEnc, ["image": image])
    tEnc += CFAbsoluteTimeGetCurrent() - t

    // noisy = sqrt_a * clean + sqrt_1ma * noise
    let n = latentSize * latentSize * 4
    let noisy = try! MLMultiArray(shape: [1, 4, NSNumber(value: latentSize), NSNumber(value: latentSize)], dataType: .float16)
    let cp = clean.dataPointer.assumingMemoryBound(to: Float16.self)
    let np_ = noise.dataPointer.assumingMemoryBound(to: Float16.self)
    let zp = noisy.dataPointer.assumingMemoryBound(to: Float16.self)
    for i in 0..<n { zp[i] = sqrtA * cp[i] + sqrt1ma * np_[i] }
    if iter == 0 {
        let p = zp
        print("sw noisy[:6]", (0..<6).map { String(format: "%.4f", Float(p[$0])) }.joined(separator: " "))
    }

    t = CFAbsoluteTimeGetCurrent()
    let npred = try! predict(unet, ["sample": noisy, "timestep": timestep, "encoder_hidden_states": embeds])
    tUnet += CFAbsoluteTimeGetCurrent() - t

    // denoised = (noisy - sqrt_1ma * npred) / sqrt_a
    let pp = npred.dataPointer.assumingMemoryBound(to: Float16.self)
    for i in 0..<n { zp[i] = (zp[i] - sqrt1ma * pp[i]) / sqrtA }

    t = CFAbsoluteTimeGetCurrent()
    output = try! predict(vaeDec, ["latent": noisy])
    tDec += CFAbsoluteTimeGetCurrent() - t

    if iter == 0 {
        // copy out immediately: prediction result buffers may be pool-reused
        // by later predictions — read now or the final PNG is garbage.
        let n2 = renderSize * renderSize * 3
        let op = output.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in 0..<n2 { savedOutput[i] = Float(op[i]) }
        func sum(_ a: MLMultiArray) -> Float {
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            var s: Float = 0
            for i in 0..<(a.count) { s += Float(p[i]) }
            return s
        }
        func head6(_ a: MLMultiArray) -> String {
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            return (0..<6).map { String(format: "%.4f", Float(p[$0])) }.joined(separator: " ")
        }
        print(String(format: "clean sum %.3f | npred sum %.3f | decoded sum %.1f",
                     sum(clean), sum(npred), sum(output)))
        print("sw npred[:6]", head6(npred))
    }
}
let total = CFAbsoluteTimeGetCurrent() - tAll
print(String(format: "per img: vaeEnc %.1f ms | unet %.1f ms | vaeDec %.1f ms | total %.1f ms -> %.1f img/s",
             tEnc / Double(iterations) * 1000, tUnet / Double(iterations) * 1000,
             tDec / Double(iterations) * 1000, total / Double(iterations) * 1000,
             Double(iterations) / total))

// save output.png from the iter-0 snapshot
var px = [UInt8](repeating: 0, count: renderSize * renderSize * 4)
for y in 0..<renderSize {
    for x in 0..<renderSize {
        for c in 0..<3 {
            let v = (savedOutput[c * renderSize * renderSize + y * renderSize + x] + 1) * 127.5
            px[(y * renderSize + x) * 4 + c] = UInt8(min(255, max(0, v)))
        }
    }
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: renderSize, height: renderSize, bitsPerComponent: 8,
                    bytesPerRow: renderSize * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/output.png") as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("saved \(dir)/output.png")
