import Foundation

/// Fixed post-processing shaders (tonemap blit, lenticular interlace,
/// calibration test pattern), compiled at runtime.
///
/// Runtime compilation keeps the package buildable with plain Command Line
/// Tools — no Xcode `metal` compiler required.
enum LKGFixedShaders {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    // Uniform block mirroring LenticularUniforms (Swift).
    struct LKGLenticularParams {
        float pitch, tilt, center, subp, invView, tilesX, tilesY, screenW, screenH;
    };

    struct LKGTestPatternParams {
        float2 tileSize;
        float cols, rows;
    };

    struct LKGTileBlitParams {
        float2 tileOrigin;  // pixel origin (top-left) of the tile in the quilt target
        float2 tileSize;    // tile size in the quilt target
        float2 cropOrigin;  // center-crop origin in the source texture
        float2 cropSize;    // crop size in the source texture
        float2 srcSize;
    };

    vertex float4 lkgFullscreenVS(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    static float3 lkgTonemap(float3 c) {
        c = clamp(c, 0.0, 16.0);
        c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14); // ACES approx
        return pow(c, float3(1.0 / 2.2));
    }

    static float3 lkgHsv2rgb(float h, float s, float v) {
        float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
        float3 p = abs(fract(float3(h) + k) * 6.0 - 3.0);
        return v * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
    }

    /// Tonemapped blit of the HDR quilt texture (preview window / PNG export).
    fragment float4 lkgTonemapFS(float4 fpos [[position]], texture2d<float> tex [[texture(0)]],
                                 constant float2& destSize [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = fpos.xy / destSize;
        return float4(lkgTonemap(tex.sample(s, uv).rgb), 1.0);
    }

    /// Lenticular interlace: the "Looking Glass optical transformation".
    /// Ported from the official holoplay.js QUILT_FRAGMENT_SHADER.
    ///
    /// Quilt convention: view 0 = bottom-left tile (GL-style v-up). Metal texture
    /// v is top-down, so the quilt sample flips v at the end.
    fragment float4 lkgLenticularFS(float4 fpos [[position]],
                                    constant LKGLenticularParams& LP [[buffer(0)]],
                                    texture2d<float> quilt [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = float2(fpos.x / LP.screenW, 1.0 - fpos.y / LP.screenH); // GL-style, y up
        float3 outCol;
        for (int i = 0; i < 3; i++) {
            float z = (uv.x + float(i) * LP.subp + uv.y * LP.tilt) * LP.pitch - LP.center;
            z = fract(z);
            z = (1.0 - LP.invView) * z + LP.invView * (1.0 - z);
            float view = floor(z * LP.tilesX * LP.tilesY);
            float tx = fmod(view, LP.tilesX);
            float ty = floor(view / LP.tilesX);
            float2 q = float2((tx + uv.x) / LP.tilesX, (ty + uv.y) / LP.tilesY);
            q.y = 1.0 - q.y; // Metal texture v flip
            outCol[i] = lkgTonemap(quilt.sample(s, q).rgb)[i];
        }
        return float4(outCol, 1.0);
    }

    /// Calibration test pattern: each view gets a flat hue.
    /// On the device, with correct interlacing, the whole panel appears as one
    /// uniform color that sweeps hue as you move your head; misalignment shows
    /// up as static rainbow banding.
    fragment float4 lkgTestPatternFS(float4 fpos [[position]],
                                     constant LKGTestPatternParams& P [[buffer(0)]]) {
        float col = floor(fpos.x / P.tileSize.x);
        float rowT = floor(fpos.y / P.tileSize.y);
        float row = P.rows - 1.0 - rowT;
        float idx = row * P.cols + col;
        return float4(lkgHsv2rgb(fract(idx / (P.cols * P.rows)), 0.85, 1.4), 1.0);
    }

    /// Per-tile update blit: samples an LDR sRGB source (e.g. a stylized view
    /// image) with center-crop, converts to linear, writes into the HDR quilt.
    /// The render pass must be scoped to the tile rect via viewport+scissor.
    fragment float4 lkgTileBlitFS(float4 fpos [[position]],
                                  constant LKGTileBlitParams& P [[buffer(0)]],
                                  texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 t = (fpos.xy - P.tileOrigin) / P.tileSize; // 0..1, y down
        float2 uv = (P.cropOrigin + t * P.cropSize) / P.srcSize;
        float3 c = src.sample(s, uv).rgb;
        return float4(pow(max(c, 0.0), float3(2.2)), 1.0);
    }
    """
}
