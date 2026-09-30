import XCTest

/// The real keyboard, used: the extension in its own process over a field in
/// the app, driven through every layout's flows — the mic key present and
/// centred, the + beside it, the panel's carousel swiping to the keys and
/// back, the key-term field opening and closing, letters typing into the
/// field, the mic starting and stopping a dictation while the app listens.
/// One run per face × mic concept × layout (`TEST_RUNNER_BLURT_PROBE_ARGS`);
/// every step prints a FLOW line and attaches a screenshot, and
/// `scripts/ios-keyboard-flows.sh` runs the matrix and collects them.
@MainActor
final class BlurtKeyboardFlows: XCTestCase {
  private var app = XCUIApplication()
  private var shots = 0

  func testFlows() throws {
    continueAfterFailure = true
    let arguments =
      ProcessInfo.processInfo.environment["BLURT_PROBE_ARGS"]?.split(separator: " ").map(String.init) ?? ["light"]
    let layout = arguments.first { ["slimBar", "panel", "full"].contains($0) } ?? "panel"
    app = XCUIApplication()
    // The app listens from launch, so the keyboard's mic key is live.
    app.launchArguments = ["-BlurtProbeField"] + arguments + ["-BlurtStartListening"]
    app.launch()
    try bringUpBlurt()
    shot("up")
    let mic = micKey()
    check(mic.exists, "mic key present (\(mic.label))")
    check(mic.label == "Dictate", "mic key ready: the app is listening (\(mic.label))")
    let plus = app.buttons["Add a key term"]
    check(plus.exists, "the + present")
    if mic.exists, plus.exists {
      let width = app.windows.firstMatch.frame.width
      let centre = mic.frame.midX
      if layout == "panel" {
        check(abs(centre - width / 2) < 4, "mic centred in the panel (\(centre) of \(width))")
        check(plus.frame.midX < 60, "the + in the panel's top-left corner (\(plus.frame.midX))")
      } else {
        // The pair is centred in the voice bar's own width: the whole row in
        // the full keyboard, the room left of delete and return in the slim bar.
        let pair = (mic.frame.minX + plus.frame.maxX) / 2
        let room = layout == "slimBar" ? app.buttons["delete.left"].firstMatch.frame.minX : width
        check(abs(pair - room / 2) < 20, "mic and + centred as a pair (\(pair) in \(room))")
      }
    }
    switch layout {
    case "panel": try panelFlows()
    case "full": try fullFlows()
    default: try slimFlows()
    }
    try termFlow()
    try dictationFlow()
  }

  // MARK: Flows

  private func panelFlows() throws {
    // Where a finger swipes on the panel: the empty space under the element,
    // the element itself, the space key. Each attempt says where it started
    // and whether the carousel flipped; the page is put back between them.
    let mic = { self.micKey().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }
    let gap = { self.micKey().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.15)) }
    let space = { self.app.buttons["space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }
    let attempts = [
      Swipe(origin: "the gap under the mic, left", start: gap, dx: -160),
      Swipe(origin: "the mic itself, left", start: mic, dx: -160),
      Swipe(origin: "the space key, left", start: space, dx: -160),
      Swipe(origin: "the gap under the mic, right", start: gap, dx: 160),
      Swipe(origin: "the space key, right", start: space, dx: 160),
    ]
    for (index, swipe) in attempts.enumerated() {
      let (origin, dx) = (swipe.origin, swipe.dx)
      let from = swipe.start()
      from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: dx, dy: 0)))
      Thread.sleep(forTimeInterval: 1.2)
      let flipped = keysUp
      check(flipped, "swipe from \(origin) flips the panel to the keys")
      if index == 0 { shot("panel-keys") }
      if flipped {
        // Back to the panel from the letters, the swipe that is known to work.
        let g = letterKey("g").exists ? letterKey("g") : letterKey("G")
        let on = g.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        on.press(forDuration: 0.05, thenDragTo: on.withOffset(CGVector(dx: dx > 0 ? -160 : 160, dy: 0)))
        Thread.sleep(forTimeInterval: 1.2)
        check(!keysUp, "swipe from the letters (\(dx > 0 ? "left" : "right")) flips back to the panel")
        if index == 0 { shot("panel-back") }
      }
    }
    check(!keysUp && micKey().frame.width > 200, "the panel is showing again, its mic full size")
  }

  /// Where a swipe starts and how far it goes.
  private struct Swipe {
    let origin: String
    let start: () -> XCUICoordinate
    let dx: CGFloat
  }

  /// Whether the letter keys are on screen (either shift state).
  private var keysUp: Bool { letterKey("Q").exists || letterKey("q").exists }

  private func fullFlows() throws {
    let q = letterKey("Q")
    check(q.exists, "letter keys present")
    q.tap()
    letterKey("q").tap()
    let field = app.textFields.firstMatch
    check(
      (field.value as? String)?.lowercased().contains("qq") == true,
      "letters type into the field (\(field.value ?? "-"))")
    check(
      app.buttons["return"].exists || app.buttons["RETURN"].exists || app.buttons["Return"].exists,
      "return key labelled")
    shot("full-typed")
  }

  private func slimFlows() throws {
    check(app.buttons["delete.left"].exists, "delete present on the slim bar")
    shot("slim")
  }

  private func termFlow() throws {
    let plus = app.buttons["Add a key term"]
    guard plus.exists else { return }
    plus.tap()
    let cancel = app.buttons["Cancel"]
    check(cancel.waitForExistence(timeout: 3), "the + opens the key-term field")
    check(letterKey("Q").exists, "the keys come up for the term")
    letterKey("R").tap()
    letterKey("i").tap()
    shot("term")
    let save = app.buttons["Save the key term"]
    check(save.exists && save.isEnabled, "save enabled after typing")
    cancel.tap()
    check(micKey().waitForExistence(timeout: 3), "cancel returns to the mic")
  }

  private func dictationFlow() throws {
    let mic = micKey()
    guard mic.exists else { return }
    if mic.label == "Start Blurt" {
      check(false, "mic not ready: the app is not listening (\(mic.label))")
      return
    }
    mic.tap()
    let stop = micKey(labelled: "Stop dictation")
    check(stop.waitForExistence(timeout: 4), "a tap starts a dictation (recording)")
    Thread.sleep(forTimeInterval: 1.5)
    shot("recording")
    if stop.exists { stop.tap() }
    let back = micKey(labelled: "Dictate")
    check(back.waitForExistence(timeout: 12), "a second tap stops it and the key settles")
    shot("settled")
  }

  // MARK: Helpers

  private func bringUpBlurt() throws {
    let blurt = app.buttons["Add a key term"]
    let system = app.keyboards.firstMatch
    let deadline = Date().addingTimeInterval(15)
    while !blurt.exists, !system.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    var hops = 0
    while !blurt.waitForExistence(timeout: 2), hops < 4 {
      let globe = app.buttons["Next keyboard"]
      XCTAssertTrue(globe.waitForExistence(timeout: 5), "no globe key")
      globe.tap()
      hops += 1
    }
    XCTAssertTrue(blurt.exists, "Blurt never came up")
    Thread.sleep(forTimeInterval: 1.5)
  }

  /// Blurt's mic key, by its identifier: the system's own bottom bar has a
  /// "Dictate" button too, and a label query lands on it.
  private func micKey() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier == %@", "blurt-mic")).firstMatch
  }

  private func micKey(labelled label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "blurt-mic", label)).firstMatch
  }

  private func letterKey(_ letter: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", letter)).firstMatch
  }

  private func check(_ condition: Bool, _ what: String) {
    print("FLOW-\(condition ? "OK" : "FAIL"): \(what)")
    XCTAssertTrue(condition, what)
  }

  private func shot(_ name: String) {
    shots += 1
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "flow-\(String(format: "%02d", shots))-\(name).png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
