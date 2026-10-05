import Foundation

/// Metal source for AIBlockCityScene. Prepended with LKGShaderCommon.msl at
/// pipeline creation, which provides lkgTileInfo / lkgViewOffset / lkgViewRay.
///
/// Scene v4: synthwave valley + audio-reactive CLASHING palette + floating
/// mandelbox crystal + animated voronoi terrain veins + ember particles
/// + equalizer columns (hashed cells flanking the corridor, each pillar's
/// height rides the bass/mid/treble band its hash selects).
/// v4 dynamism (docs/scene-v4-plan.md):
///   sun      -> lissajous drift + noise-breathed radius + spherical
///               displacement (lava-ball warp, wax drips on lower hemisphere,
///               near-shell only, DE x0.8)
///   crystal  -> slow orbit + precessing tumble + melt domain warp (DE x0.7)
///   terrain  -> bidirectional rotating fbm + counter-scroll detail + melt
///               warp + beat crater; advected flowing grid with row waves
///   corridor -> serpentine centerline x0(z,t); camera drifts autonomously
///   melt     -> unified scalar clamp(0.3 + bass*0.5 + mid*0.3, 0, 1) gates
///               all softening; columns smin-fuse into the molten floor
/// Audio channels drive independent parameters:
///   bass   -> terrain amplitude + sun size + voronoi vein brightness
///   mid    -> camera sway + terrain drift + crystal tumble + palette swing
///   treble -> star density/twinkle + ember brightness + palette swing
///   beat   -> hue kick (rhythm reads as hue swing, not brightness flash)
///             + shockwave ring + crystal breath + ember jump
///             + saturation snap (撞色: complementary pairs orbit
///             the hue wheel together, per-element multipliers add clash)
/// Composition notes (fov 25°, ndc half-width 0.22): crystal orbits around
/// (2.2, 4.8, -8) ±(1.4, -, 1.2) at world scale 0.85 — angular radius ~3°
/// ≈ 1/4 of the half-frame; shell 1.45 > extent ~1.13, never clips.
/// Sun drifts around (0, 6, -24) ±(2.6, 0.8, -), never leaves the frame.
/// Columns live in the z ∈ [-18, 8] band around the focus plane.
/// Emotion engine: `theme` uniform = (hueBias, crystalGain, columnGain,
/// emberGain); default (0,1,1,1) is bitwise-neutral. `audioPitch` uniform =
/// detected pitch in hue turns (MIDI/12, confidence-gated + smoothed, holds
/// last value under noise); default 0 is bitwise-neutral.
/// v5 ARCHITECTURE NOTE (docs/scene-v5-groove-plan.md): this file carries TWO
/// scene sources. `sceneMSL` is the S5 scene VERBATIM — never edit it (the
/// offline bitwise regression depends on its exact codegen; Metal fast-math
/// FMA fusion makes even value-identical edits to a live expression flip
/// pixels). `sceneMSL5` is the v5 groove scene (slowEnergy/kickEnv geometry
/// modulation + liquid metaball cluster + beat hue/flash divestment).
/// AIBlockCityScene compiles both and picks the pipeline per encode:
/// slowEnergy == 0 && kickEnv == 0 -> sceneMSL (bitwise S5), else sceneMSL5.
extension AIBlockCityScene {
    static let sceneMSL = """
    struct AIBaseParams {
        float2 tileSize;
        float4 audio;   // bass, mid, treble, beat
        float cols, rows, time, size, flip, dist, camH, fovTan, pitch, aspect;
        float4 theme;   // emotion engine: hueBias, crystalGain, columnGain, emberGain
        float audioPitch;   // tail-appended: detected pitch in hue turns (MIDI/12)
    };

    struct AIViewParams {
        float4 audio;
        float time, viewT, size, flip, dist, camH, fovTan, pitch, renderSize;
        float4 theme;
        float audioPitch;   // tail-appended: detected pitch in hue turns (MIDI/12)
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

    /// 2-octave fbm for cheap displacement/warp fields.
    static float fbm2(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 2; i++) {
            v += a * vnoise(p);
            p = p * 2.1 + float2(17.3, 9.1);
            a *= 0.5;
        }
        return v;
    }

    /// Polynomial smin: conservative when both fields are conservative, and
    /// passes 1e5 sentinels through unchanged (h clamps to 1 -> returns a).
    static float smin(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    static float2 rot2(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(p.x * c - p.y * s, p.x * s + p.y * c);
    }

    /// Unified melt scalar: 0.3 floor in silence (scene stays slightly
    /// alive), rises with bass+mid. Every softening effect reads this.
    static float meltFactor(float4 audio) {
        return clamp(0.3 + audio.x * 0.5 + audio.y * 0.3, 0.0, 1.0);
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
    /// v4: precessing dual-axis tumble + melt-driven domain warp; the warp
    /// breaks the Lipschitz bound so the returned distance is x0.7.
    static float crystalDE(float3 p, float t, float4 audio, float melt) {
        float ang = t * (0.15 + audio.y * 0.35);            // mid spins the tumble
        float ca = cos(ang), sa = sin(ang);
        p.xz = float2(p.x * ca - p.z * sa, p.x * sa + p.z * ca);
        float ang2 = 0.6 * sin(t * 0.09);                   // precession axis
        float c2 = cos(ang2), s2 = sin(ang2);
        p.yz = float2(p.y * c2 - p.z * s2, p.y * s2 + p.z * c2);
        float wAmp = 0.08 * melt * (1.0 + audio.w * 0.6);   // beat softens, then snaps back
        p += wAmp * (fbm2(p.xy * 1.5 + float2(t * 0.2, t * 0.13)) - 0.5);
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
        return (length(z) / dr - 0.02) * 0.45 * 0.7;
    }

    /// Serpentine corridor centerline: snakes with z and drifts over time.
    static float corridorX(float z, float t) {
        return sin(z * 0.22 + t * 0.15) * 1.6 + sin(z * 0.07 - t * 0.06) * 2.2;
    }

    static float terrainH(float2 xz, float t, float4 audio) {
        float amp = 0.9 + audio.x * 2.4;                    // bass pumps terrain
        float2 p2 = rot2(xz, t * 0.03);                     // slow domain rotation
        float h = fbm(p2 * 0.16 + float2(t * 0.18, t * (0.25 + audio.y * 0.6))) * amp;
        float detail = vnoise(xz * 0.6 - float2(t * 0.3, t * 0.12)); // counter-scroll interference
        h += detail * 0.15;
        h += (detail - 0.5) * 0.8 * meltFactor(audio);      // melt domain warp
        // beat shockwave presses a crater that springs back as the pulse decays
        if (audio.w > 0.001) {
            float ringR = (1.0 - audio.w) * 9.0;
            h -= exp(-abs(length(xz) - ringR) * 2.2) * audio.w * 0.4;
        }
        h += sin(xz.x * 0.35) * 0.22;
        h *= smoothstep(0.0, 3.0, abs(xz.x - corridorX(xz.y, t))); // serpentine valley
        return h;
    }

    /// Sun center: slow lissajous drift — stays well inside the 12.5°
    /// half-frame (worst-case angular offset ~6° at dist ~32).
    static float3 sunCenter(float t) {
        return float3(2.6 * sin(t * 0.11), 6.0 + 0.8 * sin(t * 0.07), -24.0);
    }

    /// Base sun radius: slow noise breath, not only beat pumping.
    /// Single-octave: this runs on every map() step, so keep it cheap.
    static float sunRadius(float t, float4 audio) {
        return (1.7 + 0.5 * vnoise(float2(t * 0.05, 3.7)))
             * (1.0 + audio.x * 0.22 + audio.w * 0.10);
    }

    /// Sun distance with spherical displacement: fbm lava-ball warp + bass
    /// equator ripple + beat shimmer + wax drips hanging off the lower
    /// hemisphere. Displacement is computed only inside the near shell
    /// (dBase < sunR*2.2) and the result steps at x0.8 (displaced DE is not
    /// strictly conservative). Total deformation budget <= 45% of sunR,
    /// scaled by melt so quiet passages settle back to a hard disc.
    static float sunDE(float3 p, float t, float4 audio, float melt) {
        float3 C = sunCenter(t);
        float sunR = sunRadius(t, audio);
        float dBase = length(p - C);
        if (dBase >= sunR * 2.2) return dBase - sunR;       // far: exact sphere step
        float3 d3 = (p - C) / max(dBase, 1e-4);
        float az = atan2(d3.z, d3.x);
        float el = asin(clamp(d3.y, -1.0, 1.0));
        float disp = fbm2(float2(az * 2.0, el * 2.0) + float2(t * 0.10, t * 0.07))
                   + audio.x * 0.5 * sin(az * 6.0 + t * 2.0)    // bass equator ripple
                   + audio.w * 0.3 * sin(el * 12.0 - t * 6.0);   // beat shimmer
        float drip = fbm2(float2(az * 3.0 + 7.0, t * 0.25))
                   * smoothstep(0.1, -0.5, d3.y);                // lower hemisphere only
        disp += drip * (0.5 + audio.x * 0.8) * 0.5;              // bass lengthens drips
        disp = clamp((disp - 0.5) * 0.45, -0.45, 0.45) * (0.35 + 0.65 * melt);
        return (dBase - sunR * (1.0 + disp)) * 0.8;
    }

    /// Crystal floats just behind the focus plane (z=0) so the 3D pop reads
    /// on the panel; right-offset to share the sky with the sun.
    /// v4: slow orbit — never crosses far past the focus plane.
    static float3 crystalCenter(float t, float4 audio) {
        return float3(2.2 + 1.4 * sin(t * 0.09),
                      4.8 + 0.3 * sin(t * 0.7) + audio.w * 0.3,
                      -8.0 + 1.2 * cos(t * 0.13));
    }

    /// v4.1: crystal world scale 0.85 (was 1.2) — angular radius ~3° ≈ 1/4
    /// of the half-frame so it no longer dominates the sun.
    static float crystalScale() { return 0.85; }

    /// Column field flanking the corridor, band-limited around the focus
    /// plane (z=0) so the pillars sit at readable 3D depth: hashed cells, each
    /// column bound to bass/mid/treble by hash -> equalizer-pillar forest.
    /// Returns (capped-cylinder dist, cellHash, bandValue, topY).
    static float4 columnField(float3 p, float t, float4 audio, float4 theme) {
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
        hgt *= theme.z;                                // emotion: column strength
        float top = terrainH(cc, t, audio) + hgt;
        float d = max(length(p.xz - cc) - 0.5, p.y - top);
        return float4(d, hc, band, top);
    }

    // returns (dist, materialId): 0 = terrain, 2 = sun, 3 = crystal, 4 = column
    static float2 map(float3 p, float t, float4 audio, float4 theme) {
        float melt = meltFactor(audio);
        float dTer = (p.y - terrainH(p.xz, t, audio)) * 0.55;
        // equalizer columns (single nearest cell — radius < half spacing),
        // smin-fused into the terrain so roots grow out of the molten floor
        // with no hard seam (smin stays conservative: no step reduction)
        float4 col = columnField(p, t, audio, theme);
        float2 res = float2(smin(col.x, dTer, 2.5 * (0.4 + 0.6 * melt)),
                            col.x < dTer ? 4.0 : 0.0);
        float dSun = sunDE(p, t, audio, melt);
        if (dSun < res.x) res = float2(dSun, 2.0);
        // crystal: shell radius (1.45) comfortably exceeds the fractal extent
        // (world scale 0.85 -> ~1.13 world), so no clipping flat cap; outside
        // the shell the sphere distance is only a conservative step.
        float3 C = crystalCenter(t, audio);
        float dB = length(p - C) - 1.45;
        if (dB < 0.3) {
            float cs = crystalScale();
            float dF = crystalDE((p - C) / cs, t, audio, melt) * cs;
            if (dF < res.x) res = float2(dF, 3.0);
        } else if (dB < res.x) {
            res.x = dB;   // safe skip toward the shell, material unchanged
        }
        return res;
    }

    static float3 calcNormal(float3 p, float t, float4 audio, float4 theme) {
        float2 e = float2(0.002, -0.002);
        return normalize(e.xyy * map(p + e.xyy, t, audio, theme).x +
                         e.yyx * map(p + e.yyx, t, audio, theme).x +
                         e.yxy * map(p + e.yxy, t, audio, theme).x +
                         e.xxx * map(p + e.xxx, t, audio, theme).x);
    }

    static float3 aces(float3 c) {
        c = clamp(c, 0.0, 16.0);
        c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
        return pow(c, float3(1.0 / 2.2));
    }

    static float3 shadeScene(float3 ro, float3 dir, float2 ndc, float time, float4 audio, float4 theme, float audioPitch) {
        // CLASH palette: complementary hue pairs orbit the wheel together with
        // the music (mid/treble = big swing, beat = fast kick), per-element
        // multipliers make layers land on different hues for extra clash
        float hueShift = audio.y * 0.33 + audio.z * 0.18 + audio.w * 0.45
                       + sin(time * 0.07) * 0.06;
        hueShift += theme.x;                            // emotion: hue re-anchor
        hueShift += audioPitch;                         // pitch class anchors hue (adds with theme.x)
        float satPop = min(1.0 + audio.w * 0.3, 1.0);       // beat saturation snap
        float melt = meltFactor(audio);

        // groove: camera rides kick (bass) and backbeat (mid) — motion, not
        // brightness; beat adds a small bob
        ro.x += sin(time * 0.5) * (0.4 * audio.y + 0.25 * audio.x);
        ro.y += audio.w * 0.15 + audio.x * 0.12;
        // autonomous drift: the scene keeps breathing even in silence
        ro.x += sin(time * 0.13) * 0.8;
        ro.y += sin(time * 0.09) * 0.15;
        ro.z += sin(time * 0.05) * 1.2;                     // slow dolly in/out
        float pSway = sin(time * 0.11) * 0.02;              // micro pitch sway
        float cps = cos(pSway), sps = sin(pSway);
        dir = float3(dir.x, dir.y * cps + dir.z * sps, -dir.y * sps + dir.z * cps);

        float tRay = 0.0;
        float m = -1.0;
        for (int i = 0; i < 110; i++) {
            float3 p = ro + dir * tRay;
            float2 dm = map(p, time, audio, theme);
            if (dm.x < 0.0015 * tRay + 0.001) { m = dm.y; break; }
            tRay += dm.x * 0.95;
            if (tRay > 70.0) break;
        }

        // sunset sky: blue zenith vs orange horizon (true complementary clash)
        float horiz = pow(max(1.0 - abs(dir.y), 0.0), 7.0);
        float3 sky = mix(hsv2rgb(fract(0.62 + hueShift), 0.85 * satPop, 0.11),
                         hsv2rgb(fract(0.05 + hueShift), 0.85 * satPop, 0.36), horiz);
        sky += hsv2rgb(fract(0.92 + hueShift * 0.7), 0.85 * satPop, 1.0)
             * pow(max(1.0 - abs(dir.y + 0.02), 0.0), 18.0) * 0.3;
        if (dir.y > 0.04) {
            float2 sp = dir.xz / max(dir.y, 0.05);
            float2 cell = floor(sp * 36.0);
            float h = hash21(cell);
            float tw = 0.5 + 0.5 * sin(time * (1.5 + h * 5.0) + h * 40.0);
            float star = step(0.9965 - audio.z * 0.003, h); // treble adds stars
            sky += star * tw * (0.35 + audio.z * 0.9)
                 * hsv2rgb(fract(0.58 + hueShift * 0.4), 0.25, 1.0);
        }
        sky *= 1.0 + audio.w * 0.15;                         // beat sky flash (subtle; rhythm lives in hue)

        float3 colOut;
        if (m < -0.5) {
            colOut = sky;
        } else if (m > 3.5) {
            // equalizer column: dark basalt body + neon cap riding its audio band
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio, theme);
            float4 col = columnField(p, time, audio, theme);   // re-fetch cell params
            float hc = col.y, band = col.z, top = col.w;
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = max(dot(n, L), 0.0);
            // per-column hue offset keeps pillar colors diverse (richness)
            float3 body = hsv2rgb(fract(0.70 + hueShift * 0.6 + hc * 0.25), 0.55, 0.22);
            float3 cap = hsv2rgb(fract(0.30 + hueShift + hc * 0.5), 0.9 * satPop, 1.0);
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
            float3 n = calcNormal(p, time, audio, theme);
            float3 Cc = crystalCenter(time, audio);
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = max(dot(n, L), 0.0);
            float cs = crystalScale();
            float ao = clamp(crystalDE((p - Cc) / cs + n * 0.07, time, audio, melt) * cs / 0.085,
                             0.0, 1.0);
            float fres = pow(1.0 - max(dot(n, -dir), 0.0), 2.5);
            float hue = fract(0.55 + hueShift + 0.20 * sin(p.y * 2.0 + time * 0.5));
            float3 cCol = hsv2rgb(hue, 0.85 * satPop, 1.0);
            colOut = cCol * (0.10 + 0.65 * dif) * (0.35 + 0.65 * ao)
                   + hsv2rgb(fract(hue + 0.5), 0.7 * satPop, 1.0) * fres * 0.55
                       * (1.0 + audio.w * 0.3);
            colOut *= theme.y;                          // emotion: crystal strength
            // luminance-keyed transparency: dark facets melt into the sky,
            // turning the fractal into a glassy volume instead of a rock
            float crysLum = dot(colOut, float3(0.299, 0.587, 0.114));
            colOut = mix(sky, colOut, smoothstep(0.05, 0.38, crysLum));
            float fog = 1.0 - exp(-0.0009 * tRay * tRay);
            colOut = mix(colOut, sky, fog * 0.7);
        } else if (m > 1.5) {
            // synthwave sun: hot gradient + scanline gaps widening toward
            // bottom; scanline density/speed ride mid
            float3 p = ro + dir * tRay;
            float sunR = sunRadius(time, audio);
            float yy = (p.y - sunCenter(time).y) / sunR;    // -1..1 over the disc
            float3 sun = mix(hsv2rgb(fract(0.93 + hueShift * 0.3), 0.85 * satPop, 1.0),
                             hsv2rgb(fract(0.11 + hueShift * 0.3), 0.70 * satPop, 1.0),
                             clamp(yy * 0.5 + 0.5, 0.0, 1.0));
            float gap = clamp(0.5 - yy * 0.5, 0.05, 1.0);   // wider gaps lower
            float stripe = smoothstep(gap, gap + 0.06,
                fract(p.y * (1.4 + audio.y * 0.5) - time * (0.25 + audio.y * 0.6)));
            colOut = sun * (0.35 + 1.0 * stripe) * (1.15 + audio.w * 0.2);
            // luminance-keyed transparency: the dark scanline gaps let the
            // sky bleed through, so the sun reads as floating light bands
            float sunLum = dot(colOut, float3(0.299, 0.587, 0.114));
            colOut = mix(sky, colOut, smoothstep(0.30, 0.95, sunLum));
        } else {
            // terrain: lifted violet base (never reads pure black) + neon
            // grid + voronoi veins + ring
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio, theme);
            float h01 = clamp(p.y / 2.2, 0.0, 1.0);
            float3 base = mix(hsv2rgb(fract(0.75 + hueShift * 0.8), 0.72, 0.09),
                              hsv2rgb(fract(0.83 + hueShift * 0.8), 0.78, 0.24), h01);
            base += sky * 0.05;      // faint sky ambient floor tint

            // flowing synthwave grid: advected toward the camera (bass
            // speeds it up), swaying in x; per-cell hash picks the phase of
            // a traveling row wave that ripples along the grid lines
            float2 gridUV = p.xz + float2(sin(p.z * 0.15 + time * 0.4) * 0.3,
                                          time * (2.0 + audio.x * 3.0));
            float2 g = abs(fract(gridUV / 1.5) - 0.5);
            float line = smoothstep(0.455, 0.5, max(g.x, g.y));
            float2 cellId = floor(gridUV / 1.5);
            float rowWave = 0.5 + 0.5 * sin(time * 2.2 - (cellId.x + cellId.y) * 0.9
                                            + hash21(cellId) * 6.2831);
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
                   + gridCol * line * (0.45 + audio.x * 0.4) * (0.6 + 0.4 * rowWave)
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
                float glow = min(0.004 / (d * d + 0.004), 1.4);   // cap below ACES shoulder: keeps hue
                colOut += hsv2rgb(fract(0.90 + hueShift * 1.4 + h2 * 0.2), 0.65, 1.0)
                        * glow * tw * (0.4 + audio.z * 0.9) * theme.w;  // emotion: ember strength
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
        return float4(shadeScene(ro, dir, ti.tileNDC, P.time, P.audio, P.theme, P.audioPitch), 1.0);
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
        return float4(aces(shadeScene(ro, dir, ndc, P.time, P.audio, P.theme, P.audioPitch)), 1.0);
    }
    """

    /// v5 groove scene: fast/slow split — beat hue/flash moved to the
    /// display layer; slowEnergy/kickEnv drive geometry; liquid metaball
    /// cluster (material 5). Same entry-point names as sceneMSL (separate
    /// MTLLibrary, no collision).
    static let sceneMSL5 = """
    struct AIBaseParams {
        float2 tileSize;
        float4 audio;   // bass, mid, treble, beat
        float cols, rows, time, size, flip, dist, camH, fovTan, pitch, aspect;
        float4 theme;   // emotion engine: hueBias, crystalGain, columnGain, emberGain
        float audioPitch;   // tail-appended: detected pitch in hue turns (MIDI/12)
        float slowEnergy;   // v5: 2-4s phrase-energy EMA (bass/mid weighted)
        float kickEnv;      // v5: kick envelope, slow attack / fast release
        float accumEnergy;  // v5: monotonic energy integral (never decreases)
    };

    struct AIViewParams {
        float4 audio;
        float time, viewT, size, flip, dist, camH, fovTan, pitch, renderSize;
        float4 theme;
        float audioPitch;
        float slowEnergy;
        float kickEnv;
        float accumEnergy;
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

    /// 2-octave fbm for cheap displacement/warp fields.
    static float fbm2(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 2; i++) {
            v += a * vnoise(p);
            p = p * 2.1 + float2(17.3, 9.1);
            a *= 0.5;
        }
        return v;
    }

    /// Polynomial smin: conservative when both fields are conservative, and
    /// passes 1e5 sentinels through unchanged (h clamps to 1 -> returns a).
    static float smin(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    static float2 rot2(float2 p, float a) {
        float c = cos(a), s = sin(a);
        return float2(p.x * c - p.y * s, p.x * s + p.y * c);
    }

    /// Unified melt scalar: 0.3 floor in silence (scene stays slightly
    /// alive), rises with bass+mid; v5: phrase energy melts the world on a
    /// 2-4s timescale. Every softening effect reads this.
    static float meltFactor(float4 audio, float slow) {
        return clamp(0.3 + audio.x * 0.3 + audio.y * 0.3 + slow * 0.45, 0.0, 1.0);
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
        return hsv2rgb(fract(0.50 + hueShift * 0.9 + cellHash * 0.55), 0.95, 1.0);
    }

    /// Mandelbox-lite DE (4 folds); beat breathes the fold scale.
    /// Only evaluated inside the crystal's bounding shell (see map()).
    /// v4: precessing dual-axis tumble + melt-driven domain warp; the warp
    /// breaks the Lipschitz bound so the returned distance is x0.7.
    static float crystalDE(float3 p, float t, float4 audio, float melt) {
        float ang = t * (0.15 + audio.y * 0.35);            // mid spins the tumble
        float ca = cos(ang), sa = sin(ang);
        p.xz = float2(p.x * ca - p.z * sa, p.x * sa + p.z * ca);
        float ang2 = 0.6 * sin(t * 0.09);                   // precession axis
        float c2 = cos(ang2), s2 = sin(ang2);
        p.yz = float2(p.y * c2 - p.z * s2, p.y * s2 + p.z * c2);
        float wAmp = 0.08 * melt * (1.0 + audio.w * 0.6);   // beat softens, then snaps back
        p += wAmp * (fbm2(p.xy * 1.5 + float2(t * 0.2, t * 0.13)) - 0.5);
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
        return (length(z) / dr - 0.02) * 0.45 * 0.7;
    }

    /// Serpentine corridor centerline: snakes with z and drifts over time.
    /// v5: phrase energy widens the snake amplitude (structure-level groove).
    static float corridorX(float z, float t, float slow) {
        return (sin(z * 0.22 + t * 0.15) * 1.6 + sin(z * 0.07 - t * 0.06) * 2.2)
             * (1.0 + slow * 0.8);
    }

    static float terrainH(float2 xz, float t, float4 audio, float melt, float slow,
                          float accum) {
        // bass pumps terrain (S6.1: instant response toned down — rhythm
        // takes a back seat to the cumulative sculpture below)
        float amp = (0.9 + audio.x * 0.5) * (1.0 + slow * 0.35);
        float2 p2 = rot2(xz, t * 0.03);                     // slow domain rotation
        float h = fbm(p2 * 0.16 + float2(t * 0.18, t * (0.25 + audio.y * 0.6))) * amp;
        float detail = vnoise(xz * 0.6 - float2(t * 0.3, t * 0.12)); // counter-scroll interference
        h += detail * 0.15;
        h += (detail - 0.5) * 0.8 * melt;                   // melt domain warp
        // cumulative, IRREVERSIBLE deformation: accumEnergy only ever grows,
        // so this sediment-warp fades in permanent ridges and keeps
        // translating — the floor is sculpted by the music's history and
        // never returns to an earlier shape
        float warpA = min(accum * 0.06, 1.6);
        h += (fbm2(p2 * 0.31 + float2(accum * 0.030, -accum * 0.017)) - 0.375) * warpA;
        // beat shockwave presses a crater that springs back as the pulse decays
        // (S6.1: softened — rhythm de-emphasized in favor of accumulation)
        if (audio.w > 0.001) {
            float ringR = (1.0 - audio.w) * 9.0;
            h -= exp(-abs(length(xz) - ringR) * 2.2) * audio.w * 0.3;
        }
        h += sin(xz.x * 0.35) * 0.22;
        h *= smoothstep(0.0, 3.0, abs(xz.x - corridorX(xz.y, t, slow))); // serpentine valley
        return h;
    }

    /// Sun center: slow lissajous drift — stays well inside the 12.5°
    /// half-frame (worst-case angular offset ~6° at dist ~32).
    static float3 sunCenter(float t) {
        return float3(2.6 * sin(t * 0.11), 6.0 + 0.8 * sin(t * 0.07), -24.0);
    }

    /// Base sun radius: slow noise breath, not only beat pumping.
    /// Single-octave: this runs on every map() step, so keep it cheap.
    /// v5: phrase energy amplifies the breath.
    static float sunRadius(float t, float4 audio, float slow) {
        return (1.7 + 0.5 * vnoise(float2(t * 0.05, 3.7)) * (1.0 + 0.9 * slow))
             * (1.0 + audio.x * 0.12 + audio.w * 0.10);
    }

    /// Sun distance with spherical displacement: fbm lava-ball warp + bass
    /// equator ripple + beat shimmer + wax drips hanging off the lower
    /// hemisphere. Displacement is computed only inside the near shell
    /// (dBase < sunR*2.2) and the result steps at x0.8 (displaced DE is not
    /// strictly conservative). Total deformation budget <= 45% of sunR,
    /// scaled by melt so quiet passages settle back to a hard disc.
    static float sunDE(float3 p, float t, float4 audio, float melt, float slow) {
        float3 C = sunCenter(t);
        float sunR = sunRadius(t, audio, slow);
        float dBase = length(p - C);
        if (dBase >= sunR * 2.2) return dBase - sunR;       // far: exact sphere step
        float3 d3 = (p - C) / max(dBase, 1e-4);
        float az = atan2(d3.z, d3.x);
        float el = asin(clamp(d3.y, -1.0, 1.0));
        float disp = fbm2(float2(az * 2.0, el * 2.0) + float2(t * 0.10, t * 0.07))
                   + audio.x * 0.25 * sin(az * 6.0 + t * 2.0)   // bass equator ripple
                   + audio.w * 0.3 * sin(el * 12.0 - t * 6.0);   // beat shimmer
        float drip = fbm2(float2(az * 3.0 + 7.0, t * 0.25))
                   * smoothstep(0.1, -0.5, d3.y);                // lower hemisphere only
        disp += drip * (0.5 + audio.x * 0.4) * 0.5;              // bass lengthens drips
        disp = clamp((disp - 0.5) * 0.45, -0.45, 0.45) * (0.35 + 0.65 * melt);
        return (dBase - sunR * (1.0 + disp)) * 0.8;
    }

    /// Crystal floats just behind the focus plane (z=0) so the 3D pop reads
    /// on the panel; right-offset to share the sky with the sun.
    /// v4: slow orbit — never crosses far past the focus plane.
    static float3 crystalCenter(float t, float4 audio) {
        return float3(2.2 + 1.4 * sin(t * 0.09),
                      4.8 + 0.3 * sin(t * 0.7) + audio.w * 0.3,
                      -8.0 + 1.2 * cos(t * 0.13));
    }

    /// v4.1: crystal world scale 0.85 (was 1.2) — angular radius ~3° ≈ 1/4
    /// of the half-frame so it no longer dominates the sun.
    static float crystalScale() { return 0.85; }

    /// Column field flanking the corridor, band-limited around the focus
    /// plane (z=0) so the pillars sit at readable 3D depth: hashed cells, each
    /// column bound to bass/mid/treble by hash -> equalizer-pillar forest.
    /// Returns (capped-cylinder dist, cellHash, bandValue, topY).
    /// v5: phrase energy widens the per-band height dynamic range.
    static float4 columnField(float3 p, float t, float4 audio, float4 theme,
                              float melt, float slow, float accum) {
        if (abs(p.x) < 2.4 || p.y > 12.0 || p.z < -18.0 || p.z > 8.0) {
            return float4(1e5, 0.0, 0.0, 0.0);
        }
        float2 cell = floor(p.xz / 3.2);
        float hc = hash21(cell * 1.31 + 4.7);
        if (hc < 0.35) { return float4(1e5, 0.0, 0.0, 0.0); }
        float2 cc = (cell + 0.5) * 3.2
                  + float2(hash21(cell + 3.1), hash21(cell + 5.7)) * 1.4 - 0.7;
        float band = hc < 0.55 ? audio.x : (hc < 0.75 ? audio.y : audio.z);
        float hgt = 0.8 + hc * 3.0 + band * (1.5 + hc * 3.5) * (1.0 + slow * 1.2);
        hgt *= theme.z;                                // emotion: column strength
        float top = terrainH(cc, t, audio, melt, slow, accum) + hgt;
        float d = max(length(p.xz - cc) - 0.5, p.y - top);
        return float4(d, hc, band, top);
    }

    // ---- v5 liquid metaball cluster (material 5) --------------------------
    // Four smin-fused blobs floating left of the corridor (mirrors the
    // crystal). All liquid behavior is GEOMETRY so it survives img2img:
    // surface tension (fusion k rides phrase energy + melt), capillary wobble
    // (near-shell fbm warp), viscous stretch (finite-difference velocity),
    // gravity drips that pancake into the molten floor, beat ripples, kick
    // squash & stretch. PRESENCE is gated by slowEnergy+bands (scene picker
    // never selects this shader at digital silence — see AIBlockCityScene).
    static float3 blobAnchor(float t) {
        return float3(-1.8 + 0.9 * sin(t * 0.08),
                      4.6 + 0.5 * sin(t * 0.11 + 1.7),
                      -5.0 + 0.6 * sin(t * 0.06 + 0.9));
    }

    static float blobPresence(float4 audio, float slow) {
        return clamp(slow * 2.2 + audio.x * 0.35 + audio.y * 0.3, 0.0, 1.0);
    }

    /// Blob center: slow orbit around the anchor; phrase energy speeds the
    /// flow advection up (viscous drag reads the finite-difference velocity).
    static float3 blobCenter(int i, float t, float4 audio, float slow) {
        float fi = float(i);
        float h1 = hash21(float2(fi, 11.1));
        float h2 = hash21(float2(fi, 23.7));
        float h3 = hash21(float2(fi, 37.3));
        float3 A = blobAnchor(t);
        float w = (0.35 + 0.45 * h1) * (1.0 + 1.6 * slow);
        float ph = 6.2831 * h2;
        float rad = 0.55 + 0.65 * h3;
        return A + float3(cos(t * w + ph) * rad,
                          sin(t * w * 0.7 + ph * 1.3) * rad * 0.45,
                          sin(t * w + ph) * rad * 0.7);
    }

    static float blobDE(float3 p, float t, float4 audio, float melt,
                        float slow, float kick, float accum) {
        float presence = blobPresence(audio, slow);
        if (presence < 0.001) return 1e5;        // no cluster this frame
        float3 A = blobAnchor(t);
        float d = 1e5;
        // gravity drips: droplets condense under the cluster, fall with
        // gravity, pancake on the terrain and dissolve; phrase energy raises
        // the drip frequency. Evaluated OUTSIDE the cluster shell gate (they
        // fall well below it); cheap horizontal reject before the terrainH
        // call. (The smin into the terrain happens in map().)
        if (presence > 0.15) {
            for (int i = 0; i < 2; i++) {
                float fi = float(i);
                float seed = hash21(float2(fi, 51.7));
                float sx = A.x + (seed - 0.5) * 1.6;
                float sz = A.z + (hash21(float2(fi, 63.1)) - 0.5) * 1.2;
                float2 dxz = p.xz - float2(sx, sz);
                if (dot(dxz, dxz) < 2.25 && p.y < A.y + 0.5) {
                    float freq = 0.25 + 0.55 * slow + 0.2 * seed;
                    float ph = fract(t * freq + seed * 7.0);
                    float floorY = terrainH(float2(sx, sz), t, audio, melt, slow, accum);
                    float y0 = A.y - 0.8;
                    float rd = 0.10 * presence * (0.7 + 0.6 * seed);
                    float3 dc;
                    float sy = 1.0, sxz = 1.0;
                    if (ph < 0.7) {
                        float u = ph / 0.7;
                        dc = float3(sx, mix(y0, floorY + 0.08, u * u), sz);  // accelerating fall
                        rd *= 0.7 + 0.5 * u;        // gathers volume as it falls
                    } else {
                        float s = (ph - 0.7) / 0.3;
                        dc = float3(sx, floorY + 0.05, sz);
                        sy = max(1.0 - 0.7 * s, 0.3);   // pancake on impact
                        sxz = 1.0 + 0.8 * s;
                        rd *= 1.0 - s * 0.8;        // dissolves into the floor
                    }
                    float3 dq = p - dc;
                    dq.y /= sy;
                    dq.xz /= sxz;
                    // /sxz keeps the widened pancake a conservative step
                    d = smin(d, (length(dq) - rd) / sxz, 0.12);
                }
            }
        }
        float dBound = length(p - A);
        // outside the shell only droplets contribute; dBound-3.2 stays a
        // conservative step toward the cluster
        if (dBound > 3.4) return min(d, dBound - 3.2);
        // surface tension: quiet = small k (distinct balls), energetic =
        // large k (merged liquid). Necking emerges as k drops while blobs
        // separate; the centroid pull below strings the neck out thin.
        float k = mix(0.10, 0.85, clamp(melt * 0.45 + slow * 0.6, 0.0, 1.0));
        for (int i = 0; i < 4; i++) {
            float3 c = blobCenter(i, t, audio, slow);
            float r = (0.38 + 0.20 * hash21(float2(float(i), 3.3)))
                    * (0.30 + 0.70 * presence);
            float3 q = p - c;
            // viscous stretch: elongate along velocity — fast motion strings
            // the blob out; slow motion settles back to round
            float3 v = (blobCenter(i, t + 0.1, audio, slow)
                      - blobCenter(i, t - 0.1, audio, slow)) * 5.0;
            float sp = length(v);
            float3 vh = v / max(sp, 1e-4);
            float st = 1.0 + min(sp * 0.45, 1.1);
            q -= vh * dot(q, vh) * (1.0 - 1.0 / st);
            // surface-tension necking: pull along the centroid axis so
            // separating blobs string a thin liquid neck before snapping
            float3 cA = A - c;
            float3 toA = cA / max(length(cA), 1e-4);
            float neck = 1.0 + (1.0 - clamp(slow + melt * 0.5, 0.0, 1.0)) * 0.7;
            q -= toA * dot(q, toA) * (1.0 - 1.0 / neck);
            // kick squash & stretch: the whole blob jumps on the downbeat
            // (geometry-level beat read — survives diffusion)
            q.y /= max(1.0 - 0.20 * kick, 0.2);
            float di = (length(q) - r) / (st * neck);
            d = smin(d, di, k);
        }
        // capillary wobble + beat ripples, near-shell only (v4 budget
        // pattern), DE x0.75. Quiet passages keep a small autonomous shimmer
        // (presence-scaled) so the liquid never reads dead.
        if (d < 0.7) {
            float wob = (fbm2(p.xy * 2.6 + float2(t * 0.45, t * 0.30)) - 0.375)
                      + (fbm2(p.zy * 2.6 - float2(t * 0.38, t * 0.22)) - 0.375);
            float amp = presence * (0.015 + 0.05 * clamp(slow + audio.x * 0.25, 0.0, 1.0));
            // beat ripples: concentric rings rolling over the skin
            float3 dA = (p - A) / max(dBound, 1e-4);
            float el = asin(clamp(dA.y, -1.0, 1.0));
            wob += audio.w * 0.35 * sin(el * 10.0 - t * 9.0);
            d += wob * (amp + audio.w * 0.04);
            d *= 0.75;
        }
        return d;
    }

    // returns (dist, materialId): 0 = terrain, 2 = sun, 3 = crystal,
    // 4 = column, 5 = liquid blob
    static float2 map(float3 p, float t, float4 audio, float4 theme,
                      float slow, float kick, float accum) {
        float melt = meltFactor(audio, slow);
        float dTer = (p.y - terrainH(p.xz, t, audio, melt, slow, accum)) * 0.55;
        // equalizer columns (single nearest cell — radius < half spacing),
        // smin-fused into the terrain so roots grow out of the molten floor
        // with no hard seam (smin stays conservative: no step reduction)
        float4 col = columnField(p, t, audio, theme, melt, slow, accum);
        float2 res = float2(smin(col.x, dTer, 2.5 * (0.4 + 0.6 * melt)),
                            col.x < dTer ? 4.0 : 0.0);
        // liquid blob cluster: smin into the terrain layer so drips merge
        // with the molten floor; the cluster floats high, so away from the
        // floor the smin is an exact min (conservative, no step reduction)
        float dBlob = blobDE(p, t, audio, melt, slow, kick, accum);
        float dPre = res.x;
        res.x = smin(dBlob, res.x, 0.9);
        if (dBlob < dPre) res.y = 5.0;
        float dSun = sunDE(p, t, audio, melt, slow);
        if (dSun < res.x) res = float2(dSun, 2.0);
        // crystal: shell radius (1.45) comfortably exceeds the fractal extent
        // (world scale 0.85 -> ~1.13 world), so no clipping flat cap; outside
        // the shell the sphere distance is only a conservative step.
        float3 C = crystalCenter(t, audio);
        float dB = length(p - C) - 1.45;
        if (dB < 0.3) {
            float cs = crystalScale();
            float dF = crystalDE((p - C) / cs, t, audio, melt) * cs;
            if (dF < res.x) res = float2(dF, 3.0);
        } else if (dB < res.x) {
            res.x = dB;   // safe skip toward the shell, material unchanged
        }
        return res;
    }

    static float3 calcNormal(float3 p, float t, float4 audio, float4 theme,
                             float slow, float kick, float accum) {
        float2 e = float2(0.002, -0.002);
        return normalize(e.xyy * map(p + e.xyy, t, audio, theme, slow, kick, accum).x +
                         e.yyx * map(p + e.yyx, t, audio, theme, slow, kick, accum).x +
                         e.yxy * map(p + e.yxy, t, audio, theme, slow, kick, accum).x +
                         e.xxx * map(p + e.xxx, t, audio, theme, slow, kick, accum).x);
    }

    static float3 aces(float3 c) {
        c = clamp(c, 0.0, 16.0);
        c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
        return pow(c, float3(1.0 / 2.2));
    }

    /// Sunset sky: blue zenith vs orange horizon (true complementary clash)
    /// + treble-driven stars. Factored out so the liquid blob can reflect it.
    /// v5: the beat sky flash is REMOVED — brightness rhythm lives in the
    /// display layer (interlace mainHue / mainGain).
    static float3 skyColor(float3 dir, float time, float4 audio, float hueShift) {
        float horiz = pow(max(1.0 - abs(dir.y), 0.0), 7.0);
        float3 sky = mix(hsv2rgb(fract(0.62 + hueShift), 0.95, 0.11),
                         hsv2rgb(fract(0.05 + hueShift), 0.95, 0.30), horiz);
        sky += hsv2rgb(fract(0.92 + hueShift * 0.7), 0.95, 1.0)
             * pow(max(1.0 - abs(dir.y + 0.02), 0.0), 18.0) * 0.22;
        if (dir.y > 0.04) {
            float2 sp = dir.xz / max(dir.y, 0.05);
            float2 cell = floor(sp * 36.0);
            float h = hash21(cell);
            float tw = 0.5 + 0.5 * sin(time * (1.5 + h * 5.0) + h * 40.0);
            float star = step(0.9965 - audio.z * 0.003, h); // treble adds stars
            sky += star * tw * (0.35 + audio.z * 0.9)
                 * hsv2rgb(fract(0.58 + hueShift * 0.4), 0.25, 1.0);
        }
        return sky;
    }

    static float3 shadeScene(float3 ro, float3 dir, float2 ndc, float time,
                             float4 audio, float4 theme, float audioPitch,
                             float slow, float kick, float accum,
                             thread float& depthOut) {
        // CLASH palette: complementary hue pairs orbit the wheel together
        // with the music (mid/treble = big swing), per-element multipliers
        // make layers land on different hues for extra clash.
        // v5: the beat hue kick and saturation snap are REMOVED here — the
        // display layer (interlace mainHue, 60 Hz coherent) owns fast color.
        float hueShift = audio.y * 0.33 + audio.z * 0.18
                       + sin(time * 0.07) * 0.06;
        hueShift += theme.x;                            // emotion: hue re-anchor
        hueShift += audioPitch;                         // pitch class anchors hue (adds with theme.x)
        // S6.1 palette evolution: the monotonic energy integral walks the
        // whole palette around the wheel over minutes of playback; each
        // element below adds its own slower drift rate so hue RELATIONSHIPS
        // keep changing instead of rotating in lockstep
        hueShift += accum * 0.01;
        float melt = meltFactor(audio, slow);

        // groove: camera rides kick (bass) and backbeat (mid) — motion, not
        // brightness; v5 widened the travel and added a kick dolly push-in
        // (slow attack / fast release via kickEnv)
        ro.x += sin(time * 0.5) * (0.85 * audio.y + 0.3 * audio.x);
        ro.y += audio.w * 0.22 + audio.x * 0.08;
        ro.z -= kick * (0.9 + 0.4 * audio.x);
        // autonomous drift: the scene keeps breathing even in silence;
        // phrase energy opens up the dolly travel (structure-level groove)
        ro.x += sin(time * 0.13) * (0.8 + 0.9 * slow);
        ro.y += sin(time * 0.09) * 0.15;
        ro.z += sin(time * 0.05) * (1.2 + 2.4 * slow);
        float pSway = sin(time * 0.11) * 0.02;              // micro pitch sway
        float cps = cos(pSway), sps = sin(pSway);
        dir = float3(dir.x, dir.y * cps + dir.z * sps, -dir.y * sps + dir.z * cps);

        float tRay = 0.0;
        float m = -1.0;
        for (int i = 0; i < 110; i++) {
            float3 p = ro + dir * tRay;
            float2 dm = map(p, time, audio, theme, slow, kick, accum);
            if (dm.x < 0.0015 * tRay + 0.001) { m = dm.y; break; }
            tRay += dm.x * 0.95;
            if (tRay > 70.0) break;
        }
        // S7 depth branch: free raymarch depth for the diffusion worker's
        // depth-weighted noise blending (0 = near/preserve, 1 = far/free)
        depthOut = m < -0.5 ? 1.0 : 1.0 - exp(-tRay * 0.04);

        float3 sky = skyColor(dir, time, audio, hueShift);

        float3 colOut;
        if (m < -0.5) {
            colOut = sky;
        } else if (m > 4.5) {
            // liquid blob: wrap diffuse (waxy volume) + hot specular +
            // fresnel rim with thin-edge transmission (fake SSS) + sky
            // reflection. Hue stays display-layer owned (mainHue).
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio, theme, slow, kick, accum);
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = clamp((dot(n, L) + 0.6) / 1.6, 0.0, 1.0);   // wrapped diffuse
            float3 base = hsv2rgb(fract(0.52 + hueShift + accum * 0.015), 0.85, 0.72);
            float3 hv = normalize(L - dir);
            float spec = pow(max(dot(n, hv), 0.0), 60.0) * 1.3;
            float fres = pow(1.0 - max(dot(n, -dir), 0.0), 3.0);
            float3 refl = skyColor(reflect(dir, n), time, audio, hueShift);
            colOut = base * (0.20 + 0.85 * dif)
                   + hsv2rgb(fract(0.08 + hueShift), 0.25, 1.0) * spec
                   + hsv2rgb(fract(0.02 + hueShift), 0.70, 1.0) * fres * 0.55
                   + refl * fres * 0.5;
            float fog = 1.0 - exp(-0.00065 * tRay * tRay);
            colOut = mix(colOut, sky, fog * 0.8);
        } else if (m > 3.5) {
            // equalizer column: dark basalt body + neon cap riding its audio band
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio, theme, slow, kick, accum);
            float4 col = columnField(p, time, audio, theme, melt, slow, accum);   // re-fetch cell params
            float hc = col.y, band = col.z, top = col.w;
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = max(dot(n, L), 0.0);
            // per-column hue offset keeps pillar colors diverse (richness)
            float3 body = hsv2rgb(fract(0.70 + hueShift * 0.6 + hc * 0.25 + accum * 0.007), 0.68, 0.22);
            float3 cap = hsv2rgb(fract(0.30 + hueShift + hc * 0.5 + accum * 0.017), 1.0, 1.0);
            float capGlow = exp(min((p.y - top) * 1.4, 0.0) * 1.0);  // 1 at the cap, decays down
            // rocky voronoi texture on the shaft
            float3 vv = voronoi(float2(atan2(p.z, p.x) * 3.0, p.y * 0.9), time);
            float crack = smoothstep(0.10, 0.0, vv.y);
            colOut = body * (0.25 + 0.9 * dif)
                   + cap * capGlow * (0.35 + band * 1.4)
                   + veinColorAt(hueShift + accum * 0.007, vv.z) * crack * 0.25;
            float fog = 1.0 - exp(-0.00065 * tRay * tRay);
            colOut = mix(colOut, sky, fog);
        } else if (m > 2.5) {
            // mandelbox crystal: diffuse key light + one-tap AO give it volume
            // (pure fresnel reads as a flat disc); rim glow on the counter-hue
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio, theme, slow, kick, accum);
            float3 Cc = crystalCenter(time, audio);
            float3 L = normalize(float3(0.0, 0.5, -0.8));
            float dif = max(dot(n, L), 0.0);
            float cs = crystalScale();
            float ao = clamp(crystalDE((p - Cc) / cs + n * 0.07, time, audio, melt) * cs / 0.085,
                             0.0, 1.0);
            float fres = pow(1.0 - max(dot(n, -dir), 0.0), 2.5);
            float hue = fract(0.55 + hueShift + accum * 0.013
                              + 0.20 * sin(p.y * 2.0 + time * 0.5));
            float3 cCol = hsv2rgb(hue, 0.92, 1.0);
            colOut = cCol * (0.10 + 0.65 * dif) * (0.35 + 0.65 * ao)
                   + hsv2rgb(fract(hue + 0.5), 0.8, 1.0) * fres * 0.55;
            colOut *= theme.y;                          // emotion: crystal strength
            // luminance-keyed transparency: dark facets melt into the sky,
            // turning the fractal into a glassy volume instead of a rock
            float crysLum = dot(colOut, float3(0.299, 0.587, 0.114));
            colOut = mix(sky, colOut, smoothstep(0.05, 0.38, crysLum));
            float fog = 1.0 - exp(-0.00065 * tRay * tRay);
            colOut = mix(colOut, sky, fog * 0.7);
        } else if (m > 1.5) {
            // synthwave sun: hot gradient + scanline gaps widening toward
            // bottom; scanline density/speed ride mid
            float3 p = ro + dir * tRay;
            float sunR = sunRadius(time, audio, slow);
            float yy = (p.y - sunCenter(time).y) / sunR;    // -1..1 over the disc
            float3 sun = mix(hsv2rgb(fract(0.93 + hueShift * 0.3 + accum * 0.021), 0.95, 1.0),
                             hsv2rgb(fract(0.11 + hueShift * 0.3 + accum * 0.021), 0.80, 1.0),
                             clamp(yy * 0.5 + 0.5, 0.0, 1.0));
            float gap = clamp(0.5 - yy * 0.5, 0.05, 1.0);   // wider gaps lower
            float stripe = smoothstep(gap, gap + 0.06,
                fract(p.y * (1.4 + audio.y * 0.5) - time * (0.25 + audio.y * 0.6)));
            colOut = sun * (0.35 + 1.0 * stripe) * 1.15;
            // luminance-keyed transparency: the dark scanline gaps let the
            // sky bleed through, so the sun reads as floating light bands
            float sunLum = dot(colOut, float3(0.299, 0.587, 0.114));
            colOut = mix(sky, colOut, smoothstep(0.30, 0.95, sunLum));
        } else {
            // terrain: lifted violet base (never reads pure black) + neon
            // grid + voronoi veins + ring
            float3 p = ro + dir * tRay;
            float3 n = calcNormal(p, time, audio, theme, slow, kick, accum);
            float h01 = clamp(p.y / 2.2, 0.0, 1.0);
            float3 base = mix(hsv2rgb(fract(0.75 + hueShift * 0.8 + accum * 0.005), 0.85, 0.09),
                              hsv2rgb(fract(0.83 + hueShift * 0.8 + accum * 0.005), 0.88, 0.24), h01);
            base += sky * 0.05;      // faint sky ambient floor tint

            // flowing synthwave grid: advected toward the camera (bass
            // speeds it up), swaying in x; per-cell hash picks the phase of
            // a traveling row wave that ripples along the grid lines
            float2 gridUV = p.xz + float2(sin(p.z * 0.15 + time * 0.4) * 0.3,
                                          time * (2.0 + audio.x * 0.8));
            float2 g = abs(fract(gridUV / 1.5) - 0.5);
            float line = smoothstep(0.455, 0.5, max(g.x, g.y));
            float2 cellId = floor(gridUV / 1.5);
            float rowWave = 0.5 + 0.5 * sin(time * 2.2 - (cellId.x + cellId.y) * 0.9
                                            + hash21(cellId) * 6.2831);
            float3 gridCol = mix(hsv2rgb(fract(0.52 + hueShift + accum * 0.011), 1.0, 1.0),
                                 hsv2rgb(fract(0.90 + hueShift + accum * 0.011), 0.95, 1.0),
                                 0.5 + 0.5 * sin(time * 0.3 + p.x * 0.2));

            // animated voronoi veins: per-cell rainbow hues keep palette
            // richness while the grid/sky swing globally with the music.
            // v5: beat brightness contribution removed (geometry crater stays)
            float3 v = voronoi(p.xz * 0.7 + float2(0.0, time * 0.15), time);
            float vein = smoothstep(0.12, 0.0, v.y);
            float cellPulse = 0.5 + 0.5 * sin(v.x * 6.0 - time * 2.0);
            float3 veinCol = veinColorAt(hueShift + accum * 0.007, v.z);

            // shockwave ring expands as the beat pulse decays
            float ringR = (1.0 - audio.w) * 9.0;
            float ring = exp(-abs(length(p.xz) - ringR) * 2.2) * audio.w;

            float3 L = normalize(float3(0.0, 0.5, -0.8));   // key light from the sun
            float dif = max(dot(n, L), 0.0);
            colOut = base * (0.3 + 0.9 * dif)
                   + gridCol * line * (0.45 + audio.x * 0.15) * (0.6 + 0.4 * rowWave)
                   + veinCol * vein * (0.7 + cellPulse * 0.5 + audio.x * 0.15)
                   + hsv2rgb(fract(0.95 + hueShift * 0.8), 0.80, 1.0) * ring * 1.0;
            float fog = 1.0 - exp(-0.00065 * tRay * tRay);
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
                float glow = min(0.004 / (d * d + 0.004), 1.4);   // cap below ACES shoulder: keeps hue
                colOut += hsv2rgb(fract(0.90 + hueShift * 1.4 + accum * 0.019 + h2 * 0.2), 0.80, 1.0)
                        * glow * tw * (0.4 + audio.z * 0.9) * theme.w;  // emotion: ember strength
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
        float depthDummy;
        return float4(shadeScene(ro, dir, ti.tileNDC, P.time, P.audio, P.theme,
                                 P.audioPitch, P.slowEnergy, P.kickEnv, P.accumEnergy,
                                 depthDummy), 1.0);
    }

    struct AIViewOut {
        float4 c [[color(0)]];
        float4 d [[color(1)]];
    };

    // Single-view LDR render (square staging) as diffusion img2img input,
    // MRT: color + raymarch depth (S7).
    fragment AIViewOut aiViewFS(float4 fpos [[position]], constant AIViewParams& P [[buffer(0)]]) {
        float2 uv = float2(fpos.x / P.renderSize, 1.0 - fpos.y / P.renderSize);
        float2 ndc = uv * 2.0 - 1.0;
        float off = lkgViewOffset(P.viewT, P.size, P.flip);
        float3 ro = float3(off, P.camH, P.dist);
        float3 dir = normalize(float3(ndc.x * P.fovTan, ndc.y * P.fovTan, -1.0));
        float cp = cos(P.pitch), sp = sin(P.pitch);
        dir = float3(dir.x, dir.y * cp + dir.z * sp, -dir.y * sp + dir.z * cp);
        float depth;
        float3 col = shadeScene(ro, dir, ndc, P.time, P.audio, P.theme,
                                P.audioPitch, P.slowEnergy, P.kickEnv, P.accumEnergy,
                                depth);
        AIViewOut o;
        o.c = float4(aces(col), 1.0);
        o.d = float4(depth, depth, depth, 1.0);
        return o;
    }
    """
}
