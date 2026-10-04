import Foundation
import simd

/// Uniform block consumed by the lenticular interlace shader.
/// Layout must match `LKGLenticularParams` in LKGFixedShaders.
public struct LenticularUniforms {
    public var pitch: Float = 0
    public var tilt: Float = 0
    public var center: Float = 0
    public var subp: Float = 0
    public var invView: Float = 0
    public var tilesX: Float = 11
    public var tilesY: Float = 6
    public var screenW: Float = 1440
    public var screenH: Float = 2560
    /// Full-sweep horizontal shift of the overlay layer, as a fraction of screen
    /// width. Positive pops the overlay out of the screen (flip sign to recess).
    public var overlayShift: Float = 0
    /// 1 when an overlay texture is bound.
    public var hasOverlay: Float = 0

    public init() {}
}

/// Optical calibration of a Looking Glass display (unique per unit, factory-measured).
///
/// Values are fetched live from a running Looking Glass Bridge via its REST API
/// (`http://localhost:33334`). The derivation of shader uniforms follows the
/// official holoplay.js `updateCalibration()`:
///
///     pitch' = pitch * (screenW / DPI) * cos(atan(1 / slope))
///     tilt'  = screenH / (screenW * slope)   (negated if flipImageX)
///     subp   = 1 / (screenW * 3)
public struct Calibration: Sendable {
    public var pitch: Double
    public var slope: Double
    public var center: Double
    public var dpi: Double
    public var invView: Double
    public var flipImageX: Double
    public var screenW: Double
    public var screenH: Double
    public var serial: String

    public init(pitch: Double, slope: Double, center: Double, dpi: Double,
                invView: Double, flipImageX: Double,
                screenW: Double, screenH: Double, serial: String) {
        self.pitch = pitch
        self.slope = slope
        self.center = center
        self.dpi = dpi
        self.invView = invView
        self.flipImageX = flipImageX
        self.screenW = screenW
        self.screenH = screenH
        self.serial = serial
    }

    /// Fallback values for a specific LKG Go unit (serial LKG-E10707), used when
    /// Looking Glass Bridge is not reachable.
    public static let lkgGoFallback = Calibration(
        pitch: 80.72404524405245, slope: -6.628277216522679, center: 0.406017497961845,
        dpi: 491, invView: 1, flipImageX: 0,
        screenW: 1440, screenH: 2560, serial: "LKG-E10707-fallback")

    /// Derive interlace shader uniforms for a given quilt grid.
    public func lenticularUniforms(columns: Int = 11, rows: Int = 6) -> LenticularUniforms {
        var lp = LenticularUniforms()
        let screenInches = Float(screenW / dpi)
        lp.pitch = Float(pitch) * screenInches * cos(atan(1.0 / Float(slope)))
        lp.tilt = Float(screenH / (screenW * slope))
        if flipImageX == 1 { lp.tilt *= -1 }
        lp.center = Float(center)
        lp.subp = 1.0 / (Float(screenW) * 3.0)
        lp.invView = Float(invView)
        lp.tilesX = Float(columns)
        lp.tilesY = Float(rows)
        lp.screenW = Float(screenW)
        lp.screenH = Float(screenH)
        return lp
    }

    /// Query the first connected Looking Glass display from a running Bridge.
    /// Returns nil if Bridge is not running or no device is connected.
    public static func fetchFromBridge(bridgeURL: String = "http://localhost:33334") -> Calibration? {
        func put(_ endpoint: String, _ body: [String: Any]) -> [String: Any]? {
            guard let url = URL(string: "\(bridgeURL)/\(endpoint)") else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 5
            var result: [String: Any]?
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 8)
            return result
        }
        func val(_ d: [String: Any]?, _ key: String) -> Any? {
            (d?[key] as? [String: Any])?["value"]
        }
        guard let orch = put("enter_orchestration", ["name": "lkg-metal-quilt"]),
              let token = val(orch, "payload") as? String,
              let devs = put("available_output_devices", ["orchestration": token]),
              let payload = devs["payload"] as? [String: Any],
              let devMap = payload["value"] as? [String: Any] else { return nil }

        for (_, devAny) in devMap {
            guard let dev = (devAny as? [String: Any])?["value"] as? [String: Any],
                  let hwid = val(dev, "hwid") as? String, hwid.contains("LKG"),
                  let calStr = val(dev, "calibration") as? String, !calStr.isEmpty,
                  let calData = calStr.data(using: .utf8),
                  let cal = try? JSONSerialization.jsonObject(with: calData) as? [String: Any]
            else { continue }
            func num(_ key: String) -> Double? {
                ((cal[key] as? [String: Any])?["value"] as? NSNumber)?.doubleValue
            }
            guard let pitch = num("pitch"), let slope = num("slope"),
                  let center = num("center"), let dpi = num("DPI"),
                  let screenW = num("screenW"), let screenH = num("screenH")
            else { continue }
            return Calibration(
                pitch: pitch, slope: slope, center: center, dpi: dpi,
                invView: num("invView") ?? 0, flipImageX: num("flipImageX") ?? 0,
                screenW: screenW, screenH: screenH,
                serial: (cal["serial"] as? String) ?? hwid)
        }
        return nil
    }
}
