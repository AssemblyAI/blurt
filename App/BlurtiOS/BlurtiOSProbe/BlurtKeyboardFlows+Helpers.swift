import XCTest

// MARK: - Helpers
//
// The keys, the checks and the screenshots every flow is written in, in
// `BlurtKeyboardFlows.swift` and its other extensions alike.

extension BlurtKeyboardFlows {
  /// Blurt's mic key, by its identifier: a key, as every KeyboardKit key is
  /// to XCUITest (the keyboard-key trait); the system's own bottom bar has a
  /// "Dictate" button too, and a label query lands on it.
  func micKey() -> XCUIElement {
    app.keys.matching(NSPredicate(format: "identifier == %@", "blurt-mic")).firstMatch
  }

  func micKey(labelled label: String) -> XCUIElement {
    app.keys.matching(NSPredicate(format: "identifier == %@ AND label == %@", "blurt-mic", label)).firstMatch
  }

  /// A letter key, in either case.
  func letterKey(_ letter: String) -> XCUIElement {
    app.keys.matching(NSPredicate(format: "label ==[c] %@", letter)).firstMatch
  }

  func check(_ condition: Bool, _ what: String) {
    print("FLOW-\(condition ? "OK" : "FAIL"): \(what)")
    XCTAssertTrue(condition, what)
  }

  /// The mic key's pixels are there — a key with nothing drawn in it is the
  /// failure the frame checks cannot see.
  func checkDrawn(_ mic: XCUIElement, _ when: String) {
    let ink = MicPixels.ink(app, mic: mic) ?? 0
    check(ink > MicPixels.drawnThreshold, "the mic is drawn \(when) (ink \(ink))")
  }

  func shot(_ name: String) {
    shots += 1
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "flow-\(String(format: "%02d", shots))-\(name).png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
