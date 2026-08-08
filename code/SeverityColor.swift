import SwiftUI
import AppKit

/// Maps a metric's value to a color along green → blue → orange → pink → red,
/// so you can read "how bad is this" at a glance without reading the number.
enum Severity {

    /// For 0–100 percent metrics (CPU, GPU, Memory).
    static func color(forPercent value: Double) -> Color {
        colorForNormalized(value / 100)
    }
    
    static func color(forBytes bytes: UInt64) -> Color {
            let mb = Double(bytes) / 1_048_576
            let minMB = 50.0
            let maxMB = 3000.0
            let clamped = min(max(mb, minMB), maxMB)
            let t = (log2(clamped) - log2(minMB)) / (log2(maxMB) - log2(minMB))
            return colorForNormalized(t)
        }

    /// For Celsius temperatures. Calibrated for typical laptop/desktop CPU/GPU
    /// ranges: comfortable below ~50°C, genuinely hot above ~90°C.
    static func color(forCelsius value: Double) -> Color {
        let normalized = (value - 30) / (95 - 30) // 30°C → 0, 95°C → 1
        return colorForNormalized(normalized)
    }

    /// For powermetrics' thermal_pressure levels.
    static func color(forThermalPressure pressure: String?) -> Color {
        switch pressure {
        case "Nominal": return .green
        case "Moderate": return .blue
        case "Heavy": return .orange
        case "Trapping": return .pink
        case "Sleeping": return .red
        default: return .secondary
        }
    }

    private static func colorForNormalized(_ raw: Double) -> Color {
        let t = min(max(raw, 0), 1)
        let stops: [(Double, NSColor)] = [
            (0.0, .systemGreen),
            (0.25, .systemBlue),
            (0.5, .systemOrange),
            (0.75, .systemPink),
            (1.0, .systemRed)
        ]
        for i in 0..<(stops.count - 1) {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            if t <= t1 {
                let localT = t1 > t0 ? (t - t0) / (t1 - t0) : 0
                return Color(lerp(c0, c1, localT))
            }
        }
        return Color(stops.last!.1)
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let ca = a.usingColorSpace(.deviceRGB) ?? a
        let cb = b.usingColorSpace(.deviceRGB) ?? b
        let r = ca.redComponent + (cb.redComponent - ca.redComponent) * t
        let g = ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t
        let bl = ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t
        return NSColor(red: r, green: g, blue: bl, alpha: 1)
    }
}
