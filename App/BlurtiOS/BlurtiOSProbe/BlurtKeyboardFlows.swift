import XCTest

/// The real keyboard, used: the extension in its own process over a field in
/// the app, driven through its flows — the mic key in the bottom row between
/// space and return, the + in the bar, letters typing into the field, the
/// key-term field opening and closing, the mic starting and stopping a
/// dictation while the app listens, and the ways a keyboard comes back. One
/// run per face (`TEST_RUNNER_BLURT_PROBE_ARGS`); every step prints a FLOW
/// line and attaches a screenshot, and `scripts/ios-keyboard-flows.sh` runs
/// both faces and collects them.
@MainActor
final class BlurtKeyboardFlows: XCTestCase {
  // The flows in `BlurtKeyboardFlows+Case.swift` launch the app again, so it can't be private.
  // swiftlint:disable:next test_case_accessibility
  var app = XCUIApplication()
  // The screenshot counter `shot` (in `BlurtKeyboardFlows+Helpers.swift`) numbers by.
  // swiftlint:disable:next test_case_accessibility
  var shots = 0

  func testFlows() {
    continueAfterFailure = true
    let arguments =
      ProcessInfo.processInfo.environment["BLURT_PROBE_ARGS"]?.split(separator: " ").map(String.init) ?? ["light"]
    app = XCUIApplication()
    // The app listens from launch, so the keyboard's mic key is live.
    app.launchArguments =
      ["-BlurtProbeField"] + arguments + ["-BlurtStartListening", "-BlurtProbeResetTerms", "-BlurtProbeText", "Rizz"]
    // A simulator with no key in its Keychain can't open the window: the key
    // the script was given (TEST_RUNNER_BLURT_DEBUG_API_KEY) goes to the app.
    if let key = ProcessInfo.processInfo.environment["BLURT_DEBUG_API_KEY"], !key.isEmpty {
      app.launchEnvironment["BLURT_DEBUG_API_KEY"] = key
    }
    app.launch()
    KeyboardMeasure.bringUpBlurt(app)
    Thread.sleep(forTimeInterval: 1.5)
    shot("up")
    let mic = micKey()
    check(mic.exists, "mic key present (\(mic.label))")
    // "Stop dictation" is hands-free already recording: ready too.
    check(mic.label != "Start Blurt", "mic key ready: the app is listening (\(mic.label))")
    let plus = app.buttons["Add a key term"]
    check(plus.exists, "the + present")
    checkDrawn(mic, "on appearance")
    if mic.exists { checkPlacement(mic: mic, plus: plus) }
    typingFlow()
    selectionFlow(app.textFields.firstMatch)
    termFlow()
    dictationFlow()
    switchAwayAndBack()
  }

  /// Where the mic sits: in the bottom row between space and return, on
  /// their centre line (DESIGN.md › The mic's place); the + in the bar above
  /// the keys, at the trailing end.
  private func checkPlacement(mic: XCUIElement, plus: XCUIElement) {
    let space = app.keys["space"].firstMatch
    let returnKey = app.keys.matching(
      NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "return", "Return")
    ).firstMatch
    check(space.exists && returnKey.exists, "space and return present")
    guard space.exists, returnKey.exists else {
      return
    }
    check(abs(mic.frame.midY - space.frame.midY) < 2, "the mic on the bottom row's centre line")
    check(
      mic.frame.minX >= space.frame.maxX - 1 && mic.frame.maxX <= returnKey.frame.minX + 1,
      "the mic between space and return (\(mic.frame) vs \(space.frame), \(returnKey.frame))"
    )
    let keysTop = letterKey("q").frame.minY
    check(plus.exists && plus.frame.maxY <= keysTop + 1, "the + in the bar above the keys")
    check(plus.exists && plus.frame.maxX > mic.frame.midX, "the + at the bar's trailing end")
  }
}

// MARK: - Flows

extension BlurtKeyboardFlows {
  private func typingFlow() {
    let q = letterKey("q")
    check(q.exists, "letter keys present")
    q.tap()
    letterKey("q").tap()
    let field = app.textFields.firstMatch
    check(
      (field.value as? String)?.lowercased().contains("qq") == true,
      "letters type into the field (\(field.value ?? "-"))"
    )
    check(app.keys["space"].exists, "space present")
    shot("typed")
  }

  /// Highlight the word in the field: the + becomes a chip holding it, one
  /// tap adds it, and the chip then says Blurt has it.
  private func selectionFlow(_ field: XCUIElement) {
    // Double-tap the word itself — it sits at the field's leading edge — not
    // the field's empty middle, and once more after a beat if the highlight
    // didn't take the first time (a shot of the miss says why).
    // Either face of the chip: the word to add, or — were the list not reset —
    // the word Blurt already knows.
    let chip = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@ OR label ENDSWITH %@", "Add “", "” is a key term")
    ).firstMatch
    for attempt in 1...2 where !chip.exists {
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).doubleTap()
      if chip.waitForExistence(timeout: 3) { break }
      shot("select-miss-\(attempt)")
    }
    let label = chip.exists ? chip.label : "-"
    check(chip.exists, "highlighting a word shows the chip (\(label))")
    shot("selected")
    let plus = app.buttons["Add a key term"]
    let mic = micKey()
    if label.hasPrefix("Add “") {
      let word = label.dropFirst("Add “".count).prefix { $0 != "”" }
      chip.tap()
      let known = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@", "“\(word)” is a key term")).firstMatch
      // The check shows for 1.2 s; XCUITest's snapshot of another process
      // can miss it, so the proof of the add is below: the word re-selected
      // is a word Blurt knows.
      if known.waitForExistence(timeout: 2) { shot("added") }
      // The highlight still stands in the field; the chip gives way to the +
      // on its own after the check, so the bar is never stuck on the word.
      check(plus.waitForExistence(timeout: 4), "after the check the + is back while the word stays highlighted")
      check(mic.exists && mic.label != "Start Blurt", "the mic is still the mic after adding (\(mic.label))")
      shot("after-add")
      // Cleared and highlighted again: Blurt knows the word now, and a tap on
      // that chip puts the + back at once.
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
      Thread.sleep(forTimeInterval: 0.5)
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).doubleTap()
      check(known.waitForExistence(timeout: 4), "one tap added “\(word)”: highlighted again, the chip knows it")
      shot("known")
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

  private func termFlow() {
    let plus = app.buttons["Add a key term"]
    guard plus.exists else {
      return
    }
    plus.tap()
    let cancel = app.buttons["Cancel"]
    check(cancel.waitForExistence(timeout: 3), "the + opens the key-term field")
    check(letterKey("q").exists, "the keys stay up for the term")
    let field = app.textFields.firstMatch
    let hostBefore = field.value as? String
    letterKey("r").tap()
    letterKey("i").tap()
    shot("term")
    let save = app.buttons["Save the key term"]
    check(save.exists && save.isEnabled, "save enabled after typing")
    check(
      (field.value as? String) == hostBefore,
      "the term's letters went to the field in the bar, not the host (\(field.value ?? "-"))"
    )
    cancel.tap()
    check(micKey().waitForExistence(timeout: 3), "cancel returns to the bar")
  }

  private func dictationFlow() {
    let mic = micKey()
    guard mic.exists else {
      return
    }
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
    // Hold to talk: the press starts, the lift stops.
    micKey().press(forDuration: 1.5)
    check(micKey(labelled: "Dictate").waitForExistence(timeout: 12), "a hold's lift stops it (\(micKey().label))")
    shot("held")
  }
}
