import Foundation

/// Metal shading language prelude for raymarched quilt scenes.
///
/// Prepend this to your scene shader source string. It provides the quilt tile
/// math so each fragment can figure out which view it belongs to and compute a
/// per-view camera ray. View 0 is the bottom-left tile; views sweep
/// left-to-right, bottom-to-top (standard Looking Glass quilt convention).
public enum LKGShaderCommon {
    public static let msl: String = """
    #include <metal_stdlib>
    using namespace metal;

    /// Per-fragment quilt tile info.
    struct LKGTileInfo {
        float viewIndex;  // 0..N-1
        float viewT;      // 0..1 sweep across all views
        float2 tileUV;    // 0..1 inside tile, y up
        float2 tileNDC;   // -1..1 inside tile, y up
    };

    /// Resolve the quilt tile a fragment belongs to.
    /// `px` is the fragment position in the quilt render target (pixel units,
    /// top-down). `tileSize` is the per-view tile size in pixels.
    static LKGTileInfo lkgTileInfo(float2 px, float2 tileSize, float cols, float rows) {
        float col  = floor(px.x / tileSize.x);
        float rowT = floor(px.y / tileSize.y);
        float row  = rows - 1.0 - rowT; // view 0 = bottom-left tile
        LKGTileInfo ti;
        ti.viewIndex = row * cols + col;
        ti.viewT = ti.viewIndex / (cols * rows - 1.0);
        float lx = (px.x - col * tileSize.x) / tileSize.x;
        float ly = 1.0 - (px.y - rowT * tileSize.y) / tileSize.y;
        ti.tileUV = float2(lx, ly);
        ti.tileNDC = float2(lx * 2.0 - 1.0, ly * 2.0 - 1.0);
        return ti;
    }

    /// Horizontal camera offset for a view (parallel off-axis quilt camera).
    static float lkgViewOffset(float viewT, float sweep, float flip) {
        return (viewT - 0.5) * sweep * flip;
    }

    /// Off-axis camera ray for raymarched content. All views are parallel;
    /// the frustum shear makes the z=0 focus plane project identically in
    /// every view.
    static float3 lkgViewRay(LKGTileInfo ti, float offset, float dist,
                             float fovTan, float tileAspect, float pitch) {
        float3 dir = normalize(float3(ti.tileNDC.x * fovTan * tileAspect - offset / dist,
                                      ti.tileNDC.y * fovTan, -1.0));
        float cp = cos(pitch), sp = sin(pitch);
        return float3(dir.x, dir.y * cp + dir.z * sp, -dir.y * sp + dir.z * cp);
    }
    """
}
