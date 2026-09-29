import XCTest

/// Reads the system keyboard's geometry on this simulator: every key's frame,
/// the keyboard's own, and whatever else sits in it (the predictive bar), on
/// both faces. `scripts/apple-geometry.sh` runs this and turns the attachment
/// into `Design/apple-geometry.json`, which the `key/*` tokens are pinned to.
/// XCTest, because XCUIAutomation needs it (the one exception AGENTS.md makes).
final class AppleKeyboardProbe: XCTestCase {
  @MainActor
  func testMeasure() throws {
    for face in ["light", "dark"] {
      let app = XCUIApplication()
      app.launchArguments = ["-BlurtProbeField", face]
      app.launch()
      let keyboard = app.keyboards.firstMatch
      XCTAssertTrue(
        keyboard.waitForExistence(timeout: 15),
        "no on-screen keyboard: turn off 'simulate hardware keyboard' in Device Hub / Simulator")
      // Let the predictive bar and the key pop-in settle.
      Thread.sleep(forTimeInterval: 1.5)
      var out: [String: Any] = [
        "face": face,
        "window": rect(app.windows.firstMatch.frame),
        "keyboard": rect(keyboard.frame),
      ]
      var keys: [String: Any] = [:]
      for key in keyboard.keys.allElementsBoundByIndex {
        let name = key.identifier.isEmpty ? key.label : key.identifier
        guard !name.isEmpty, keys[name] == nil else { continue }
        keys[name] = rect(key.frame)
      }
      out["keys"] = keys
      var others: [String: Any] = [:]
      for element in keyboard.otherElements.allElementsBoundByIndex.prefix(24) {
        let name = element.identifier.isEmpty ? element.label : element.identifier
        guard !name.isEmpty, others[name] == nil else { continue }
        others[name] = rect(element.frame)
      }
      for element in keyboard.buttons.allElementsBoundByIndex.prefix(24) {
        let name = "button:" + (element.identifier.isEmpty ? element.label : element.identifier)
        guard others[name] == nil else { continue }
        others[name] = rect(element.frame)
      }
      out["others"] = others
      let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
      let text = String(decoding: data, as: UTF8.self)
      let json = XCTAttachment(string: text)
      json.name = "apple-geometry-\(face).json"
      json.lifetime = .keepAlways
      add(json)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "apple-keyboard-\(face).png"
      shot.lifetime = .keepAlways
      add(shot)
      app.terminate()
    }
  }

  private func rect(_ r: CGRect) -> [String: Double] {
    ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
  }
}
