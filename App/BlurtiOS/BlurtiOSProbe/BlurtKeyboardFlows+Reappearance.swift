import XCTest

// The ways a keyboard comes back — the system globe away and back, put away
// and brought up in the same field — each ending with the mic key there and
// drawn. `BlurtKeyboardFlows.testFlows` runs these last.

// MARK: - Switching keyboards

extension BlurtKeyboardFlows {
  /// The globe under the keyboard: away to the system keyboard and back to
  /// Blurt. The mic key must be there again, drawn and full size — the one
  /// thing a fresh appearance in a living extension process can lose. Then
  /// the other way a keyboard comes back: put away and brought up again in
  /// the same field.
  func switchAwayAndBack() throws {
    let globe = app.buttons["Next keyboard"].firstMatch
    guard globe.exists else {
      check(false, "no globe under the keyboard to switch with")
      return
    }
    let plus = app.buttons["Add a key term"]
    globe.tap()
    Thread.sleep(forTimeInterval: 2)
    check(!plus.exists, "the globe switches away from Blurt")
    shot("switched-away")
    var hops = 0
    while !plus.waitForExistence(timeout: 2), hops < 4 {
      app.buttons["Next keyboard"].firstMatch.tap()
      hops += 1
    }
    Thread.sleep(forTimeInterval: 1.5)
    let mic = micKey()
    // One snapshot: an element that flickers would throw between two.
    let frame = mic.exists ? mic.frame : .zero
    check(frame.width > 30 && frame.height > 30, "back on Blurt the mic key is there, full size (\(frame))")
    checkDrawn(mic, "back on Blurt")
    if frame == .zero { print("FLOW-TREE (mic missing after the switch):\n\(app.debugDescription)") }
    shot("switched-back")
    try dismissAndReturn()
  }

  private func dismissAndReturn() throws {
    let dismiss = app.buttons["probe-dismiss"]
    guard dismiss.exists else { return }
    let plus = app.buttons["Add a key term"]
    dismiss.tap()
    Thread.sleep(forTimeInterval: 1.5)
    check(!plus.exists && !micKey().exists, "the keyboard goes away")
    app.textFields.firstMatch.tap()
    let back = plus.waitForExistence(timeout: 5) || micKey().waitForExistence(timeout: 2)
    Thread.sleep(forTimeInterval: 1.5)
    let mic = micKey()
    let frame = mic.exists ? mic.frame : .zero
    check(back && frame.width > 30 && frame.height > 30, "brought back, the mic key is there, full size (\(frame))")
    checkDrawn(micKey(), "brought back")
    if frame == .zero { print("FLOW-TREE (mic missing after the return):\n\(app.debugDescription)") }
    shot("returned")
  }
}
