#!/usr/bin/env swift
// Composites a window screenshot (with alpha shadow) onto a gradient backdrop —
// the "nice screenshot" treatment for site images. Capture the input with
// scripts/screenshot.swift, which preserves the shadow alpha this expects.
// Usage: swift scripts/beautify.swift <in.png> <out.png>

import AppKit

guard CommandLine.arguments.count == 3 else {
  print("usage: beautify.swift <in.png> <out.png>")
  exit(1)
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inputURL),
  let rep = image.representations.first as? NSBitmapImageRep
else {
  print("could not read \(inputURL.path)")
  exit(1)
}
let shotW = rep.pixelsWide
let shotH = rep.pixelsHigh

// Padding proportional to the shot, capped for consistency across sizes.
let pad = min(max(Int(Double(min(shotW, shotH)) * 0.07), 72), 140)
let outW = shotW + pad * 2
let outH = shotH + pad * 2

let out = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)

// Brand gradient (matches the site's accent colors), angled.
let gradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.24, green: 0.36, blue: 0.86, alpha: 1),
  NSColor(calibratedRed: 0.42, green: 0.23, blue: 0.86, alpha: 1),
  NSColor(calibratedRed: 0.58, green: 0.25, blue: 0.78, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH), angle: -35)

// The captured window already carries macOS corner radius + shadow in its alpha.
let dest = NSRect(x: pad, y: pad, width: shotW, height: shotH)
rep.draw(
  in: dest, from: .zero, operation: .sourceOver, fraction: 1.0,
  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

NSGraphicsContext.restoreGraphicsState()
guard let data = out.representation(using: .png, properties: [:]) else {
  print("encode failed")
  exit(1)
}
try! data.write(to: outputURL)
print("wrote \(outputURL.path) (\(outW)x\(outH))")
