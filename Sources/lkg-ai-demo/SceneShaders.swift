import Foundation

/// Metal source for AIBlockCityScene. Prepended with LKGShaderCommon.msl at
/// pipeline creation, which provides lkgTileInfo / lkgViewOffset / lkgViewRay.
///
/// Scene v2: synthwave terrain (valley corridor + sunset sun + stars).
/// Audio channels drive independent parameters:
///   bass   -> terrain amplitude + sun size
///   mid    -> camera sway + terrain drift speed
///   treble -> star density/twinkle
///   beat   -> sun flash + expanding shockwave ring on the terrain
extension AIBlockCityScene {
    static let sceneMSL = """
    struct AIBaseParams {
        float2 tileSize;
        float4 audio;   // bass, mid, treble, beat
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

    static float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i), b = hash21(i + float2(1, 0));
        float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    static float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 3; i++) {
            v += a * vnoise(p);
            p = p * 2.1 + float2(17.3, 9.1);
            a *= 0.5;
        }
        return v;
    }

    static float terrainH(float2 xz, float t, float4 audio) {
        float amp = 0.9 + audio.x * 2.4;                    // bass pumps terrain
        float h = fbm(xz * 0.16 + float2(0.0, t * (0.25 + audio.y * 0.6))) * amp;
        h += sin(xz.x * 0.35) * 0.22;
        h *= smoothstep(0.0, 3.0, abs(xz.x));               // central valley corridor
        return h;
    }

    // returns (dist, materialId): 0 = terrain, 2 = sun
    static float2 map(float3 p, float t, float4 audio) {
        float2 res = float2((p.y - terrainH(p.xz, t, audio)) * 0.55, 0.0);
        float sunR = 2.1 * (1.0 + audio.x * 0.22 + audio.w * 0.10);
        float dSun = length(p - float3(0.0, 6.0, -24.0)) - sunR;
        if (dSun < res.x) res = float2(dSun, 2.0);
        return res;
    }

    static float3 calcNormal(float3 p, float t, float4 audio) {
        float2 e = float2(0.002, -0.002);
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
        // mid -> gentle camera sway, beat -> small bob
        ro.x += sin(time * 0.5) * 0.5 * audio.y;
        ro.y += audio.w * 0.15;

        float tRay = 0.0;
        float m = -1.0;
        for (int i = 0; i < 110; i++) {
            float3 p = ro + dir * tRay;
            float2 dm = map(p, time, audio);
            if (dm.x < 0.0015 * tRay + 0.001) { m = dm.y; break; }
            tRay += dm.x * 0.95;
            if (tRay > 70.0) break;
        }

        // sunset sky + stars
        float horiz = pow(max(1.0 - abs(dir.y), 0.0), 7.0);
        float3 sky = mix(float3(0.03, 0.015, 0.10), float3(0.32, 0.10, 0.30), horiz);
        sky += float3(1.0, 0.45, 0.25) * pow(max(1.0 - abs(dir.y + 0.02), 0.0), 18.0) * 0.55;
        if (dir.y > 0.04) {
            float2 sp = dir.xz / max(dir.y, 0.05);
            float2 cell = floor(sp * 36.0);
            float h = hash21(cell);
            float tw = 0.5 + 0.5 * sin(time * (1.5 + h * 5.0) + h * 40.0);
            float star = step(0.9965 - audio.z * 0.003, h); // treble adds stars
            sky += star * tw * (0.35 + audio.z * 0.9) * float3(0.8, 0.9, 1.0);
        }
        sky *= 1.0 + audio.w * 0.5;                          // beat sky flash

        float3 colOut;
        if (m < -0.5) {
            colOut = sky;
        } else if (m > 1.5) {
            // synthwave sun: hot gradient + scanline gaps widening toward bottom
            float3 p = ro + dir * tRay;
            float yy = (p.y - 6.0) / 2.1;                   // -1..1 over the disc
            float3 sun = mix(float3(1.0, 0.15, 0.55), float3(1.0, 0.9, 0.35),
                             clamp(yy * 0.5 + 0.5, 0.0, 1.0));
            float gap = clamp(0.5 - yy * 0.5, 0.05, 1.0);   // wider gaps lower
            float stripe = smoothstep(gap, gap + 0.06, fract(p.y * 1.6 - time * 0.25));
            colOut = sun * (0.35 + 1.3 * stripe) * (1.8 + audio.w * 1.6);
        } else {
            // terrain: dark violet body + neon grid + beat shockwave ring
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio);
            float h01 = clamp(p.y / 2.2, 0.0, 1.0);
            float3 base = mix(float3(0.03, 0.02, 0.09), float3(0.16, 0.05, 0.28), h01);

            float2 g = abs(fract(p.xz / 1.5) - 0.5);
            float line = smoothstep(0.455, 0.5, max(g.x, g.y));
            float3 gridCol = mix(float3(0.0, 0.9, 1.0), float3(1.0, 0.2, 0.75),
                                 0.5 + 0.5 * sin(time * 0.3 + p.x * 0.2));

            // shockwave ring expands as the beat pulse decays
            float ringR = (1.0 - audio.w) * 9.0;
            float ring = exp(-abs(length(p.xz) - ringR) * 2.2) * audio.w;

            float3 L = normalize(float3(0.0, 0.5, -0.8));   // key light from the sun
            float dif = max(dot(n, L), 0.0);
            colOut = base * (0.3 + 0.9 * dif)
                   + gridCol * line * (0.9 + audio.x * 0.8)
                   + float3(1.0, 0.35, 0.7) * ring * 1.6;
            float fog = 1.0 - exp(-0.0009 * tRay * tRay);
            colOut = mix(colOut, sky, fog);
        }

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
