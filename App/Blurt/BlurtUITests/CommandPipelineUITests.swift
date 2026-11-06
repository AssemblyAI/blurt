import XCTest

/// Control Your Mac end to end in the real app: the key's press and release
/// through the real key tap, the session's recording and transcription, the
/// router's command path, the pill — with the stub planner and performer
/// (`UITestSupport`) in place of the gateway and Accessibility.
final class CommandPipelineUITests: BlurtUITestCase {
  private var pill: XCUIElement { app.anyDescendant(identified: UITestIdentifiers.overlayPill) }

  private func planned(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.plannedLabel]
  }

  private func performed(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.performedLabel]
  }

  /// The pill's last brief notice, kept by the harness: the pill shows one for
  /// under a second, too briefly for XCUITest's polling to catch.
  private func notice(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.noticeLabel]
  }

  /// The picked key held while `command` is "said".
  private func command(_ command: String, in harness: XCUIElement) {
    setTranscript(command, in: harness)
    hold(in: harness)
  }

  /// Left ⌃ (any key would do) set to Control Your Mac.
  private func commandKey(in harness: XCUIElement) {
    bind("left ⌃", with: UITestIdentifiers.harnessSetCommand, in: harness)
  }

  /// A held command key: recorded, transcribed, planned, each step carried out, Done.
  func testCommandIsPlannedPerformedAndDone() {
    let harness = readyHarness()
    commandKey(in: harness)
    command("Open Slack", in: harness)
    waitForLabel(planned(in: harness), equals: "Open Slack", timeout: 15, "The spoken command should reach the planner")
    waitForText(performed(in: harness), containing: "openApp(\"Slack\")", "The planned step should be carried out")
    waitForLabel(
      notice(in: harness), equals: "Your command was carried out.", "The pill should say the command was done")
  }

  /// While a command is still planning, the pill stays up saying it's working —
  /// never gone, which reads as frozen — until the command is done.
  func testPillStaysUpWhileTheCommandWorks() {
    let harness = readyHarness()
    commandKey(in: harness)
    command("Slowly open Notes", in: harness)
    waitForLabel(planned(in: harness), equals: "Slowly open Notes", timeout: 15, "The command should be planning")
    // The stub plans for 3 s: through all of it, the pill is up and working.
    for _ in 0..<20 {
      if text(of: performed(in: harness)).contains("Notes") { break }
      XCTAssertTrue(pill.exists && pill.isHittable, "The pill went away while the command was still working")
      // Working — or, if the command ended since the check above, just done:
      // what must never happen is the pill leaving, or saying anything else.
      XCTAssertTrue(
        ["Carrying out your command.", "Your command was carried out."].contains(pill.label),
        "The pill should say the command is working, got \(pill.label)")
      usleep(100_000)
    }
    waitForText(performed(in: harness), containing: "openApp(\"Notes\")", timeout: 10, "The command should finish")
    waitForLabel(notice(in: harness), equals: "Your command was carried out.", "Then the pill should say it's done")
  }

  /// A typed step pastes through the session's own injector, as a dictation would.
  func testTypedStepPastesThroughTheSession() {
    let harness = readyHarness()
    commandKey(in: harness)
    command("Type hello there", in: harness)
    waitForLabel(pastedLabel(in: harness), equals: "hello there", timeout: 15, "A typed step should paste")
  }

  /// "That didn't work" is noted against the last command, never planned.
  func testComplaintIsNotedNotPlanned() {
    let harness = readyHarness()
    commandKey(in: harness)
    command("Mute", in: harness)
    waitForText(performed(in: harness), containing: "media(", timeout: 15, "The first command should run")
    command("That didn't work", in: harness)
    waitForLabel(
      notice(in: harness), equals: "Noted: the last command was marked as not working.", "The complaint should be noted"
    )
    XCTAssertEqual(text(of: planned(in: harness)), "Mute", "A complaint is never planned")
  }

  /// Something overheard — longer than any command — is refused before planning.
  func testOverheardSpeechIsNotPlanned() {
    let harness = readyHarness()
    commandKey(in: harness)
    command(String(repeating: "and the results are coming in tonight ", count: 10), in: harness)
    waitForLabel(
      notice(in: harness), equals: "That was too long to be a command.", timeout: 15, "A long stretch should be refused"
    )
    XCTAssertEqual(text(of: planned(in: harness)), "—", "Nothing overheard is planned")
  }

  /// A command the planner can't do says so, and the key works again after.
  func testUnplannableCommandFailsAndTheKeyWorksAgain() {
    let harness = readyHarness()
    commandKey(in: harness)
    command("Juggle the windows", in: harness)
    waitForLabel(
      notice(in: harness), equals: "Blurt can’t do that command.", timeout: 15, "A command it can't do should say so")
    command("Open Music", in: harness)
    waitForText(performed(in: harness), containing: "openApp(\"Music\")", timeout: 15, "The key should still work")
  }

  /// A rewrite key: the canned selection rewritten as the spoken instruction asks, pasted over it.
  func testRewriteKeyPastesTheRewrite() {
    let harness = readyHarness()
    bind("left ⌃", with: UITestIdentifiers.harnessSetRewrite, in: harness)
    command("Make it shorter", in: harness)
    waitForText(
      pastedLabel(in: harness), containing: "Rewritten (Make it shorter)", timeout: 15, "The rewrite should paste")
  }

  /// A compose key: no selection needed; what the spoken instructions describe is pasted at the cursor.
  func testComposeKeyPastesTheComposition() {
    let harness = readyHarness()
    bind("left ⌃", with: UITestIdentifiers.harnessSetCompose, in: harness)
    command("Tell Dan we should ship it", in: harness)
    waitForText(
      pastedLabel(in: harness), containing: "Composed (Tell Dan we should ship it)", timeout: 15,
      "The composition should paste")
  }
}
