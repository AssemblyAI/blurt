import XCTest

/// The largest-size audit's "text clipped" findings on plain text, checked
/// against what is on screen rather than taken on the audit's word.
///
/// The audit says text "may be clipped at larger Dynamic Type sizes" even at
/// AX XXXL, the largest there is, and it said it of the style editor's
/// "Professional" chip while the chip drew the word whole (#465's run
/// 46111753809: 226 pt of text on a full-width chip). The text is set in a
/// fixed-size face scaled by the app (`ScaledFont`), not a system text style,
/// so the audit can't see that it scales, and one long word has nowhere to
/// wrap. So the claim is checked against the one thing it is about: text
/// drawn whole sits fully on screen, inside the element that holds it, with
/// room left beside it, since text that needed more width would have taken
/// all its holder offers. Anything else fails, and the failure says what was
/// measured.
@MainActor
enum ClipCheck {
  /// How much narrower than its holder the text must be, on each side.
  private static let room: CGFloat = 8

  /// Nil when `element`'s text is drawn whole; otherwise what was measured.
  static func clipped(_ element: XCUIElement, in app: XCUIApplication, within screen: CGRect) -> String? {
    let frame = element.frame
    guard screen.contains(frame) else {
      return "[ClipCheck: \(describe(frame)) is not fully on screen]"
    }
    guard let root = try? app.snapshot(), let holder = holder(of: element.label, at: frame, in: root) else {
      return "[ClipCheck: \(describe(frame)), no element holding it found]"
    }
    let isInside = holder.insetBy(dx: -0.5, dy: -0.5).contains(frame)
    let hasRoom = frame.minX - holder.minX >= room && holder.maxX - frame.maxX >= room
    guard isInside, hasRoom else {
      return "[ClipCheck: \(describe(frame)) in a holder at \(describe(holder)), under \(Int(room)) pt clear each side]"
    }
    return nil
  }

  /// The frame of the nearest element around the text labelled `label` at
  /// `frame` that is wider than the text: the chip, row or cell it sits in.
  private static func holder(of label: String, at frame: CGRect, in root: XCUIElementSnapshot) -> CGRect? {
    var pending: [(node: XCUIElementSnapshot, ancestors: [CGRect])] = [(root, [])]
    while let (node, ancestors) = pending.popLast() {
      if node.elementType == .staticText, node.label == label, node.frame.equalTo(frame) {
        return ancestors.reversed().first { $0.width > frame.width }
      }
      pending += node.children.map { ($0, ancestors + [node.frame]) }
    }
    return nil
  }

  private static func describe(_ frame: CGRect) -> String {
    "\(Int(frame.width))×\(Int(frame.height)) pt at (\(Int(frame.minX)), \(Int(frame.minY)))"
  }
}
