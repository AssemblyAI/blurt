import XCTest

// The ways a keyboard comes back — the system globe away and back, put
// away and brought up in the same field, a layout changed in Settings
// meanwhile, a rough swipe on the panel — each ending with the mic key
// there and drawn. `BlurtKeyboardFlows.testFlows` runs these last.

// MARK: - Switching keyboards

extension BlurtKeyboardFlows {
  /// The globe under the keyboard: away to the system keyboard and back to
  /// Blurt. The mic key must be there again, drawn and full size — the one
  /// thing a fresh appearance in a living extension process can lose.
  func switchAwayAndBack() throws {
    let globe = app.buttons["Next keyboard"].firstMatch
    guard globe.exists else {
      check(false, "no globe under the keyboard to switch with")
      return
    }
    // Once from the page that is up, and — on the panel — once more from its
    // keys page, the way a swipe leaves it: the panel must come back on its
    // mic page, at its own height, with the mic drawn.
    try switchAwayAndBack(globe: globe, from: "the mic page")
    if micKey().exists, app.buttons["space"].exists, !keysUp {
      flipToKeys()
      if keysUp { try switchAwayAndBack(globe: globe, from: "the keys page") }
    }
    // And the other way a keyboard comes back: put away and brought up again
    // in the same field, from the mic page and from the keys page.
    try dismissAndReturn(from: "the mic page")
    if micKey().exists, app.buttons["space"].exists, !keysUp {
      flipToKeys()
      if keysUp { try dismissAndReturn(from: "the keys page") }
    }
    // And with the layout changed in Settings meanwhile: to each of the
    // other two, then back to this run's own, the keyboard re-shown after
    // each change.
    let others = ["slimBar", "panel", "full"].filter { $0 != layoutName } + [layoutName]
    for other in others where app.buttons["probe-layout-\(other)"].exists {
      app.buttons["probe-layout-\(other)"].tap()
      try dismissAndReturn(from: "a layout change to \(other)")
    }
    if layoutName == "panel", micKey().exists, !keysUp { try roughSwipes() }
  }

  /// The swipes a finger makes and a clean drag does not: one that rests on
  /// the mic long enough to press it before it travels (a press goes out and
  /// is cancelled), and one taken while a dictation is recording. After each
  /// pair the panel must be back with its mic drawn.
  private func roughSwipes() throws {
    let mic = micKey()
    let held = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    held.press(forDuration: 0.35, thenDragTo: held.withOffset(CGVector(dx: -160, dy: 0)))
    Thread.sleep(forTimeInterval: 1.2)
    check(keysUp, "a slow swipe from the mic flips to the keys (\(micKey().label))")
    swipeBackFromLetters()
    var frame = micKey().exists ? micKey().frame : .zero
    check(
      frame.width > 200, "after a slow swipe from the mic and back, the mic is there (\(frame), \(micKey().label))")
    shot("rough-slow")
    guard micKey().exists, micKey().label == "Dictate" else { return }
    micKey().tap()
    check(micKey(labelled: "Stop dictation").waitForExistence(timeout: 4), "a tap starts a dictation")
    let gap = micKey().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.15))
    gap.press(forDuration: 0.05, thenDragTo: gap.withOffset(CGVector(dx: -160, dy: 0)))
    Thread.sleep(forTimeInterval: 1.2)
    check(keysUp, "a swipe while recording flips to the keys")
    swipeBackFromLetters()
    frame = micKey().exists ? micKey().frame : .zero
    check(frame.width > 200, "back on the panel while recording, the mic is there (\(frame), \(micKey().label))")
    shot("rough-recording")
    if micKey(labelled: "Stop dictation").exists { micKey().tap() }
    _ = micKey(labelled: "Dictate").waitForExistence(timeout: 12)
  }

  private func swipeBackFromLetters() {
    let g = letterKey("g").exists ? letterKey("g") : letterKey("G")
    let on = g.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    on.press(forDuration: 0.05, thenDragTo: on.withOffset(CGVector(dx: 160, dy: 0)))
    Thread.sleep(forTimeInterval: 1.2)
  }

  /// A swipe on the panel's gap, to its keys page.
  private func flipToKeys() {
    let gap = micKey().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.15))
    gap.press(forDuration: 0.05, thenDragTo: gap.withOffset(CGVector(dx: -160, dy: 0)))
    Thread.sleep(forTimeInterval: 1.2)
  }

  private func dismissAndReturn(from page: String) throws {
    let dismiss = app.buttons["probe-dismiss"]
    guard dismiss.exists else { return }
    let plus = app.buttons["Add a key term"]
    dismiss.tap()
    Thread.sleep(forTimeInterval: 1.5)
    check(!plus.exists && !micKey().exists, "the keyboard goes away (from \(page))")
    app.textFields.firstMatch.tap()
    let back = plus.waitForExistence(timeout: 5) || micKey().waitForExistence(timeout: 2)
    Thread.sleep(forTimeInterval: 1.5)
    let mic = micKey()
    let frame = mic.exists ? mic.frame : .zero
    check(
      back && frame.width > 40 && frame.height > 20,
      "brought back from \(page) the mic key is there, full size (\(frame))")
    if frame == .zero { print("FLOW-TREE (mic missing after the return):\n\(app.debugDescription)") }
    if page == "the keys page" { check(!keysUp, "the panel is back on its mic page after being put away") }
    shot("returned-\(page.replacingOccurrences(of: " ", with: "-"))")
  }

  private func switchAwayAndBack(globe: XCUIElement, from page: String) throws {
    // XCUITest has no Keyboard element for a custom keyboard: the + at the
    // panel's top corner stands in for where the keyboard begins.
    let plus = app.buttons["Add a key term"]
    let topBefore = plus.exists ? plus.frame.minY : 0
    globe.tap()
    Thread.sleep(forTimeInterval: 2)
    check(!plus.exists, "the globe switches away from Blurt (from \(page))")
    shot("switched-away")
    var hops = 0
    while !plus.waitForExistence(timeout: 2), hops < 4 {
      app.buttons["Next keyboard"].firstMatch.tap()
      hops += 1
    }
    Thread.sleep(forTimeInterval: 1.5)
    let mic = micKey()
    let top = plus.exists ? plus.frame.minY : 0
    // One snapshot: an element that flickers would throw between two.
    let frame = mic.exists ? mic.frame : .zero
    check(
      frame.width > 40 && frame.height > 20,
      "back on Blurt from \(page) the mic key is there, full size (\(frame); top \(topBefore) → \(top))")
    if frame == .zero { print("FLOW-TREE (mic missing after the switch):\n\(app.debugDescription)") }
    if page == "the keys page" {
      check(!keysUp, "the panel is back on its mic page after the switch")
      // The keys page was up before, so the keyboard was 54 pt taller then.
      check(abs(top - topBefore - 54) < 4, "the panel is back at its own height (top \(topBefore) → \(top))")
    }
    shot("switched-back")
  }
}
