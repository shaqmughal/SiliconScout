#!/usr/bin/env swift
// Generates SiliconScout.app icon PNGs at all required macOS sizes.
// Run from the repo root: swift scripts/generate-icon.swift
import AppKit
import CoreGraphics

let outputDir = "Sources/SiliconScoutApp/Assets.xcassets/AppIcon.appiconset"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func drawIcon(ctx: CGContext, s: CGFloat) {
    // ── Background gradient (indigo → purple) ──────────────────────────────
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.14, 0.22, 0.62), color(0.38, 0.14, 0.60)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
        start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // ── Chip body ───────────────────────────────────────────────────────────
    let inset  = s * 0.22
    let chip   = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cRad   = chip.width * 0.16
    let stroke = s * 0.028

    ctx.setStrokeColor(color(1, 1, 1, 0.95))
    ctx.setLineWidth(stroke)
    let chipPath = CGMutablePath()
    chipPath.addRoundedRect(in: chip, cornerWidth: cRad, cornerHeight: cRad)
    ctx.addPath(chipPath)
    ctx.strokePath()

    // Inner grid (subtle)
    ctx.setStrokeColor(color(1, 1, 1, 0.28))
    ctx.setLineWidth(s * 0.016)
    ctx.move(to: CGPoint(x: s * 0.5, y: chip.minY + stroke))
    ctx.addLine(to: CGPoint(x: s * 0.5, y: chip.maxY - stroke))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: chip.minX + stroke, y: s * 0.5))
    ctx.addLine(to: CGPoint(x: chip.maxX - stroke, y: s * 0.5))
    ctx.strokePath()

    // ── Pins (3 per side) ──────────────────────────────────────────────────
    ctx.setFillColor(color(1, 1, 1, 0.90))
    let pinLen = s * 0.082
    let pinW   = s * 0.030
    let n      = 3

    func pins(vertical: Bool, leading: Bool) {
        let span  = vertical ? chip.height : chip.width
        let step  = span / CGFloat(n + 1)
        let base  = vertical ? chip.minY : chip.minX
        for i in 1...n {
            let off = base + step * CGFloat(i)
            let r: CGRect
            if vertical {
                r = CGRect(
                    x: leading ? chip.minX - pinLen : chip.maxX,
                    y: off - pinW / 2, width: pinLen, height: pinW)
            } else {
                r = CGRect(
                    x: off - pinW / 2,
                    y: leading ? chip.minY - pinLen : chip.maxY,
                    width: pinW, height: pinLen)
            }
            ctx.fill(r)
        }
    }
    pins(vertical: false, leading: false) // top
    pins(vertical: false, leading: true)  // bottom
    pins(vertical: true,  leading: true)  // left
    pins(vertical: true,  leading: false) // right

    // ── Magnifying glass (bottom-right quadrant) ───────────────────────────
    let mgCX   = s * 0.590
    let mgCY   = s * 0.415
    let mgR    = s * 0.108
    let mgW    = s * 0.040
    let hLen   = s * 0.110
    let angle  = -CGFloat.pi / 4

    ctx.setStrokeColor(color(1, 1, 1, 0.95))
    ctx.setLineWidth(mgW)
    ctx.setLineCap(.round)
    ctx.addEllipse(in: CGRect(x: mgCX - mgR, y: mgCY - mgR, width: mgR * 2, height: mgR * 2))
    ctx.strokePath()

    let hx1 = mgCX + cos(angle) * (mgR + mgW * 0.3)
    let hy1 = mgCY + sin(angle) * (mgR + mgW * 0.3)
    ctx.move(to: CGPoint(x: hx1, y: hy1))
    ctx.addLine(to: CGPoint(x: hx1 + cos(angle) * hLen,
                             y: hy1 + sin(angle) * hLen))
    ctx.strokePath()
}

func generate(size: Int) -> Data {
    let s   = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Clip to rounded rect (macOS rounds at ~22 % of width)
    let rr = CGMutablePath()
    rr.addRoundedRect(in: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: s * 0.22, cornerHeight: s * 0.22)
    ctx.addPath(rr); ctx.clip()

    drawIcon(ctx: ctx, s: s)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// macOS requires these seven pixel sizes
let sizes = [16, 32, 64, 128, 256, 512, 1024]

try FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true)

for px in sizes {
    let data = generate(size: px)
    let path = "\(outputDir)/AppIcon-\(px).png"
    try data.write(to: URL(fileURLWithPath: path))
    print("  \(path)")
}

// Contents.json for Xcode asset catalog
let json = """
{
  "images" : [
    { "idiom":"mac","scale":"1x","size":"16x16",   "filename":"AppIcon-16.png"   },
    { "idiom":"mac","scale":"2x","size":"16x16",   "filename":"AppIcon-32.png"   },
    { "idiom":"mac","scale":"1x","size":"32x32",   "filename":"AppIcon-32.png"   },
    { "idiom":"mac","scale":"2x","size":"32x32",   "filename":"AppIcon-64.png"   },
    { "idiom":"mac","scale":"1x","size":"128x128", "filename":"AppIcon-128.png"  },
    { "idiom":"mac","scale":"2x","size":"128x128", "filename":"AppIcon-256.png"  },
    { "idiom":"mac","scale":"1x","size":"256x256", "filename":"AppIcon-256.png"  },
    { "idiom":"mac","scale":"2x","size":"256x256", "filename":"AppIcon-512.png"  },
    { "idiom":"mac","scale":"1x","size":"512x512", "filename":"AppIcon-512.png"  },
    { "idiom":"mac","scale":"2x","size":"512x512", "filename":"AppIcon-1024.png" }
  ],
  "info" : { "author":"xcode","version":1 }
}
"""
try json.write(
    toFile: "\(outputDir)/Contents.json",
    atomically: true, encoding: .utf8)
print("  \(outputDir)/Contents.json")
print("Done.")
