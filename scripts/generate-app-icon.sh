#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iconset_dir="$root_dir/apps/MacSystemEQApp/Assets/AppIcon.iconset"
icns_output="$root_dir/apps/MacSystemEQApp/Config/AppIcon.icns"

mkdir -p "$iconset_dir"

swift_script="$(mktemp)"
trap 'rm -f "$swift_script"' EXIT

cat > "$swift_script" <<'SWIFT'
import AppKit
import Foundation

func drawIcon(size: Int, outputURL: URL) throws {
    let dimension = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "icon-gen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap"])
    }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
        throw NSError(domain: "icon-gen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Graphics context unavailable"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }
    context.imageInterpolation = .high

    NSColor.clear.setFill()
    canvas.fill()

    let tileInset = dimension * 0.06
    let tileRect = canvas.insetBy(dx: tileInset, dy: tileInset)
    let tileRadius = dimension * 0.22

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -dimension * 0.015)
    shadow.shadowBlurRadius = dimension * 0.04
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.set()

    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)
    let backgroundGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.52, blue: 0.89, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.24, blue: 0.71, alpha: 1)
    ])!
    backgroundGradient.draw(in: tilePath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()

    let highlightRect = NSRect(
        x: tileRect.minX,
        y: tileRect.midY + dimension * 0.08,
        width: tileRect.width,
        height: tileRect.height * 0.55
    )
    let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: dimension * 0.16, yRadius: dimension * 0.16)
    NSColor.white.withAlphaComponent(0.18).setFill()
    highlightPath.fill()

    let panelInsetX = tileRect.width * 0.14
    let panelInsetBottom = tileRect.height * 0.16
    let panelHeight = tileRect.height * 0.44
    let panelRect = NSRect(
        x: tileRect.minX + panelInsetX,
        y: tileRect.minY + panelInsetBottom,
        width: tileRect.width - panelInsetX * 2,
        height: panelHeight
    )
    let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: dimension * 0.06, yRadius: dimension * 0.06)
    let panelGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.02, alpha: 0.86),
        NSColor(calibratedWhite: 0.12, alpha: 0.84)
    ])!
    panelGradient.draw(in: panelPath, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    panelPath.lineWidth = max(1, dimension * 0.008)
    panelPath.stroke()

    let barCount = 10
    let contentInsetX = panelRect.width * 0.08
    let contentInsetY = panelRect.height * 0.12
    let usableRect = NSRect(
        x: panelRect.minX + contentInsetX,
        y: panelRect.minY + contentInsetY,
        width: panelRect.width - contentInsetX * 2,
        height: panelRect.height - contentInsetY * 2
    )
    let barSpacing = usableRect.width * 0.035
    let totalSpacing = CGFloat(barCount - 1) * barSpacing
    let barWidth = (usableRect.width - totalSpacing) / CGFloat(barCount)
    let profile: [CGFloat] = [0.88, 0.74, 0.60, 0.45, 0.34, 0.36, 0.47, 0.63, 0.79, 0.66]

    for idx in 0 ..< barCount {
        let x = usableRect.minX + CGFloat(idx) * (barWidth + barSpacing)
        let barHeight = max(usableRect.height * 0.18, usableRect.height * profile[idx])
        let barRect = NSRect(
            x: x,
            y: usableRect.minY,
            width: barWidth,
            height: barHeight
        )
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth * 0.45, yRadius: barWidth * 0.45)
        let t = CGFloat(idx) / CGFloat(max(1, barCount - 1))
        let color = NSColor(
            calibratedRed: 0.16 + 0.74 * t,
            green: 0.95 - 0.40 * t,
            blue: 0.38,
            alpha: 1
        )
        color.setFill()
        barPath.fill()
    }

    let ringCenter = CGPoint(x: tileRect.maxX - dimension * 0.19, y: tileRect.maxY - dimension * 0.18)
    let ringRadius = dimension * 0.07
    let ringRect = NSRect(
        x: ringCenter.x - ringRadius,
        y: ringCenter.y - ringRadius,
        width: ringRadius * 2,
        height: ringRadius * 2
    )
    let ringPath = NSBezierPath(ovalIn: ringRect)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    ringPath.lineWidth = max(1, dimension * 0.01)
    ringPath.stroke()

    let dotRadius = ringRadius * 0.36
    let dotRect = NSRect(
        x: ringCenter.x - dotRadius,
        y: ringCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )
    let dotPath = NSBezierPath(ovalIn: dotRect)
    NSColor.white.withAlphaComponent(0.86).setFill()
    dotPath.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon-gen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    try pngData.write(to: outputURL)
}

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("usage: icon-generator.swift <iconset-dir>\n", stderr)
    exit(1)
}

let iconsetURL = URL(fileURLWithPath: args[1], isDirectory: true)
let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in outputs {
    let outputURL = iconsetURL.appendingPathComponent(name)
    try drawIcon(size: size, outputURL: outputURL)
}
SWIFT

swift "$swift_script" "$iconset_dir"
iconutil -c icns "$iconset_dir" -o "$icns_output"

echo "Generated icon set at: $iconset_dir"
echo "Generated icns at: $icns_output"
