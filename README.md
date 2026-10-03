# lkg-metal-quilt

Real-time quilt rendering for Looking Glass light field displays, in pure Swift + Metal.

Renders an animated scene into a multi-view quilt every frame, interlaces it with the
device's factory optical calibration, and displays it fullscreen on the panel —
no Unity, no web stack, ~60 FPS on Apple Silicon.

| Quilt (66 views, 11x6) | Interlaced panel image |
|---|---|
| ![quilt](docs/example-quilt.jpg) | ![lenticular](docs/example-lenticular.jpg) |

Verified on Looking Glass Go (LKG-E10707) + Apple M5 Max @ 60 FPS, GPU ~9.5 ms/frame
at full 4092x4092 quilt resolution.

## How it works

1. **Quilt render** — the scene renders all views into one large quilt texture
   (e.g. 4092x4092 = 11x6 tiles of 372x682). View 0 is the bottom-left tile.
   The included demo is a raymarched shadertoy-style scene: a single fullscreen
   triangle where each fragment resolves its tile via `lkgTileInfo()` and casts
   a view ray from a parallel off-axis camera. Rasterized (mesh) content can use
   `QuiltCamera`'s per-view off-axis projection matrices instead.
2. **Lenticular interlace** — a post-process shader (ported from the official
   holoplay.js `QUILT_FRAGMENT_SHADER`) samples the quilt per RGB subpixel using
   the display's unique calibration (pitch / slope / center / DPI), producing the
   image the lenticular lens array turns into 3D.
3. **Calibration** — fetched live from a running
   [Looking Glass Bridge](https://lookingglassfactory.com/software) via its REST
   API (`PUT http://localhost:33334/...`). Falls back to built-in values for one
   specific LKG Go unit when Bridge is unavailable.

## Requirements

- macOS on Apple Silicon (tested on M5 Max, macOS 26/27)
- Swift toolchain — Command Line Tools is enough (shaders are compiled at
  runtime; no Xcode needed)
- A Looking Glass display connected as a screen
- [Looking Glass Bridge](https://lookingglassfactory.com/software) running
  (for exact per-device calibration; optional but recommended)

## Run the demo

```sh
swift run -c release lkg-demo                 # live: fullscreen on LKG + preview window
swift run -c release lkg-demo -- --no-preview # device only
```

Keys (focus the preview window first):

| Key | Action |
|---|---|
| `q` | quit |
| `s` / `S` | save quilt PNG / interlaced PNG to current directory |
| `f` | flip parallax direction (if the image looks inside-out) |
| `-` `=` | camera sweep (parallax amount) |
| `[` `]` | camera distance |
| `9` `0` | field of view |
| `1` / `2` | full / half resolution quilt render |
| `p` | pause animation |
| `b` | bypass interlace (show raw quilt on device, for debugging) |
| `c` | calibration test pattern — flat hue per view; on the device the panel should show one uniform color that sweeps hue as you move your head |

Offline frame export:

```sh
swift run -c release lkg-demo -- --dump quilt_qs11x6a0.56.png --time 1.2
swift run -c release lkg-demo -- --dump-lentic lenticular.png
```

Quilt PNGs follow the QuiltPlayer naming convention and can be opened in
QuiltPlayer / Looking Glass Studio directly.

## Use as a library (SwiftPM)

```swift
// Package.swift
.package(url: "https://github.com/Jup33Q/lkg-metal-quilt.git", from: "0.1.0")
```

```swift
import LKGQuilt

let app = try LKGApp(spec: .lkgGo)        // finds the LKG screen, fetches calibration
app.onRenderQuilt = { cmd, pass, time in
    // encode your scene into the quilt pass here
}
app.onKey = { key in false }              // custom keys
app.onStatusLine = { "my params" }        // extra text in the FPS log line
app.run()
```

### Writing your own raymarched scene

Prepend `LKGShaderCommon.msl` to your fragment shader source; it provides:

- `lkgTileInfo(px, tileSize, cols, rows)` — which view this fragment belongs to
  (view index, 0..1 sweep position, per-tile UV/NDC)
- `lkgViewOffset(viewT, sweep, flip)` — camera offset for the view
- `lkgViewRay(tileInfo, offset, dist, fovTan, tileAspect, pitch)` — off-axis
  camera ray (focus plane at z = 0)

Then render one fullscreen triangle into `renderer.makeQuiltPassDescriptor()`
with an `rgba16Float` target. See `Sources/lkg-demo/BlockCityScene.swift` for a
complete example.

### Lower-level API

- `QuiltSpec` — quilt grid layout (`.lkgGo`, `.lkgPortrait`, custom)
- `Calibration.fetchFromBridge()` — live device calibration via Bridge REST API
- `Calibration.lenticularUniforms(columns:rows:)` — interlace shader uniforms
- `QuiltRenderer` — quilt target + tonemap/interlace/test-pattern passes,
  `saveQuiltPNG` / `saveLenticularPNG` offline export
- `QuiltCamera` / `Matrix4x4` — off-axis projection math for mesh content
- `LKGApp.findLKGScreen()` — locate the LKG display

## Performance notes

Measured on Apple M5 Max, Looking Glass Go, full 4092x4092 quilt:

| Stage | GPU time |
|---|---|
| Scene raymarch (66 views, demo content) | ~9 ms |
| Lenticular interlace (1440x2560) | sub-ms (dwarfs under vsync pacing) |
| Total frame rate | 60 FPS (vsync-locked) |

The interlace pass reads the full quilt texture with scattered tile access;
keep the quilt as rgba16Float in private storage and avoid extra copies.

## License

MIT
