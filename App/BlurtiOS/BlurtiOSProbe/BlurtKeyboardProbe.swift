import XCTest

/// Reads Blurt's keyboard the way `AppleKeyboardProbe` reads Apple's — the
/// extension in its own process over the same field, on both faces — so
/// `scripts/keyboard-parity.sh` can put every key of the two side by side.
/// XCUITest has no keyboard element for a custom keyboard, only its
/// controls: the keys are the keys and buttons in the bottom of the window,
/// and the keyboard's frame is their union plus the bar's.
final class BlurtKeyboardProbe: XCTestCase {
  @MainActor
  func testMeasure() throws {
    for face in ["light", "dark"] {
      let app = KeyboardMeasure.launch(face: face)
      KeyboardMeasure.bringUpBlurt(app)
      Thread.sleep(forTimeInterval: 2)
      let window = app.windows.firstMatch.frame
      // The keyboard's region: the bottom of the window, above the host's
      // own bar (its globe and dictation button are the host's, not the
      // keyboard's). Anything of the app's sits in the top half. Keys and
      // buttons both: KeyboardKit's keys carry the keyboard-key trait, so
      // XCUITest shows them as keys; Blurt's bar holds buttons. Bound by
      // element, not index: the set is still settling as the keys come up.
      let hostBar = ["Next keyboard", "dictation", "Dictate"]
      func inRegion(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        let name = element.identifier.isEmpty ? element.label : element.identifier
        return frame.minY > window.midY && frame.width > 0 && !hostBar.contains(name)
      }
      // Keys and buttons only: anything wider (otherElements, the tree) is a
      // snapshot of the whole extension that times out.
      let keys =
        app.keys.allElementsBoundByAccessibilityElement.filter(inRegion)
        + app.buttons.allElementsBoundByAccessibilityElement.filter(inRegion)
      let union = keys.map(\.frame).reduce(CGRect.null) { $0.union($1) }
      let record = KeyboardMeasure.record(face: face, app: app, keyboard: union, keys: keys, others: [])
      try KeyboardMeasure.attach(record, prefix: "blurt", face: face, app: app, to: self)
      app.terminate()
    }
  }
}
