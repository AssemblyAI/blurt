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
  var app = XCUIApplication()
  var shots = 0
  /// `left` or `right` when the run puts the mic at an edge (Settings ›
  /// alignment); nil for the middle.
  var side: String?
  /// The layout this run is of: `slimBar`, `panel` or `full`.
  var layoutName = "panel"

  func testFlows() throws {
    continueAfterFailure = true
    let arguments =
      ProcessInfo.processInfo.environment["BLURT_PROBE_ARGS"]?.split(separator: " ").map(String.init) ?? ["light"]
    let layout = arguments.first { ["slimBar", "panel", "full"].contains($0) } ?? "panel"
    layoutName = layout
    side = arguments.first { ["left", "right"].contains($0) }
    app = XCUIApplication()
    // The app listens from launch, so the keyboard's mic key is live.
    app.launchArguments =
      ["-BlurtProbeField"] + arguments + ["-BlurtStartListening", "-BlurtProbeResetTerms", "-BlurtProbeText", "Rizz"]
    app.launch()
    try bringUpBlurt()
    shot("up")
    let mic = micKey()
    check(mic.exists, "mic key present (\(mic.label))")
    // "Stop dictation" is hands-free already recording: ready too.
    check(mic.label != "Start Blurt", "mic key ready: the app is listening (\(mic.label))")
    let plus = app.buttons["Add a key term"]
    check(plus.exists, "the + present")
    checkDrawn(mic, "on appearance")
    if mic.exists, plus.exists { checkPlacement(layout: layout, mic: mic, plus: plus) }
    switch layout {
    case "panel": try panelFlows()
    case "full": try fullFlows()
    default: try slimFlows()
    }
    try selectionFlow(app.textFields.firstMatch)
    try termFlow()
    try dictationFlow()
    try switchAwayAndBack()
  }

  // MARK: Helpers

  /// Where the mic and the + sit, for this run's layout and side.
  private func checkPlacement(layout: String, mic: XCUIElement, plus: XCUIElement) {
    let width = app.windows.firstMatch.frame.width
    let centre = mic.frame.midX
    // Wherever the mic is, the + sits on its centre line.
    check(
      abs(plus.frame.midY - mic.frame.midY) < 4,
      "the + at the mic's centre line (\(plus.frame.midY) vs \(mic.frame.midY))")
    if let side {
      // One hand: the mic at the chosen edge, the + on its inner side. The
      // slim bar's row is bounded by the globe (when Blurt draws one; on a
      // Face ID phone the system puts it under the keyboard) and delete
      // keys, so there the mic is next to that key rather than the edge.
      let left = side == "left"
      let globe = app.buttons["globe"].firstMatch
      let bound =
        layout == "slimBar"
        ? (left ? (globe.exists ? globe.frame.maxX : 0) : app.buttons["delete.left"].firstMatch.frame.minX)
        : (left ? 0 : width)
      let edge = left ? mic.frame.minX - bound : bound - mic.frame.maxX
      let inner = left ? plus.frame.minX > mic.frame.maxX : plus.frame.maxX < mic.frame.minX
      check(edge < 12, "mic at the \(side) edge (\(edge) pt in)")
      check(inner, "the + on the mic's inner side")
    } else if layout == "panel" {
      check(abs(centre - width / 2) < 4, "mic centred in the panel (\(centre) of \(width))")
      check(plus.frame.minX > mic.frame.maxX, "the + beside the mic, to its right")
    } else {
      // The element itself is centred in the voice bar's own width — the
      // whole row in the full keyboard, the room between the globe (if any)
      // and delete in the slim bar — with the + hanging beside it.
      let globe = app.buttons["globe"].firstMatch
      let from = layout == "slimBar" && globe.exists ? globe.frame.maxX : 0
      let to = layout == "slimBar" ? app.buttons["delete.left"].firstMatch.frame.minX : width
      check(abs(centre - (from + to) / 2) < 8, "mic centred in its row (\(centre) in \(from)…\(to))")
      check(plus.frame.minX > mic.frame.maxX, "the + beside the mic, to its right")
    }
  }

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
  func micKey() -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier == %@", "blurt-mic")).firstMatch
  }

  func micKey(labelled label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "blurt-mic", label)).firstMatch
  }

  func letterKey(_ letter: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", letter)).firstMatch
  }

  func check(_ condition: Bool, _ what: String) {
    print("FLOW-\(condition ? "OK" : "FAIL"): \(what)")
    XCTAssertTrue(condition, what)
  }

  /// The mic element's pixels are there — a key with nothing drawn in it is
  /// the failure the frame checks cannot see.
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

// MARK: - Flows

extension BlurtKeyboardFlows {
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
    check(!keysUp && panelMicUp, "the panel is showing again, its mic full size")
    checkDrawn(micKey(), "after the swipes back")
    // Pairs from one fixed screen point (an element mid-slide is no anchor):
    // a flip and a flip back, and two the same way — with no wait between,
    // so the second lands mid-slide, and again after the slide has settled.
    // Each pair lands on the panel, the cards never having crossed.
    let anchor = gap().screenPoint
    let fixed = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchor.x, dy: anchor.y))
    let pairs = [
      Pair(name: "left then right, mid-slide", first: -160, second: 160, pause: 0),
      Pair(name: "left twice, mid-slide", first: -160, second: -160, pause: 0),
      Pair(name: "left then right, settled", first: -160, second: 160, pause: 0.5),
      Pair(name: "left twice, settled", first: -160, second: -160, pause: 0.5),
    ]
    for pair in pairs {
      fixed.press(forDuration: 0.05, thenDragTo: fixed.withOffset(CGVector(dx: pair.first, dy: 0)))
      if pair.pause > 0 { Thread.sleep(forTimeInterval: pair.pause) }
      fixed.press(forDuration: 0.05, thenDragTo: fixed.withOffset(CGVector(dx: pair.second, dy: 0)))
      Thread.sleep(forTimeInterval: 1.5)
      check(!keysUp && panelMicUp, "two quick swipes, \(pair.name), land back on the panel")
      shot("panel-pair-\(pair.name.replacingOccurrences(of: ", ", with: "-").replacingOccurrences(of: " ", with: "-"))")
    }
  }

  /// Two swipes from one point: how far each goes, and the wait between.
  private struct Pair {
    let name: String
    let first: CGFloat
    let second: CGFloat
    let pause: TimeInterval
  }

  /// Where a swipe starts and how far it goes.
  private struct Swipe {
    let origin: String
    let start: () -> XCUICoordinate
    let dx: CGFloat
  }

  /// Whether the letter keys are on screen (either shift state).
  var keysUp: Bool { letterKey("Q").exists || letterKey("q").exists }

  /// Whether the mic key on screen is the panel's: as tall as the panel's
  /// element box (88), where the bar's is the row (44). The width says
  /// nothing — the key is as wide as the element shows, whichever concept.
  var panelMicUp: Bool { micKey().exists && micKey().frame.height > 60 }

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

  /// Highlight the word in the field: the + becomes a chip holding it, one
  /// tap adds it, and the chip then says Blurt has it.
  private func selectionFlow(_ field: XCUIElement) throws {
    // Double-tap the word itself — it sits at the field's leading edge — not
    // the field's empty middle, and once more after a beat if the highlight
    // didn't take the first time (a shot of the miss says why).
    // Either face of the chip: the word to add, or — were the list not reset —
    // the word Blurt already knows.
    let chip = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@ OR label ENDSWITH %@", "Add “", "” is a key term")
    ).firstMatch
    let mic = micKey()
    for attempt in 1...2 where !chip.exists {
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).doubleTap()
      if chip.waitForExistence(timeout: 3) { break }
      shot("\(layoutName)-select-miss-\(attempt)")
    }
    let label = chip.exists ? chip.label : "-"
    check(chip.exists, "highlighting a word shows the chip (\(label))")
    if chip.exists, mic.exists {
      check(abs(chip.frame.midY - mic.frame.midY) < 4, "the chip at the mic's centre line")
      check(
        chip.frame.minX >= mic.frame.maxX - 1 || chip.frame.maxX <= mic.frame.minX + 1,
        "the chip clear of the mic (\(chip.frame) vs \(mic.frame))")
    }
    shot("\(layoutName)-selected")
    let plus = app.buttons["Add a key term"]
    if label.hasPrefix("Add “") {
      let word = label.dropFirst("Add “".count).prefix { $0 != "”" }
      chip.tap()
      let known = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "“\(word)” is a key term")).firstMatch
      // The check shows for 1.2 s; XCUITest's snapshot of another process
      // can miss it, so the proof of the add is below: the word re-selected
      // is a word Blurt knows.
      if known.waitForExistence(timeout: 2) { shot("\(layoutName)-added") }
      // The highlight still stands in the field; the chip gives way to the +
      // on its own after the check, so the row is never stuck on the word.
      check(plus.waitForExistence(timeout: 4), "after the check the + is back while the word stays highlighted")
      check(mic.exists && mic.label != "Start Blurt", "the mic is still the mic after adding (\(mic.label))")
      shot("\(layoutName)-after-add")
      // Cleared and highlighted again: Blurt knows the word now, and a tap on
      // that chip puts the + back at once.
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
      Thread.sleep(forTimeInterval: 0.5)
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).doubleTap()
      check(known.waitForExistence(timeout: 4), "one tap added “\(word)”: highlighted again, the chip knows it")
      shot("\(layoutName)-known")
      if known.exists {
        known.tap()
        check(plus.waitForExistence(timeout: 3), "a tap on the known chip puts the + back")
      }
    } else if chip.exists {
      check(false, "the word was already a key term before this run (\(label)) — the list was not reset")
    }
    // Clear the highlight, cursor at the end, so typing appends rather than
    // replaces; the + is there either way.
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    check(plus.waitForExistence(timeout: 3), "the + present once the highlight is cleared")
    Thread.sleep(forTimeInterval: 0.5)
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
}
