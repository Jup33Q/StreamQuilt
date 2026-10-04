import Foundation

/// Metal source for AIBlockCityScene. Prepended with LKGShaderCommon.msl at
/// pipeline creation, which provides lkgTileInfo / lkgViewOffset / lkgViewRay.
///
/// Scene v3: synthwave valley + audio-reactive CLASHING palette + floating
/// mandelbox crystal + animated voronoi terrain veins + ember particles
/// + equalizer columns (hashed cells flanking the corridor, each pillar's
/// height rides the bass/mid/treble band its hash selects).
/// Audio channels drive independent parameters:
///   bass   -> terrain amplitude + sun size + voronoi vein brightness
///   mid    -> camera sway + terrain drift + crystal tumble + palette swing
///   treble -> star density/twinkle + ember brightness + palette swing
///   beat   -> sun flash + shockwave ring + crystal breath + ember jump
///             + hue kick / saturation snap (撞色: complementary pairs orbit
///             the hue wheel together, per-element multipliers add clash)
/// Composition notes (fov 25°, ndc half-width 0.22): crystal hovers just
/// behind the focus plane at (2.2, 4.8, -8) — angular radius ~4.3° ≈ 1/3 of
/// the half-frame; shell stepping never clips the fractal (shell 2.0 > extent
/// ~1.6). Columns live in the z ∈ [-18, 8] band around the focus plane.
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

    /// Animated voronoi: returns (F1, F2-F1, cellHash). Cell points wander over time.
    static float3 voronoi(float2 x, float t) {
        float2 n = floor(x), f = fract(x);
        float f1 = 8.0, f2 = 8.0;
        float id = 0.0;
        for (int j = -1; j <= 1; j++)
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float cid = hash21(n + g + 7.77);
            float2 o = float2(hash21(n + g), hash21(n + g + 19.19));
            o = 0.5 + 0.42 * sin(t * 0.6 + 6.2831 * o);   // wandering cell points
            float d = dot(g + o - f, g + o - f);
            if (d < f1) { f2 = f1; f1 = d; id = cid; } else if (d < f2) { f2 = d; }
        }
        return float3(sqrt(f1), sqrt(f2) - sqrt(f1), id);
    }

    /// Vein/crack color: per-cell rainbow hues (0.55 spread) keep palette
    /// richness while the global palette swings with the music.
    static float3 veinColorAt(float hueShift, float cellHash) {
        return hsv2rgb(fract(0.50 + hueShift * 0.9 + cellHash * 0.55), 0.85, 1.0);
    }

    /// Mandelbox-lite DE (4 folds); beat breathes the fold scale.
    /// Only evaluated inside the crystal's bounding shell (see map()).
    static float crystalDE(float3 p, float t, float4 audio) {
        float ang = t * (0.15 + audio.y * 0.35);            // mid spins the tumble
        float ca = cos(ang), sa = sin(ang);
        p.xz = float2(p.x * ca - p.z * sa, p.x * sa + p.z * ca);
        float3 z = p;
        float dr = 1.0;
        float scale = 1.9 + audio.w * 0.25;                 // beat breath
        for (int i = 0; i < 4; i++) {
            z = clamp(z, -1.0, 1.0) * 2.0 - z;              // box fold
            float r2 = max(dot(z, z), 0.30);
            float k = scale / r2;                           // sphere fold
            z = z * k + p;
            dr = dr * k + 1.0;
        }
        return (length(z) / dr - 0.02) * 0.45;
    }

    static float terrainH(float2 xz, float t, float4 audio) {
        float amp = 0.9 + audio.x * 2.4;                    // bass pumps terrain
        float h = fbm(xz * 0.16 + float2(0.0, t * (0.25 + audio.y * 0.6))) * amp;
        h += sin(xz.x * 0.35) * 0.22;
        h *= smoothstep(0.0, 3.0, abs(xz.x));               // central valley corridor
        return h;
    }

    /// Crystal floats just behind the focus plane (z=0) so the 3D pop reads
    /// on the panel; right-offset to share the sky with the sun.
    static float3 crystalCenter(float t, float4 audio) {
        return float3(2.2, 4.8 + 0.3 * sin(t * 0.7) + audio.w * 0.3, -8.0);
    }

    /// Column field flanking the corridor, band-limited around the focus
    /// plane (z=0) so the pillars sit at readable 3D depth: hashed cells, each
    /// column bound to bass/mid/treble by hash -> equalizer-pillar forest.
    /// Returns (capped-cylinder dist, cellHash, bandValue, topY).
    static float4 columnField(float3 p, float t, float4 audio) {
        if (abs(p.x) < 2.4 || p.y > 12.0 || p.z < -18.0 || p.z > 8.0) {
            return float4(1e5, 0.0, 0.0, 0.0);
        }
        float2 cell = floor(p.xz / 3.2);
        float hc = hash21(cell * 1.31 + 4.7);
        if (hc < 0.35) { return float4(1e5, 0.0, 0.0, 0.0); }
        float2 cc = (cell + 0.5) * 3.2
                  + float2(hash21(cell + 3.1), hash21(cell + 5.7)) * 1.4 - 0.7;
        float band = hc < 0.55 ? audio.x : (hc < 0.75 ? audio.y : audio.z);
        float hgt = 0.8 + hc * 3.0 + band * (1.5 + hc * 3.5);
        float top = terrainH(cc, t, audio) + hgt;
        float d = max(length(p.xz - cc) - 0.5, p.y - top);
        return float4(d, hc, band, top);
    }

    // returns (dist, materialId): 0 = terrain, 2 = sun, 3 = crystal, 4 = column
    static float2 map(float3 p, float t, float4 audio) {
        float2 res = float2((p.y - terrainH(p.xz, t, audio)) * 0.55, 0.0);
        float sunR = 2.1 * (1.0 + audio.x * 0.22 + audio.w * 0.10);
        float dSun = length(p - float3(0.0, 6.0, -24.0)) - sunR;
        if (dSun < res.x) res = float2(dSun, 2.0);
        // equalizer columns (single nearest cell — radius < half spacing)
        float4 col = columnField(p, t, audio);
        if (col.x < res.x) res = float2(col.x, 4.0);
        // crystal: shell radius (2.0) comfortably exceeds the fractal extent
        // (/1.2 local scale -> ~1.6 world), so no clipping flat cap; outside
        // the shell the sphere distance is only a conservative step.
        float3 C = crystalCenter(t, audio);
        float dB = length(p - C) - 2.0;
        if (dB < 0.3) {
            float dF = crystalDE((p - C) / 1.2, t, audio) * 1.2;
            if (dF < res.x) res = float2(dF, 3.0);
        } else if (dB < res.x) {
            res.x = dB;   // safe skip toward the shell, material unchanged
        }
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
        // CLASH palette: complementary hue pairs orbit the wheel together with
        // the music (mid/treble = big swing, beat = fast kick), per-element
        // multipliers make layers land on different hues for extra clash
        float hueShift = audio.y * 0.33 + audio.z * 0.18 + audio.w * 0.15
                       + sin(time * 0.07) * 0.06;
        float satPop = min(1.0 + audio.w * 0.3, 1.0);       // beat saturation snap

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

        // sunset sky: blue zenith vs orange horizon (true complementary clash)
        float horiz = pow(max(1.0 - abs(dir.y), 0.0), 7.0);
        float3 sky = mix(hsv2rgb(fract(0.62 + hueShift), 0.85 * satPop, 0.11),
                         hsv2rgb(fract(0.05 + hueShift), 0.85 * satPop, 0.36), horiz);
        sky += hsv2rgb(fract(0.92 + hueShift * 0.7), 0.85 * satPop, 1.0)
             * pow(max(1.0 - abs(dir.y + 0.02), 0.0), 18.0) * 0.5;
        if (dir.y > 0.04) {
            float2 sp = dir.xz / max(dir.y, 0.05);
            float2 cell = floor(sp * 36.0);
            float h = hash21(cell);
            float tw = 0.5 + 0.5 * sin(time * (1.5 + h * 5.0) + h * 40.0);
            float star = step(0.9965 - audio.z * 0.003, h); // treble adds stars
            sky += star * tw * (0.35 + audio.z * 0.9)
                 * hsv2rgb(fract(0.58 + hueShift * 0.4), 0.25, 1.0);
        }
        sky *= 1.0 + audio.w * 0.5;                          // beat sky flash

        float3 colOut;
        if (m < -0.5) {
            colOut = sky;
        } else if (m > 3.5) {
            // equalizer column: dark basalt body + neon cap riding its audio band
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio);
            float4 col = columnField(p, time, audio);   // re-fetch cell params
            float hc = col.y, band = col.z, top = col.w;
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = max(dot(n, L), 0.0);
            // per-column hue offset keeps pillar colors diverse (richness)
            float3 body = hsv2rgb(fract(0.70 + hueShift * 0.6 + hc * 0.25), 0.55, 0.22);
            float3 cap = hsv2rgb(fract(0.30 + hueShift + hc * 0.5), 0.9 * satPop, 1.2);
            float capGlow = exp(min((p.y - top) * 1.4, 0.0) * 1.0);  // 1 at the cap, decays down
            // rocky voronoi texture on the shaft
            float3 vv = voronoi(float2(atan2(p.z, p.x) * 3.0, p.y * 0.9), time);
            float crack = smoothstep(0.10, 0.0, vv.y);
            colOut = body * (0.25 + 0.9 * dif)
                   + cap * capGlow * (0.35 + band * 1.4)
                   + veinColorAt(hueShift, vv.z) * crack * 0.25;
            float fog = 1.0 - exp(-0.0009 * tRay * tRay);
            colOut = mix(colOut, sky, fog);
        } else if (m > 2.5) {
            // mandelbox crystal: diffuse key light + one-tap AO give it volume
            // (pure fresnel reads as a flat disc); rim glow on the counter-hue
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio);
            float3 Cc = crystalCenter(time, audio);
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = max(dot(n, L), 0.0);
            float ao = clamp(crystalDE((p - Cc) / 1.2 + n * 0.10, time, audio) * 1.2 / 0.12,
                             0.0, 1.0);
            float fres = pow(1.0 - max(dot(n, -dir), 0.0), 2.5);
            float hue = fract(0.55 + hueShift + 0.20 * sin(p.y * 2.0 + time * 0.5));
            float3 cCol = hsv2rgb(hue, 0.85 * satPop, 1.0);
            colOut = cCol * (0.10 + 0.65 * dif) * (0.35 + 0.65 * ao)
                   + hsv2rgb(fract(hue + 0.5), 0.7 * satPop, 1.0) * fres * 0.7
                       * (1.0 + audio.w * 0.8);
            float fog = 1.0 - exp(-0.0009 * tRay * tRay);
            colOut = mix(colOut, sky, fog * 0.7);
        } else if (m > 1.5) {
            // synthwave sun: hot gradient + scanline gaps widening toward bottom
            float3 p = ro + dir * tRay;
            float yy = (p.y - 6.0) / 2.1;                   // -1..1 over the disc
            float3 sun = mix(hsv2rgb(fract(0.93 + hueShift * 0.3), 0.85 * satPop, 1.0),
                             hsv2rgb(fract(0.11 + hueShift * 0.3), 0.70 * satPop, 1.0),
                             clamp(yy * 0.5 + 0.5, 0.0, 1.0));
            float gap = clamp(0.5 - yy * 0.5, 0.05, 1.0);   // wider gaps lower
            float stripe = smoothstep(gap, gap + 0.06, fract(p.y * 1.6 - time * 0.25));
            colOut = sun * (0.35 + 1.3 * stripe) * (1.8 + audio.w * 1.6);
        } else {
            // terrain: dark violet body + neon grid + voronoi veins + ring
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio);
            float h01 = clamp(p.y / 2.2, 0.0, 1.0);
            float3 base = mix(hsv2rgb(fract(0.75 + hueShift * 0.8), 0.80, 0.035),
                              hsv2rgb(fract(0.83 + hueShift * 0.8), 0.82, 0.17), h01);

            float2 g = abs(fract(p.xz / 1.5) - 0.5);
            float line = smoothstep(0.455, 0.5, max(g.x, g.y));
            float3 gridCol = mix(hsv2rgb(fract(0.52 + hueShift), 1.0, 1.0),
                                 hsv2rgb(fract(0.90 + hueShift), 0.85, 1.0),
                                 0.5 + 0.5 * sin(time * 0.3 + p.x * 0.2));

            // animated voronoi veins: per-cell rainbow hues keep palette
            // richness while the grid/sky swing globally with the music
            float3 v = voronoi(p.xz * 0.7 + float2(0.0, time * 0.15), time);
            float vein = smoothstep(0.12, 0.0, v.y);
            float cellPulse = 0.5 + 0.5 * sin(v.x * 6.0 - time * 2.0);
            float3 veinCol = veinColorAt(hueShift, v.z);

            // shockwave ring expands as the beat pulse decays
            float ringR = (1.0 - audio.w) * 9.0;
            float ring = exp(-abs(length(p.xz) - ringR) * 2.2) * audio.w;

            float3 L = normalize(float3(0.0, 0.5, -0.8));   // key light from the sun
            float dif = max(dot(n, L), 0.0);
            colOut = base * (0.3 + 0.9 * dif)
                   + gridCol * line * (0.45 + audio.x * 0.4)
                   + veinCol * vein * (0.7 + cellPulse * 0.5 + audio.x * 0.6 + audio.w * 0.7)
                   + hsv2rgb(fract(0.95 + hueShift * 0.8), 0.65, 1.0) * ring * 1.6;
            float fog = 1.0 - exp(-0.0009 * tRay * tRay);
            colOut = mix(colOut, sky, fog);
        }

        // ember particles: analytic glow points, occluded by the first hit;
        // per-particle rainbow (0.6 spread) + fast orbit = moving color confetti
        for (int i = 0; i < 24; i++) {
            float fi = float(i);
            float h1 = hash21(float2(fi, 1.7));
            float h2 = hash21(float2(fi, 9.2));
            float h3 = hash21(float2(fi, 4.4));
            float3 C = float3((h1 - 0.5) * 9.0,
                              0.6 + h2 * 5.5 + audio.w * (0.4 + h3) * 1.2,  // beat jump
                              -16.0 + h3 * 18.0);
            C.x += sin(time * (0.3 + h2 * 0.5) + h1 * 6.28) * 0.8;
            C.y += sin(time * (0.5 + h3 * 0.7) + h2 * 6.28) * 0.4;
            float tc = dot(C - ro, dir);
            if (tc > 0.0 && (m < -0.5 || tc < tRay)) {
                float d = length(ro + dir * tc - C);
                float tw = 0.55 + 0.45 * sin(time * (2.0 + h1 * 4.0) + h3 * 40.0);
                float glow = min(0.004 / (d * d + 0.004), 2.5);
                colOut += hsv2rgb(fract(0.90 + hueShift * 1.4 + h2 * 0.2), 0.65, 1.0)
                        * glow * tw * (0.4 + audio.z * 0.9);
            }
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
