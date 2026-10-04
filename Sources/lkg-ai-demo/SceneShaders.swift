import Foundation

/// Metal source for AIBlockCityScene. Prepended with LKGShaderCommon.msl at
/// pipeline creation, which provides lkgTileInfo / lkgViewOffset / lkgViewRay.
extension AIBlockCityScene {
    static let sceneMSL = """
    struct AIBaseParams {
        float2 tileSize;
        float4 audio;   // bass, mid, treble, beat (AudioAnalyzer)
        float cols, rows, time, size, flip, dist, camH, fovTan, pitch, aspect;
    };

    struct AIViewParams {
        float4 audio;
        float time, viewT, size, flip, dist, camH, fovTan, pitch, renderSize;
    };

    vertex float4 aiSceneVS(uint vid [[vertex_id]]) {
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

    static float2 map(float3 p, float t, float4 audio) {
        float2 res = float2(p.y, 0.0);
        float c = 2.2;
        float2 id = floor(p.xz / c);
        float2 r = (fract(p.xz / c) - 0.5) * c;
        float2 idw = id - floor(id / 64.0) * 64.0;
        float h0 = hash21(idw);
        float wave = sin(t * 1.6 - length(id) * 0.55 + h0 * 6.2831) * 0.5 + 0.5;
        // bass pumps block heights, treble sharpens the pulse
        float pump = 0.65 + audio.x * 1.4;
        float h = (0.25 + 2.6 * h0) * (0.55 + 0.45 * wave) * pump;
        float dB = sdBox(float3(r.x, p.y - h * 0.5, r.y), float3(0.55, h * 0.5, 0.55)) - 0.04;
        if (dB < res.x) res = float2(dB, 1.0 + h0);

        // beat makes the orbit cube jump
        float jump = audio.w * 1.2;
        float a = t * 0.6;
        float3 q2 = p - float3(cos(a) * 3.4, 2.4 + sin(t * 0.9) * 0.6 + jump, sin(a) * 3.4 - 1.5);
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

    static float3 calcNormal(float3 p, float t, float4 audio) {
        float2 e = float2(0.0015, -0.0015);
        return normalize(e.xyy * map(p + e.xyy, t, audio).x +
                         e.yyx * map(p + e.yyx, t, audio).x +
                         e.yxy * map(p + e.yxy, t, audio).x +
                         e.xxx * map(p + e.xxx, t, audio).x);
    }

    static float3 aces(float3 c) {
        c = clamp(c, 0.0, 16.0);
        c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
        return pow(c, float3(1.0 / 2.2));
    }

    static float3 shadeScene(float3 ro, float3 dir, float2 ndc, float time, float4 audio) {
        float tRay = 0.0;
        float m = -1.0;
        float3 glow = float3(0.0);
        for (int i = 0; i < 90; i++) {
            float3 p = ro + dir * tRay;
            float2 dm = map(p, time, audio);
            // beat flash amplifies near-miss glow
            glow += palette(dm.y, time) * exp(-max(dm.x, 0.0) * 9.0) * 0.005 * (1.0 + audio.w * 2.5);
            if (dm.x < 0.0012 * tRay + 0.0006) { m = dm.y; break; }
            tRay += dm.x * 0.9;
            if (tRay > 80.0) break;
        }

        float3 sky = mix(float3(0.02, 0.03, 0.07), float3(0.05, 0.10, 0.22), pow(max(dir.y, 0.0), 0.6));
        sky += float3(0.10, 0.20, 0.50) * pow(max(1.0 - abs(dir.y), 0.0), 6.0) * 0.35;
        sky *= 1.0 + audio.w * 0.6; // beat sky pulse

        float3 colOut;
        if (m < -0.5) {
            colOut = sky;
        } else {
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio);
            float3 base = palette(m, time + audio.z * 3.0); // treble shifts palette
            if (m < 0.5) {
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
            if (m > 2.5) colOut += base * 1.5;
            if (m > 0.5 && m < 2.5) colOut += base * smoothstep(0.9, 1.0, n.y) * 0.7;
            float fog = 1.0 - exp(-0.0016 * tRay * tRay);
            colOut = mix(colOut, sky, fog);
        }
        colOut += glow;
        colOut *= 1.0 - 0.12 * dot(ndc, ndc);
        return colOut;
    }

    // Full-quilt HDR base layer (tile math via LKGShaderCommon).
    fragment float4 aiBaseFS(float4 fpos [[position]], constant AIBaseParams& P [[buffer(0)]]) {
        LKGTileInfo ti = lkgTileInfo(fpos.xy, P.tileSize, P.cols, P.rows);
        float off = lkgViewOffset(ti.viewT, P.size, P.flip);
        float3 ro = float3(off, P.camH, P.dist);
        float3 dir = lkgViewRay(ti, off, P.dist, P.fovTan, P.aspect, P.pitch);
        return float4(shadeScene(ro, dir, ti.tileNDC, P.time, P.audio), 1.0);
    }

    // Single-view LDR render (square staging) as diffusion img2img input.
    // Horizontal fov matches vertical (square); the quilt composite center-crops
    // to the portrait tile aspect.
    fragment float4 aiViewFS(float4 fpos [[position]], constant AIViewParams& P [[buffer(0)]]) {
        float2 uv = float2(fpos.x / P.renderSize, 1.0 - fpos.y / P.renderSize);
        float2 ndc = uv * 2.0 - 1.0;
        float off = lkgViewOffset(P.viewT, P.size, P.flip);
        float3 ro = float3(off, P.camH, P.dist);
        float3 dir = normalize(float3(ndc.x * P.fovTan, ndc.y * P.fovTan, -1.0));
        float cp = cos(P.pitch), sp = sin(P.pitch);
        dir = float3(dir.x, dir.y * cp + dir.z * sp, -dir.y * sp + dir.z * cp);
        return float4(aces(shadeScene(ro, dir, ndc, P.time, P.audio)), 1.0);
    }
    """
}
