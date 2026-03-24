#!/usr/bin/env swift
import AppKit

// Generate a LED dot-matrix style app icon for ScrollBar
func generateIcon(size: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    let s = CGFloat(size)

    // Background: dark rounded rect
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).setFill()
    bgPath.fill()

    // Inner border glow
    let innerRect = bgRect.insetBy(dx: s * 0.03, dy: s * 0.03)
    let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: s * 0.15, yRadius: s * 0.15)
    NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0).setFill()
    innerPath.fill()

    // Draw LED dot grid
    let margin = s * 0.08
    let gridArea = s - margin * 2
    let dotRows = 16
    let dotCols = 16
    let cellW = gridArea / CGFloat(dotCols)
    let cellH = gridArea / CGFloat(dotRows)
    let dotRadius = min(cellW, cellH) * 0.32

    // "SB" pattern in a 16x16 grid (stylized)
    let pattern: [[Int]] = [
        //0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0], // 0
        [0,0,1,1,1,1,0,0,0,1,1,1,1,0,0,0], // 1
        [0,1,1,0,0,0,0,0,0,1,0,0,1,1,0,0], // 2
        [0,1,1,0,0,0,0,0,0,1,0,0,0,1,0,0], // 3
        [0,0,1,1,1,0,0,0,0,1,1,1,1,0,0,0], // 4
        [0,0,0,0,1,1,0,0,0,1,0,0,1,1,0,0], // 5
        [0,0,0,0,0,1,0,0,0,1,0,0,0,1,0,0], // 6
        [0,1,1,1,1,0,0,0,0,1,1,1,1,0,0,0], // 7
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0], // 8
        [0,0,2,2,2,2,2,2,2,2,2,2,2,2,0,0], // 9  - scrolling bar (amber)
        [0,0,2,2,2,2,2,2,2,2,2,2,2,2,0,0], // 10
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0], // 11
        [0,0,3,3,0,4,4,0,3,3,0,4,4,0,0,0], // 12 - small colored indicators
        [0,0,3,3,0,4,4,0,3,3,0,4,4,0,0,0], // 13
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0], // 14
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0], // 15
    ]

    // Colors: 0=off, 1=green(white), 2=amber, 3=red, 4=blue
    let colors: [Int: NSColor] = [
        1: NSColor(red: 0.85, green: 0.95, blue: 0.85, alpha: 1.0),  // green-white
        2: NSColor(red: 1.0, green: 0.75, blue: 0.1, alpha: 1.0),    // amber
        3: NSColor(red: 1.0, green: 0.2, blue: 0.15, alpha: 1.0),    // red
        4: NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0),     // blue
    ]

    for row in 0..<dotRows {
        for col in 0..<dotCols {
            let cx = margin + CGFloat(col) * cellW + cellW / 2
            let cy = s - (margin + CGFloat(row) * cellH + cellH / 2)
            let dotRect = CGRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

            let val = pattern[row][col]
            if val > 0, let color = colors[val] {
                // Glow
                let glowRect = dotRect.insetBy(dx: -dotRadius * 0.7, dy: -dotRadius * 0.7)
                ctx.setFillColor(color.withAlphaComponent(0.25).cgColor)
                ctx.fillEllipse(in: glowRect)
                // Dot
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: dotRect)
                // Highlight
                let hlRect = dotRect.insetBy(dx: dotRadius * 0.3, dy: dotRadius * 0.3)
                ctx.setFillColor(color.withAlphaComponent(0.6).blended(withFraction: 0.4, of: .white)!.cgColor)
                ctx.fillEllipse(in: hlRect)
            } else {
                // Dim unlit dot
                ctx.setFillColor(NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).cgColor)
                ctx.fillEllipse(in: dotRect)
            }
        }
    }

    img.unlockFocus()
    return img
}

// Generate multiple sizes for .icns
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconDir = "/tmp/ScrollBar.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconDir)
try! fm.createDirectory(atPath: iconDir, withIntermediateDirectories: true)

for size in sizes {
    let img = generateIcon(size: size)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }

    let filename: String
    if size <= 512 {
        // icon_16x16.png, icon_16x16@2x.png, etc.
        try! png.write(to: URL(fileURLWithPath: "\(iconDir)/icon_\(size)x\(size).png"))
        // Also write as @2x of half size
        let half = size / 2
        if half >= 16 {
            try! png.write(to: URL(fileURLWithPath: "\(iconDir)/icon_\(half)x\(half)@2x.png"))
        }
    }
    if size == 1024 {
        try! png.write(to: URL(fileURLWithPath: "\(iconDir)/icon_512x512@2x.png"))
    }
}

// Convert iconset to icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconDir, "-o", "/Users/suknamgoong/scroll/ScrollBar/AppIcon.icns"]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("AppIcon.icns generated successfully!")
} else {
    print("Error generating icns (status: \(process.terminationStatus))")
}
