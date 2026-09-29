#!/usr/bin/env swift  // Pixel tools for the design loop, with no dependencies beyond AppKit — the  // same shape as beautify.swift and screenshot.swift. Three commands:
//
//   swift scripts/design-diff.swift crop <in.png> <out.png> [--expect-height <px>]
//       Cuts the keyboard out of a whole-screen simulator capture: finds the
//       magenta (#FF00FF) registration border the gallery's -BlurtGalleryBare
//       mode draws round the row and writes what is inside it. With
//       --expect-height, fails unless the crop is that tall (±1 px).
//
//   swift scripts/design-diff.swift diff <a.png> <b.png> --out <triptych.png> --json <metrics.json>
//       [--mask x,y,w,h]... [--threshold 8]
//       Compares two same-sized images pixel by pixel, both converted to sRGB
//       first (a simulator capture carries the display's profile, a Figma
//       export is sRGB). Reports, for the whole image and for everything
//       outside the masks, the fraction of pixels whose largest channel
//       difference exceeds the threshold (AE) and the root-mean-square
//       difference (RMSE, 0–1); each mask is reported on its own. Writes a
//       triptych: a | b | heat map (difference in red, masks tinted blue).
//       Masks are in pixels of the images given.
//
//   swift scripts/design-diff.swift sheet --out <sheet.png> --columns <n> [--scale <f>] <caption>=<png>...
//       A contact sheet: the images in a grid with their captions under them.
//
// Every image is read into an 8-bit sRGB RGBA buffer through CoreGraphics, so
// the numbers do not depend on how the PNG was tagged.

import AppKit

struct Pixels {
  let width: Int
  let height: Int
  var bytes: [UInt8]  // RGBA, sRGB, not premultiplied in any way that matters for opaque captures

  subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * width + x) * 4
    return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("design-diff: \(message)\n".utf8))
  exit(1)
}

func load(_ path: String) -> Pixels {
  guard let image = NSImage(contentsOfFile: path),
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
  else { fail("could not read \(path)") }
  let width = cgImage.width
  let height = cgImage.height
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fail("could not make an sRGB context for \(path)") }
  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
  return Pixels(width: width, height: height, bytes: bytes)
}

func save(_ pixels: Pixels, to path: String) {
  var bytes = pixels.bytes
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: &bytes, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: pixels.width * 4,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
    let image = context.makeImage()
  else { fail("could not make an image for \(path)") }
  let rep = NSBitmapImageRep(cgImage: image)
  guard let data = rep.representation(using: .png, properties: [:]) else { fail("could not encode \(path)") }
  do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("could not write \(path): \(error)") }
}

func flag(_ name: String, in args: inout [String]) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let value = args[i + 1]
  args.removeSubrange(i...(i + 1))
  return value
}

func flags(_ name: String, in args: inout [String]) -> [String] {
  var values: [String] = []
  while let value = flag(name, in: &args) { values.append(value) }
  return values
}

// MARK: - crop

func isSentinel(_ p: (r: Int, g: Int, b: Int)) -> Bool {
  abs(p.r - 255) <= 6 && p.g <= 6 && abs(p.b - 255) <= 6
}

func crop(_ args: [String]) {
  var args = args
  let expected = flag("--expect-height", in: &args).map { Int($0) ?? -1 }
  guard args.count == 2 else { fail("crop <in.png> <out.png> [--expect-height <px>]") }
  let source = load(args[0])
  var minX = Int.max
  var minY = Int.max
  var maxX = -1
  var maxY = -1
  for y in 0..<source.height {
    for x in 0..<source.width where isSentinel(source[x, y]) {
      minX = min(minX, x)
      maxX = max(maxX, x)
      minY = min(minY, y)
      maxY = max(maxY, y)
    }
  }
  guard maxX >= 0 else { fail("no #FF00FF registration border in \(args[0]) — launch with -BlurtGalleryBare") }
  // The border's thickness: walk down from the top edge along the middle
  // column. The sides may have no border at all — the keyboard rows are drawn
  // at the phone's full width, bordered above and below only — so each side is
  // inset only where the middle row does start with the sentinel.
  let midX = (minX + maxX) / 2
  let midY = (minY + maxY) / 2
  var thickness = 0
  while minY + thickness <= maxY, isSentinel(source[midX, minY + thickness]) { thickness += 1 }
  guard thickness > 0, thickness < 40 else { fail("registration border looks wrong (thickness \(thickness))") }
  let leftInset = isSentinel(source[minX, midY]) ? thickness : 0
  let rightInset = isSentinel(source[maxX, midY]) ? thickness : 0
  let x0 = minX + leftInset
  let y0 = minY + thickness
  let width = maxX - minX + 1 - leftInset - rightInset
  let height = maxY - minY + 1 - 2 * thickness
  guard width > 0, height > 0 else { fail("registration border encloses nothing") }
  if let expected, abs(height - expected) > 1 {
    fail("crop is \(height) px tall, expected \(expected) (the layout height × the device scale)")
  }
  var out = Pixels(width: width, height: height, bytes: [UInt8](repeating: 0, count: width * height * 4))
  for y in 0..<height {
    let from = ((y0 + y) * source.width + x0) * 4
    out.bytes.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: source.bytes[from..<(from + width * 4)])
  }
  save(out, to: args[1])
  print("crop: \(width)×\(height) at (\(x0),\(y0)), border \(thickness) px → \(args[1])")
}

// MARK: - diff

struct Rect {
  let x: Int
  let y: Int
  let w: Int
  let h: Int
  func contains(_ px: Int, _ py: Int) -> Bool { px >= x && px < x + w && py >= y && py < y + h }
}

func diff(_ args: [String]) {
  var args = args
  guard let outPath = flag("--out", in: &args), let jsonPath = flag("--json", in: &args) else {
    fail("diff <a.png> <b.png> --out <triptych.png> --json <metrics.json> [--mask x,y,w,h]... [--threshold n]")
  }
  let threshold = Int(flag("--threshold", in: &args) ?? "8") ?? 8
  let masks = flags("--mask", in: &args).map { spec -> Rect in
    let parts = spec.split(separator: ",").compactMap { Int($0) }
    guard parts.count == 4 else { fail("mask must be x,y,w,h: \(spec)") }
    return Rect(x: parts[0], y: parts[1], w: parts[2], h: parts[3])
  }
  guard args.count == 2 else { fail("diff needs two images") }
  let a = load(args[0])
  let b = load(args[1])
  guard a.width == b.width, a.height == b.height else {
    fail("sizes differ: \(a.width)×\(a.height) vs \(b.width)×\(b.height) — never resample; fix the export scale")
  }
  var total = 0
  var differing = 0
  var squares = 0.0
  var chromeTotal = 0
  var chromeDiffering = 0
  var chromeSquares = 0.0
  var maskDiffering = [Int](repeating: 0, count: masks.count)
  var maskTotal = [Int](repeating: 0, count: masks.count)
  var heat = Pixels(
    width: a.width * 3, height: a.height, bytes: [UInt8](repeating: 255, count: a.width * 3 * a.height * 4))
  for y in 0..<a.height {
    for x in 0..<a.width {
      let pa = a[x, y]
      let pb = b[x, y]
      let delta = max(abs(pa.r - pb.r), abs(pa.g - pb.g), abs(pa.b - pb.b))
      let over = delta > threshold
      let normalized = Double(delta) / 255
      total += 1
      if over { differing += 1 }
      squares += normalized * normalized
      let maskIndex = masks.firstIndex { $0.contains(x, y) }
      if let maskIndex {
        maskTotal[maskIndex] += 1
        if over { maskDiffering[maskIndex] += 1 }
      } else {
        chromeTotal += 1
        if over { chromeDiffering += 1 }
        chromeSquares += normalized * normalized
      }
      // Triptych: a, b, heat.
      let ia = (y * heat.width + x) * 4
      heat.bytes[ia] = UInt8(pa.r)
      heat.bytes[ia + 1] = UInt8(pa.g)
      heat.bytes[ia + 2] = UInt8(pa.b)
      let ib = (y * heat.width + a.width + x) * 4
      heat.bytes[ib] = UInt8(pb.r)
      heat.bytes[ib + 1] = UInt8(pb.g)
      heat.bytes[ib + 2] = UInt8(pb.b)
      let ih = (y * heat.width + 2 * a.width + x) * 4
      let strength = UInt8(min(255, delta * 4))
      if maskIndex != nil {
        heat.bytes[ih] = 230 - strength / 2
        heat.bytes[ih + 1] = 236 - strength / 2
        heat.bytes[ih + 2] = 255
      } else {
        heat.bytes[ih] = 255
        heat.bytes[ih + 1] = 255 - strength
        heat.bytes[ih + 2] = 255 - strength
      }
    }
  }
  save(heat, to: outPath)
  func fraction(_ n: Int, _ d: Int) -> Double { d == 0 ? 0 : Double(n) / Double(d) }
  var metrics: [String: Any] = [
    "width": a.width, "height": a.height, "threshold": threshold,
    "all": ["ae": fraction(differing, total), "rmse": (squares / Double(max(total, 1))).squareRoot()],
    "chrome": [
      "ae": fraction(chromeDiffering, chromeTotal), "rmse": (chromeSquares / Double(max(chromeTotal, 1))).squareRoot(),
      "pixels": chromeTotal,
    ],
  ]
  metrics["masks"] = masks.enumerated().map { i, rect in
    ["x": rect.x, "y": rect.y, "w": rect.w, "h": rect.h, "ae": fraction(maskDiffering[i], maskTotal[i])]
  }
  guard let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) else {
    fail("could not encode metrics")
  }
  do { try data.write(to: URL(fileURLWithPath: jsonPath)) } catch { fail("could not write \(jsonPath): \(error)") }
  func percent(_ value: Double) -> String { String(format: "%.3f%%", value * 100) }
  let chromeRMSE = String(format: "%.4f", (chromeSquares / Double(max(chromeTotal, 1))).squareRoot())
  print(
    "diff: chrome AE \(percent(fraction(chromeDiffering, chromeTotal))) RMSE \(chromeRMSE)"
      + " · all AE \(percent(fraction(differing, total))) · \(masks.count) masks → \(outPath)")
}

// MARK: - sheet

func sheet(_ args: [String]) {
  var args = args
  guard let outPath = flag("--out", in: &args), let columns = Int(flag("--columns", in: &args) ?? "") else {
    fail("sheet --out <sheet.png> --columns <n> [--scale <f>] <caption>=<png>...")
  }
  let scale = CGFloat(Double(flag("--scale", in: &args) ?? "0.5") ?? 0.5)
  let entries = args.map { arg -> (String, NSImage) in
    guard let eq = arg.firstIndex(of: "=") else { fail("each cell is caption=path: \(arg)") }
    let path = String(arg[arg.index(after: eq)...])
    guard let image = NSImage(contentsOfFile: path) else { fail("could not read \(path)") }
    return (String(arg[..<eq]), image)
  }
  guard !entries.isEmpty else { fail("sheet needs at least one image") }
  let cellW = entries.map { $0.1.size.width }.max()! * scale
  let cellH = entries.map { $0.1.size.height }.max()! * scale
  let pad: CGFloat = 24
  let caption: CGFloat = 28
  let rows = (entries.count + columns - 1) / columns
  let size = NSSize(
    width: pad + CGFloat(columns) * (cellW + pad), height: pad + CGFloat(rows) * (cellH + caption + pad))
  let out = NSImage(size: size)
  out.lockFocus()
  NSColor(calibratedRed: 0.99, green: 0.99, blue: 0.97, alpha: 1).setFill()
  NSRect(origin: .zero, size: size).fill()
  let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
  for (i, (label, image)) in entries.enumerated() {
    let column = CGFloat(i % columns)
    let row = CGFloat(rows - 1 - i / columns)
    let x = pad + column * (cellW + pad)
    let y = pad + row * (cellH + caption + pad)
    let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(
      in: NSRect(x: x, y: y + caption, width: drawSize.width, height: drawSize.height), from: .zero,
      operation: .sourceOver, fraction: 1)
    (label as NSString).draw(
      at: NSPoint(x: x, y: y + 6), withAttributes: [.font: font, .foregroundColor: NSColor.darkGray])
  }
  out.unlockFocus()
  guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
    let data = rep.representation(using: .png, properties: [:])
  else { fail("could not encode the sheet") }
  do { try data.write(to: URL(fileURLWithPath: outPath)) } catch { fail("could not write \(outPath): \(error)") }
  print("sheet: \(entries.count) cells, \(columns) across → \(outPath)")
}

// MARK: - main

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: design-diff.swift crop|diff|sheet …") }
arguments.removeFirst()
switch command {
case "crop": crop(arguments)
case "diff": diff(arguments)
case "sheet": sheet(arguments)
default: fail("unknown command \(command)")
}
