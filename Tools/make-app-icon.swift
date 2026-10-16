// Renders the Calendario app icon at every size the asset catalog needs.
//
//   swift Tools/make-app-icon.swift Calendario/Assets.xcassets/AppIcon.appiconset
//
// The artwork is drawn in a 1024-point space following Apple's macOS icon grid
// (824-point rounded body, 100-point margin, soft drop shadow) and rendered
// separately at each size so small sizes stay sharp.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Account colors: one per account in the header band, reused for event days.
let coral = color(0xFF6B6B)
let amber = color(0xFFB020)
let green = color(0x22C55E)
let sky = color(0x38BDF8)
let indigo = color(0x4F46E5)
let ringColor = color(0x312E81)
let emptyDay = color(0xEDEFF5)

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(in ctx: CGContext) {
    // Body: the macOS rounded square with a drop shadow and an indigo gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: color(0x000000, 0.3))
    ctx.addPath(bodyPath)
    ctx.setFillColor(indigo)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x5B5BF0), color(0x7B3FE4)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Calendar page.
    let page = CGRect(x: 232, y: 262, width: 560, height: 540)
    let pagePath = roundedRect(page, 64)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x1E1B4B, 0.35))
    ctx.addPath(pagePath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Header band: four account colors side by side, clipped to the page's top corners.
    ctx.saveGState()
    ctx.addPath(pagePath)
    ctx.clip()
    let bandHeight: CGFloat = 92
    let segment = page.width / 4
    for (index, fill) in [coral, amber, green, sky].enumerated() {
        ctx.setFillColor(fill)
        ctx.fill(CGRect(x: page.minX + CGFloat(index) * segment, y: page.minY, width: segment + 1, height: bandHeight))
    }
    ctx.restoreGState()

    // Binding rings across the top edge.
    for x in [372.0, 612.0] {
        ctx.addPath(roundedRect(CGRect(x: x, y: 222, width: 40, height: 96), 20))
        ctx.setFillColor(ringColor)
        ctx.fillPath()
    }

    // Day grid: 3 rows by 4 days; a few days carry events, one holds a reminder check.
    let cell: CGFloat = 98
    let gap: CGFloat = 24
    let gridWidth = 4 * cell + 3 * gap
    let gridHeight = 3 * cell + 2 * gap
    let gridTop = page.minY + bandHeight + (page.height - bandHeight - gridHeight) / 2
    let gridLeft = page.midX - gridWidth / 2
    let eventDays: [Int: CGColor] = [1: coral, 7: green, 8: sky, 10: amber]
    let checkDay = 5

    for index in 0..<12 {
        let row = index / 4
        let column = index % 4
        let rect = CGRect(
            x: gridLeft + CGFloat(column) * (cell + gap),
            y: gridTop + CGFloat(row) * (cell + gap),
            width: cell,
            height: cell
        )
        if index == checkDay {
            ctx.setFillColor(indigo)
            ctx.fillEllipse(in: rect)
            let check = CGMutablePath()
            check.move(to: CGPoint(x: rect.minX + 0.27 * cell, y: rect.minY + 0.52 * cell))
            check.addLine(to: CGPoint(x: rect.minX + 0.44 * cell, y: rect.minY + 0.68 * cell))
            check.addLine(to: CGPoint(x: rect.minX + 0.74 * cell, y: rect.minY + 0.34 * cell))
            ctx.addPath(check)
            ctx.setStrokeColor(color(0xFFFFFF))
            ctx.setLineWidth(15)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        } else {
            ctx.addPath(roundedRect(rect, 22))
            ctx.setFillColor(eventDays[index] ?? emptyDay)
            ctx.fillPath()
        }
    }
}

func render(pixels: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "icon", code: 1) }
    ctx.interpolationQuality = .high
    // Draw top-down in the 1024-point design space.
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(in: ctx)

    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "icon", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "icon", code: 3) }
}

// MARK: - Main

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let sizes = [16, 32, 128, 256, 512]
var images: [[String: String]] = []

for size in sizes {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: size * scale, to: outputDirectory.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outputDirectory.path)")
