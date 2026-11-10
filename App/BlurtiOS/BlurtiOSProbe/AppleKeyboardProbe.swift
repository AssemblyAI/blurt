import XCTest

/// Reads the system keyboard's geometry on this simulator: every key's frame,
/// the keyboard's own, and whatever else sits in it (the predictive bar), on
/// both faces. `scripts/apple-geometry.sh` runs this and turns the attachment
/// into `Design/apple-geometry-<profile>.json`, the oracle Blurt's keyboard is
/// measured against (`scripts/keyboard-parity.sh`, `BlurtKeyboardProbe`).
/// XCTest, because XCUIAutomation needs it (the one exception AGENTS.md makes).
final class AppleKeyboardProbe: XCTestCase {
  @MainActor
  func testMeasure() throws {
    for face in ["light", "dark"] {
      let app = KeyboardMeasure.launch(face: face)
      KeyboardMeasure.bringUpSystem(app)
      let keyboard = app.keyboards.firstMatch
      // Let the predictive bar and the key pop-in settle.
      Thread.sleep(forTimeInterval: 1.5)
      let others =
        Array(keyboard.otherElements.allElementsBoundByIndex.prefix(24))
        + Array(keyboard.buttons.allElementsBoundByIndex.prefix(24))
      let record = KeyboardMeasure.record(
        face: face, app: app, keyboard: keyboard.frame, keys: keyboard.keys.allElementsBoundByIndex, others: others)
      try KeyboardMeasure.attach(record, prefix: "apple", face: face, app: app, to: self)
      app.terminate()
    }
  }
}
