import Foundation

/// Quilt layout specification for a Looking Glass display.
///
/// A quilt is a single large image tiled with `columns x rows` views of a scene.
/// View 0 is the bottom-left tile; views sweep left-to-right, bottom-to-top.
public struct QuiltSpec: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var tileWidth: Int
    public var tileHeight: Int
    /// Device screen aspect (width/height), used in QuiltPlayer file naming (`a0.56` etc).
    public var screenAspect: Float

    public init(columns: Int, rows: Int, tileWidth: Int, tileHeight: Int, screenAspect: Float) {
        self.columns = columns
        self.rows = rows
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.screenAspect = screenAspect
    }

    public var viewCount: Int { columns * rows }
    public var width: Int { columns * tileWidth }
    public var height: Int { rows * tileHeight }
    public var tileAspect: Float { Float(tileWidth) / Float(tileHeight) }

    /// QuiltPlayer-style file suffix, e.g. `_qs11x6a0.56`.
    public var namingSuffix: String {
        String(format: "_qs%dx%da%.2f", columns, rows, screenAspect)
    }

    /// Looking Glass Go (verified on-device): 4092x4092, 11x6 = 66 views of 372x682.
    public static let lkgGo = QuiltSpec(columns: 11, rows: 6, tileWidth: 372, tileHeight: 682, screenAspect: 0.5625)

    /// Looking Glass Portrait: 3360x3360, 8x6 = 48 views of 420x560.
    public static let lkgPortrait = QuiltSpec(columns: 8, rows: 6, tileWidth: 420, tileHeight: 560, screenAspect: 0.75)

    /// Looking Glass 16": 7680x7680, 9x16 = 144 views of 480x853 (quilt 4320x7680 native; this is the common 2x variant).
    public static let lkg16 = QuiltSpec(columns: 9, rows: 16, tileWidth: 480, tileHeight: 853, screenAspect: 0.5625)
}
