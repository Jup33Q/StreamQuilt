import LKGQuilt
import Metal
import simd

/// Demo scene: shadertoy-style raymarched block city, one fullscreen triangle
/// per frame; the fragment shader resolves its quilt tile via LKGShaderCommon
/// and raymarches a pulsing neon block field with an orbiting glow cube.
final class BlockCityScene {
    // camera (tweakable at runtime)
    var sweep: Float = 2.5
    var fovY: Float = 25 * .pi / 180
    var dist: Float = 13.0
    var camH: Float = 3.2
    var pitch: Float = 0.20
    var flip: Float = 1.0

    private let pso: MTLRenderPipelineState
    private let spec: QuiltSpec
    private let renderer: QuiltRenderer

    struct SceneParams {
        var tileSize: SIMD2<Float>
        var cols: Float
        var rows: Float
        var time: Float
        var size: Float
        var flip: Float
        var dist: Float
        var camH: Float
        var fovTan: Float
        var pitch: Float
        var aspect: Float
    }

    init(renderer: QuiltRenderer) throws {
        self.renderer = renderer
        spec = renderer.spec
        let source = LKGShaderCommon.msl + Self.sceneMSL
        let lib = try renderer.device.makeLibrary(source: source, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sceneVS")
        d.fragmentFunction = lib.makeFunction(name: "sceneFS")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        pso = try renderer.device.makeRenderPipelineState(descriptor: d)
    }

    func encodeQuilt(cmd: MTLCommandBuffer, pass: MTLRenderPassDescriptor, time: Float) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass),
              let target = renderer.quiltTexture else { return }
        enc.setRenderPipelineState(pso)
        var p = SceneParams(
            tileSize: SIMD2(Float(target.width) / Float(spec.columns),
                            Float(target.height) / Float(spec.rows)),
            cols: Float(spec.columns), rows: Float(spec.rows),
            time: time, size: sweep, flip: flip, dist: dist, camH: camH,
            fovTan: tan(fovY / 2), pitch: pitch, aspect: spec.tileAspect)
        enc.setFragmentBytes(&p, length: MemoryLayout<SceneParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    var statusLine: String {
        String(format: "size %.1f fov %.0f dist %.0f%@", sweep, fovY * 180 / .pi, dist,
               flip < 0 ? " flipped" : "")
    }

    /// Returns true if the key was consumed.
    func handleKey(_ key: String) -> Bool {
        switch key {
        case "f": flip *= -1
        case "-": sweep = max(0.2, sweep - 0.2)
        case "=", "+": sweep += 0.2
        case "[": dist = max(4, dist - 1)
        case "]": dist += 1
        case "9": fovY = max(8 * .pi / 180, fovY - 2 * .pi / 180)
        case "0": fovY = min(50 * .pi / 180, fovY + 2 * .pi / 180)
        default: return false
        }
        return true
    }

    private static let sceneMSL = """
    struct SceneParams {
        float2 tileSize;
        float cols, rows, time, size, flip, dist, camH, fovTan, pitch, aspect;
    };

    vertex float4 sceneVS(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float hash21(float2 p) {
        p = fract(p * float2(234.34, 435.345));
        p += dot(p, p + 34.23);
        return fract(p.x * p.y);
    }

    static float3 hsv2rgb(float h, float s, float v) {
        float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
        float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
        return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
    }

    static float sdBox(float3 p, float3 b) {
        float3 q = abs(p) - b;
        return length(max(q, float3(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
    }

    // returns (dist, materialId)
    static float2 map(float3 p, float t) {
        float2 res = float2(p.y, 0.0); // ground plane

        float c = 2.2;
        float2 id = floor(p.xz / c);
        float2 r = (fract(p.xz / c) - 0.5) * c;
        float2 idw = id - floor(id / 64.0) * 64.0;
        float h0 = hash21(idw);
        float wave = sin(t * 1.6 - length(id) * 0.55 + h0 * 6.2831) * 0.5 + 0.5;
        float h = (0.25 + 2.6 * h0) * (0.55 + 0.45 * wave);
        float dB = sdBox(float3(r.x, p.y - h * 0.5, r.y), float3(0.55, h * 0.5, 0.55)) - 0.04;
        if (dB < res.x) res = float2(dB, 1.0 + h0);

        // orbiting glow cube
        float a = t * 0.6;
        float3 q2 = p - float3(cos(a) * 3.4, 2.4 + sin(t * 0.9) * 0.6, sin(a) * 3.4 - 1.5);
        float cr = cos(t * 0.8), sr = sin(t * 0.8);
        q2 = float3(q2.x * cr - q2.z * sr, q2.y, q2.x * sr + q2.z * cr);
        float cq = cos(t * 0.5), sq = sin(t * 0.5);
        q2 = float3(q2.x, q2.y * cq - q2.z * sq, q2.y * sq + q2.z * cq);
        float dC = sdBox(q2, float3(0.5)) - 0.05;
        if (dC < res.x) res = float2(dC, 3.0);

        return res;
    }

    static float3 palette(float m, float t) {
        if (m > 2.5) return float3(1.0, 0.55, 0.15);
        if (m > 0.5) return hsv2rgb(fract(m * 0.618 + t * 0.02), 0.75, 1.0);
        return float3(0.15, 0.2, 0.3);
    }

    static float3 calcNormal(float3 p, float t) {
        float2 e = float2(0.0015, -0.0015);
        return normalize(e.xyy * map(p + e.xyy, t).x +
                         e.yyx * map(p + e.yyx, t).x +
                         e.yxy * map(p + e.yxy, t).x +
                         e.xxx * map(p + e.xxx, t).x);
    }

    fragment float4 sceneFS(float4 fpos [[position]], constant SceneParams& P [[buffer(0)]]) {
        LKGTileInfo ti = lkgTileInfo(fpos.xy, P.tileSize, P.cols, P.rows);
        float off = lkgViewOffset(ti.viewT, P.size, P.flip);

        float3 ro  = float3(off, P.camH, P.dist);
        float3 dir = lkgViewRay(ti, off, P.dist, P.fovTan, P.aspect, P.pitch);

        float tRay = 0.0;
        float m = -1.0;
        float3 glow = float3(0.0);
        for (int i = 0; i < 90; i++) {
            float3 p = ro + dir * tRay;
            float2 dm = map(p, P.time);
            glow += palette(dm.y, P.time) * exp(-max(dm.x, 0.0) * 9.0) * 0.005;
            if (dm.x < 0.0012 * tRay + 0.0006) { m = dm.y; break; }
            tRay += dm.x * 0.9;
            if (tRay > 80.0) break;
        }

        float3 sky = mix(float3(0.02, 0.03, 0.07), float3(0.05, 0.10, 0.22), pow(max(dir.y, 0.0), 0.6));
        sky += float3(0.10, 0.20, 0.50) * pow(max(1.0 - abs(dir.y), 0.0), 6.0) * 0.35;

        float3 colOut;
        if (m < -0.5) {
            colOut = sky;
        } else {
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, P.time);
            float3 base = palette(m, P.time);
            if (m < 0.5) { // ground: neon grid
                float2 g = abs(fract(p.xz / 2.2) - 0.5);
                float line = smoothstep(0.465, 0.5, max(g.x, g.y));
                base = float3(0.02, 0.03, 0.06) + float3(0.0, 0.45, 0.9) * line * 0.8;
            }
            float3 L = normalize(float3(0.5, 0.8, 0.35));
            float dif = max(dot(n, L), 0.0);
            float3 V = -dir;
            float spec = pow(max(dot(reflect(-L, n), V), 0.0), 32.0);
            float fre = pow(1.0 - max(dot(n, V), 0.0), 4.0);
            colOut = base * (0.25 + 0.85 * dif) + spec * 0.35 + fre * base * 0.6;
            if (m > 2.5) colOut += base * 1.5;                                 // flyer emissive
            if (m > 0.5 && m < 2.5) colOut += base * smoothstep(0.9, 1.0, n.y) * 0.7;
            float fog = 1.0 - exp(-0.0016 * tRay * tRay);
            colOut = mix(colOut, sky, fog);
        }
        colOut += glow;

        colOut *= 1.0 - 0.12 * dot(ti.tileNDC, ti.tileNDC);
        return float4(colOut, 1.0);
    }
    """
}
