import Foundation

// Pure color math for themes. Kept here (not in the UI) so it's testable and portable.

extension RGBAColor {
    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = min(max(saturation, 0), 1)
        let v = min(max(brightness, 0), 1)
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// Hue, saturation and brightness, each 0...1.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxValue == 0 ? 0 : delta / maxValue, maxValue)
    }

    /// A soft version with the same hue: much less saturated and bright. Greys stay grey.
    public func pastel(saturationScale: Double = 0.42, brightness: Double = 0.96) -> RGBAColor {
        let (h, s, _) = hsb
        return RGBAColor(hue: h, saturation: s * saturationScale, brightness: brightness, alpha: alpha)
    }

    /// Linear blend: 0 is `self`, 1 is `other`.
    public func mixed(with other: RGBAColor, amount: Double) -> RGBAColor {
        let t = min(max(amount, 0), 1)
        return RGBAColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }
}
