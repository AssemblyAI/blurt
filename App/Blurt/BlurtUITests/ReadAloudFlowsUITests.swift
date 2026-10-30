import XCTest

/// Read-aloud and ask beyond the basics: the pill during and after a read, a
/// read held to listen on another key, a tapped ask, an ask with nothing said,
/// and a press stopping an answer.
final class ReadAloudFlowsUITests: BlurtUITestCase {
  private var pill: XCUIElement { app.anyDescendant(identified: UITestIdentifiers.overlayPill) }

  // MARK: - U3: the pill

  /// A read wears the pill as "Reading aloud." and takes it down when stopped.
  /// After a dictation, a read that ends must not replay the dictation's
  /// "pasted" notice.
  func testPillShowsAReadAndNeverReplaysAnOldNotice() {
    let harness = readyHarness()
    dictate(in: harness, expecting: UITestIdentifiers.defaultCannedTranscript, "The bound key should dictate")
    sleep(2)  // let the "Pasted" notice clear

    startRead(in: harness)
    waitForLabel(pill, equals: "Reading aloud.", "The pill should show the read")

    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    harness.buttons[UITestIdentifiers.hotkeyTapReleaseButton].click()
    waitForLabel(reading(in: harness), equals: "no", "The second tap should stop the read")
    for _ in 0..<10 {
      XCTAssertFalse(
        pill.exists && pill.label == "Your dictation was pasted.",
        "A read's end must not replay the earlier dictation's notice")
      usleep(100_000)
    }
  }

  // MARK: - U4: a held read on another key

  /// Left ⌃ set to read aloud: held, it reads once the key has been down past
  /// the hold delay; let go, it stops.
  func testHeldReadOnAnotherKey() {
    let harness = readyHarness()
    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetReadAloud].click()
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(reading(in: harness), equals: "yes", "Holding the key should start the read")
    waitForLabel(spoken(in: harness), equals: UITestIdentifiers.cannedSelection)
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    waitForLabel(reading(in: harness), equals: "no", "Letting go should stop a held read")
  }

  // MARK: - U5: ask

  /// A tap-only ask key records from one tap to the next, like a dictation,
  /// then reads the answer.
  func testTappedAsk() {
    let harness = readyHarness()
    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetAsk].click()
    harness.buttons[UITestIdentifiers.harnessSetTapMode].click()
    setTranscript("What does this mean?", in: harness)
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    harness.buttons[UITestIdentifiers.hotkeyTapReleaseButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "A tap should start the ask")
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    harness.buttons[UITestIdentifiers.hotkeyTapReleaseButton].click()
    waitForLabel(
      spoken(in: harness), equals: "Answer to: What does this mean?", timeout: 15, "The next tap should end it")
  }

  /// An ask with nothing said answers nothing — and leaves the key working.
  func testAskWithNothingSaidLeavesTheKeyWorking() {
    let harness = readyHarness()
    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetAsk].click()
    setTranscript("", in: harness)
    holdAsk(in: harness)
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusIdle, timeout: 15)
    XCTAssertEqual(text(of: spoken(in: harness)), "—", "Nothing said, so nothing answered")

    setTranscript("Try again.", in: harness)
    holdAsk(in: harness)
    waitForLabel(spoken(in: harness), equals: "Answer to: Try again.", timeout: 15, "The key should still ask")
  }

  /// Pressing the dictation key while an answer plays stops it and dictates.
  func testPressStopsAnAnswer() {
    let harness = readyHarness()
    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetAsk].click()
    setTranscript("Summarize.", in: harness)
    holdAsk(in: harness)
    waitForLabel(reading(in: harness), equals: "yes", timeout: 15, "The answer should play")

    pick("right ⌘", in: harness)
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(reading(in: harness), equals: "no", "The press should stop the answer")
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "…and dictate")
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
  }

  /// Holds the picked ask key through a request: press, recording, release.
  private func holdAsk(in harness: XCUIElement) {
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "A held ask should record")
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
  }
}
