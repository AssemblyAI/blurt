import XCTest

// MARK: - The letters' case, as Apple's keyboard has it

extension BlurtKeyboardFlows {
  /// An empty field starts a sentence, so the keys come up uppercase and go
  /// lowercase after the first letter; a sentence's end brings them back up;
  /// shift lifts one letter. Auto-Capitalization is the keyboard's own rule
  /// (KeyboardKit's `isAutocapitalizationEnabled`): iOS tells no third-party
  /// keyboard what the phone's own switch says.
  func testCase() throws {
    continueAfterFailure = true
    let arguments =
      ProcessInfo.processInfo.environment["BLURT_PROBE_ARGS"]?.split(separator: " ").map(String.init) ?? ["light"]
    app = XCUIApplication()
    app.launchArguments =
      ["-BlurtProbeField"] + arguments + ["-BlurtProbeResetTerms", "-BlurtProbeText", "", "-BlurtProbeSentences"]
    app.launch()
    KeyboardMeasure.bringUpBlurt(app)
    Thread.sleep(forTimeInterval: 1.5)
    shot("case-up")
    let field = app.textFields.firstMatch
    check(letterKey("q").label == "Q", "an empty field: the keys come up uppercase (\(letterKey("q").label))")
    letterKey("h").tap()
    check(letterKey("q").label == "q", "after the first letter the keys are lowercase (\(letterKey("q").label))")
    letterKey("i").tap()
    app.keys["space"].tap()
    check(letterKey("q").label == "q", "after a space mid-sentence, still lowercase (\(letterKey("q").label))")
    shot("case-mid")
    // A sentence's end: Apple's keys lift for the next one.
    let numbers = app.keys.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label == %@", "numeric", "123"))
      .firstMatch
    check(numbers.exists, "the 123 key present (\(numbers.label))")
    numbers.tap()
    let period = app.keys.matching(
      NSPredicate(format: "label == %@ OR label ==[c] %@ OR label ==[c] %@", ".", "period", "full stop")
    )
    .firstMatch
    check(
      period.waitForExistence(timeout: 2),
      "the period on the number page (\(app.keys.allElementsBoundByAccessibilityElement.map(\.label).joined(separator: " ")))"
    )
    if period.exists { period.tap() }
    let letters = app.keys.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label == %@", "alphabetic", "ABC"))
      .firstMatch
    if letters.exists { letters.tap() }
    app.keys["space"].tap()
    check(letterKey("q").label == "Q", "after a period and a space the keys lift again (\(letterKey("q").label))")
    letterKey("o").tap()
    check(letterKey("q").label == "q", "and drop after the letter (\(letterKey("q").label))")
    // Shift: one letter up, then down.
    let shift = app.keys.matching(NSPredicate(format: "label ==[c] %@", "shift")).firstMatch
    check(shift.exists, "shift present")
    if shift.exists {
      shift.tap()
      check(letterKey("q").label == "Q", "shift lifts the keys (\(letterKey("q").label))")
      letterKey("k").tap()
      check(letterKey("q").label == "q", "one letter later they drop (\(letterKey("q").label))")
    }
    shot("case-end")
    check((field.value as? String) == "Hi . OK", "the text reads as typed (\(field.value ?? "-"))")
  }
}
