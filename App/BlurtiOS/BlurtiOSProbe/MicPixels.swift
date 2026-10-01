import CoreGraphics
import UIKit
import XCTest

/// Whether the mic element is actually *drawn* — not merely present in the
/// accessibility tree with a frame. The keyboard's key has been there with
/// nothing in it more than once (a drawing surface that never presented in
/// the extension), and only the pixels can say. Samples the screenshot inside
/// the mic key's frame and counts pixels that differ from the frame's own
/// corner, which is the host's material: the grille's dots, lit or at rest,
/// cover well over a tenth of the box; an empty key covers none.
enum MicPixels {
  /// The least share of differing pixels that counts as the element drawn.
  static let drawnThreshold = 0.02

  /// The share of pixels inside `frame` (points, screen coordinates) that are
  /// not the material's colour.
  static func inkFraction(in shot: XCUIScreenshot, frame: CGRect) -> Double {
    guard let image = shot.image.cgImage, frame.width > 4, frame.height > 4 else { return 0 }
    let scale = CGFloat(image.width) / UIScreen.main.bounds.width
    let rect = CGRect(
      x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale
    ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), rect.width > 4, rect.height > 4
    else { return 0 }
    let bytesPerPixel = image.bitsPerPixel / 8
    let bytesPerRow = image.bytesPerRow
    struct RGB {
      let r: Int
      let g: Int
      let b: Int
      func distance(to other: RGB) -> Int { abs(r - other.r) + abs(g - other.g) + abs(b - other.b) }
    }
    func pixel(_ x: Int, _ y: Int) -> RGB {
      let offset = y * bytesPerRow + x * bytesPerPixel
      return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }
    // The material, read just inside the corner (the frame's edge may be antialiased).
    let reference = pixel(Int(rect.minX) + 2, Int(rect.minY) + 2)
    var differing = 0
    var total = 0
    var y = Int(rect.minY)
    while y < Int(rect.maxY) {
      var x = Int(rect.minX)
      while x < Int(rect.maxX) {
        if pixel(x, y).distance(to: reference) > 40 { differing += 1 }
        total += 1
        x += 2
      }
      y += 2
    }
    return total == 0 ? 0 : Double(differing) / Double(total)
  }

  /// The mic element's share of ink, or nil when the key is not there.
  static func ink(_ app: XCUIApplication, mic: XCUIElement) -> Double? {
    guard mic.exists else { return nil }
    return inkFraction(in: app.screenshot(), frame: mic.frame)
  }

  static func isDrawn(_ app: XCUIApplication, mic: XCUIElement) -> Bool {
    (ink(app, mic: mic) ?? 0) > drawnThreshold
  }
}
