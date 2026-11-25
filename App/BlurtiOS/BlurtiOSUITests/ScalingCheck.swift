import XCTest

/// The default-size audit's "Dynamic Type unsupported" findings, held until
/// the largest text size shows whether the text really doesn't scale.
///
/// On CI, and never on a Mac, that audit intermittently calls the rows at the
/// foot of Settings' last page ("AssemblyAI's privacy policy", "Powered by
/// AssemblyAI", "How fast can you type?") unsupported, on both of its passes,
/// while the same rows render visibly larger at AX XXXL in the same test and
/// the same commit passes an hour apart. So the claim is checked against the
/// one thing it is about: a held finding fails only if its text is no taller
/// at the largest size than at the default one, or never comes into full view
/// there. A font that doesn't scale stays the same height and still fails.
@MainActor
struct ScalingCheck {
  private struct Held {
    let finding: String
    let label: String
    let type: XCUIElement.ElementType
    let height: CGFloat
  }

  /// How much taller the text must be at AX XXXL. Body text there is about
  /// three times its default size, while a row whose font doesn't scale grows
  /// only by its padding.
  private static let growth: CGFloat = 1.5

  private var held: [Held] = []
  /// The tallest each held text was seen at the largest size, on any page.
  private var largest: [String: CGFloat] = [:]

  /// How tall the text labelled `label` is where it is in full view: the text
  /// itself when the audit's element (a link, a button) exposes it, else that
  /// element. Nil when it isn't on screen.
  private static func height(
    of label: String,
    type: XCUIElement.ElementType,
    in app: XCUIApplication,
    within screen: CGRect
  ) -> CGFloat? {
    let candidates = [app.staticTexts[label].firstMatch, app.descendants(matching: type)[label].firstMatch]
    return candidates.first { $0.exists && screen.contains($0.frame) }?.frame.height
  }

  private static func key(_ label: String, _ type: XCUIElement.ElementType) -> String {
    "\(type.rawValue)|\(label)"
  }

  /// Holds a default-size `finding` about `element` instead of failing it.
  mutating func hold(_ finding: String, about element: XCUIElement, in app: XCUIApplication, within screen: CGRect) {
    let label = element.label
    let type = element.elementType
    let height = Self.height(of: label, type: type, in: app, within: screen) ?? element.frame.height
    held.append(Held(finding: finding, label: label, type: type, height: height))
  }

  /// At the largest size: notes how tall each held text is on this page.
  mutating func measure(in app: XCUIApplication, within screen: CGRect) {
    for item in held {
      guard let height = Self.height(of: item.label, type: item.type, in: app, within: screen) else {
        continue
      }
      let key = Self.key(item.label, item.type)
      largest[key] = max(largest[key] ?? 0, height)
    }
  }

  /// The held findings whose text never grew: the ones that fail.
  func unscaled() -> [String] {
    held.filter { (largest[Self.key($0.label, $0.type)] ?? 0) <= $0.height * Self.growth }
      .map(\.finding)
  }
}
