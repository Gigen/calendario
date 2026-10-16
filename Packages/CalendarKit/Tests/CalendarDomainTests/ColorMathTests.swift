import CalendarDomain
import Testing

struct ColorMathTests {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

    @Test func hsbRoundTrip() {
        for color in [RGBAColor(red: 1, green: 0.23, blue: 0.19), RGBAColor(red: 0, green: 0.48, blue: 1), RGBAColor(red: 0.2, green: 0.78, blue: 0.35)] {
            let (h, s, b) = color.hsb
            let back = RGBAColor(hue: h, saturation: s, brightness: b)
            #expect(close(back.red, color.red) && close(back.green, color.green) && close(back.blue, color.blue))
        }
    }

    @Test func pastelKeepsHueAndSoftens() {
        let red = RGBAColor(red: 1, green: 0.23, blue: 0.19)
        let soft = red.pastel()
        #expect(close(soft.hsb.hue, red.hsb.hue))
        #expect(soft.hsb.saturation < red.hsb.saturation * 0.5)
        #expect(close(soft.hsb.brightness, 0.96))
    }

    @Test func greyStaysGrey() {
        let grey = RGBAColor(red: 0.5, green: 0.5, blue: 0.5).pastel()
        #expect(close(grey.red, grey.green) && close(grey.green, grey.blue))
    }

    @Test func mixing() {
        let mixed = RGBAColor(red: 0, green: 0, blue: 0).mixed(with: RGBAColor(red: 1, green: 1, blue: 1), amount: 0.25)
        #expect(close(mixed.red, 0.25))
    }
}
