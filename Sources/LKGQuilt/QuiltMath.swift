import simd

/// Camera math for quilt generation with rasterized (mesh) content.
///
/// Quilt views use parallel off-axis cameras: all view directions are parallel,
/// the camera translates horizontally, and the projection frustum is sheared so
/// that the focus plane (z = 0) projects identically in every view. Objects on
/// the focus plane appear at screen depth; in front/behind they pop out/into
/// the display volume.
///
/// For raymarched (per-fragment) content you don't need matrices — use the
/// `lkgTileInfo()` / `lkgViewOffset()` helpers from `LKGShaderCommon.msl`
/// directly in your fragment shader instead.
public struct QuiltCamera: Sendable {
    /// Total camera travel across all views, in world units. Roughly the width
    /// of the subject gives comfortable parallax on a Looking Glass Go.
    public var sweep: Float
    /// Camera distance from the focus plane.
    public var distance: Float
    /// Vertical field of view in radians.
    public var fovY: Float
    /// Parallax direction: 1 or -1 (flip if the image looks inside-out).
    public var flip: Float

    public init(sweep: Float = 2.5, distance: Float = 13, fovY: Float = 25 * .pi / 180, flip: Float = 1) {
        self.sweep = sweep
        self.distance = distance
        self.fovY = fovY
        self.flip = flip
    }

    /// Horizontal camera offset for view `index` of `viewCount`.
    public func viewOffset(index: Int, viewCount: Int) -> Float {
        let t = viewCount > 1 ? Float(index) / Float(viewCount - 1) : 0.5
        return (t - 0.5) * sweep * flip
    }

    /// Off-center perspective projection (Metal clip conventions, z in [0, 1]).
    /// The frustum shear keeps the focus plane centered for the given offset.
    public func projectionMatrix(tileAspect: Float, near: Float = 0.1, far: Float = 100,
                                 viewOffset: Float) -> float4x4 {
        let f = 1 / tan(fovY * 0.5)
        let shiftX = -viewOffset * f / (tileAspect * distance)
        return float4x4(columns: (
            SIMD4(f / tileAspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(shiftX, 0, far / (near - far), -1),
            SIMD4(0, 0, far * near / (near - far), 0)
        ))
    }

    /// View matrix: camera at (viewOffset, 0, distance) looking down -z.
    public func viewMatrix(viewOffset: Float) -> float4x4 {
        Matrix4x4.translation(SIMD3(-viewOffset, 0, -distance))
    }
}

/// Minimal float4x4 helpers (column-major, simd conventions).
public enum Matrix4x4 {
    public static func translation(_ v: SIMD3<Float>) -> float4x4 {
        float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
            SIMD4(v.x, v.y, v.z, 1)
        ))
    }

    public static func rotationY(_ a: Float) -> float4x4 {
        float4x4(columns: (
            SIMD4(cos(a), 0, -sin(a), 0), SIMD4(0, 1, 0, 0),
            SIMD4(sin(a), 0, cos(a), 0), SIMD4(0, 0, 0, 1)
        ))
    }

    public static func rotationX(_ a: Float) -> float4x4 {
        float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0),
            SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, 0, 1)
        ))
    }

    public static func scale(_ s: Float) -> float4x4 {
        float4x4(columns: (
            SIMD4(s, 0, 0, 0), SIMD4(0, s, 0, 0), SIMD4(0, 0, s, 0), SIMD4(0, 0, 0, 1)
        ))
    }
}
