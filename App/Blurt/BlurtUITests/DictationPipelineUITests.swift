import XCTest

/// End-to-end coverage of the dictation pipeline — recording audio and pasting
/// the transcript into the focused app — driven through the test harness window.
///
/// In UI-test mode the mic, transcriber, and injector are offline stubs (see
/// `UITestSupport.swift`): "recording" captures a fixed buffer, the transcriber
/// returns the harness's canned transcript, and the injector records what it
/// would have pasted (the harness window plays the role of the target app). That
/// lets these tests exercise the real `DictationSession` → `AppCoordinator`
/// render path — including the phase the menu bar/overlay show — without a
/// microphone, network, or Accessibility-trusted paste.
///
/// These assert against the harness's *default* canned transcript rather than
/// typing a custom one: at launch the main window (not the harness) gets the
/// launch activation, so on a headless CI runner the harness's text field never
/// takes keyboard focus and `typeText` fails ("neither element nor descendant
/// has keyboard focus"). Button clicks don't need focus, and the default value
/// exercises the same record → transcribe → paste path.
final class DictationPipelineUITests: BlurtUITestCase {
  /// The happy path — record → transcribe → paste — driven through the real
  /// dictation *hotkey* (DictationKeyTap → DictationKeyGate → the coordinator's
  /// onStart/onStop), so the trigger-key wiring is covered end to end.
  /// Press-then-release registers as a hold, which records then transcribes.
  func testHotkeyDrivesRecordTranscribePaste() {
    let harness = harnessWindow()

    harness.buttons[UITestIdentifiers.setKeyButton].click()  // the hotkey honors the key gate

    let status = harness.staticTexts[UITestIdentifiers.statusLabel]

    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(status, equals: "recording", "Hotkey press should drive status to recording")

    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()

    let pasted = harness.staticTexts[UITestIdentifiers.pastedLabel]
    waitForLabel(
      pasted, equals: UITestIdentifiers.defaultCannedTranscript, timeout: 15,
      "Hotkey release should paste the transcript")
    waitForLabel(status, equals: "idle", "Pipeline should return to idle after pasting")
  }

  /// The same happy path driven through the harness's Start/Stop buttons, which
  /// call the session directly (`beginDictation`/`endDictation`) rather than the
  /// key tap. Complements the hotkey test above: it covers the direct-session
  /// seam the overlay/menu-bar affordances use, independent of the tap wiring.
  func testStartStopButtonsDriveRecordTranscribePaste() {
    let harness = harnessWindow()

    harness.buttons[UITestIdentifiers.setKeyButton].click()  // begin gates on a saved key

    let status = harness.staticTexts[UITestIdentifiers.statusLabel]

    harness.buttons[UITestIdentifiers.startButton].click()
    waitForLabel(status, equals: "recording", "Start should drive status to recording")

    harness.buttons[UITestIdentifiers.stopButton].click()

    let pasted = harness.staticTexts[UITestIdentifiers.pastedLabel]
    waitForLabel(
      pasted, equals: UITestIdentifiers.defaultCannedTranscript, timeout: 15,
      "Stop should paste the transcript")
    waitForLabel(status, equals: "idle", "Pipeline should return to idle after pasting")
  }

  /// The pipeline re-arms cleanly: two back-to-back dictations each record,
  /// paste, and settle to idle. Guards against a completed run leaving stale
  /// state that blocks the next one.
  func testPipelineRunsTwiceInARow() {
    let harness = harnessWindow()

    harness.buttons[UITestIdentifiers.setKeyButton].click()

    let status = harness.staticTexts[UITestIdentifiers.statusLabel]
    let pasted = harness.staticTexts[UITestIdentifiers.pastedLabel]

    for pass in 1...2 {
      harness.buttons[UITestIdentifiers.startButton].click()
      waitForLabel(status, equals: "recording", "Pass \(pass): press should record")

      harness.buttons[UITestIdentifiers.stopButton].click()
      waitForLabel(
        pasted, equals: UITestIdentifiers.defaultCannedTranscript, timeout: 15,
        "Pass \(pass): release should paste the transcript")
      waitForLabel(status, equals: "idle", "Pass \(pass): pipeline should return to idle")
    }
  }

  /// The floating overlay pill tracks the live pipeline: it shows the recording
  /// state while dictation is in flight, then leaves the screen once the pipeline
  /// flows through transcribe → paste-notice and settles back to idle. Exercises
  /// the real `OverlayView` / `OverlayWindowController` render path — including the
  /// waveform and the transient notice — which the harness's status read-out (a
  /// mirror of `menuBarStatus`) never touches.
  func testOverlayPillTracksDictation() {
    let harness = harnessWindow()
    harness.buttons[UITestIdentifiers.setKeyButton].click()

    let status = harness.staticTexts[UITestIdentifiers.statusLabel]
    // The pill lives on a separate floating panel, so search the whole app tree
    // (not just the harness window) and match by identifier across element types.
    let pill = app.descendants(matching: .any).matching(identifier: UITestIdentifiers.overlayPill).firstMatch

    harness.buttons[UITestIdentifiers.startButton].click()
    waitForLabel(status, equals: "recording", "Start should drive status to recording")
    waitForLabel(pill, equals: "Recording.", "Overlay pill should show the recording state")

    harness.buttons[UITestIdentifiers.stopButton].click()
    waitForLabel(status, equals: "idle", "Pipeline should return to idle after pasting")
    // Once the pipeline settles, the pill fades out and leaves the AX tree — so an
    // absent element is the "no dictation happening" resting state.
    XCTAssertTrue(
      pill.waitForNonExistence(timeout: 10),
      "Overlay pill should leave the screen after the pipeline settles to idle")
  }

  /// Cancelling an in-flight recording injects nothing and returns to idle.
  func testCancelDiscardsDictation() {
    let harness = harnessWindow()
    harness.buttons[UITestIdentifiers.setKeyButton].click()

    let status = harness.staticTexts[UITestIdentifiers.statusLabel]

    harness.buttons[UITestIdentifiers.startButton].click()
    waitForLabel(status, equals: "recording")

    harness.buttons[UITestIdentifiers.cancelButton].click()
    waitForLabel(status, equals: "idle", "Cancel should return the pipeline to idle")

    // Nothing was pasted. The read-out is a plain `Text` bound to the injector's
    // recorded paste; while it's the empty string SwiftUI emits no accessibility
    // element at all, so an absent element *is* the "nothing pasted" state.
    // (Reading `.value` of a non-existent element would raise instead.)
    let pasted = harness.staticTexts[UITestIdentifiers.pastedLabel]
    let pastedValue = pasted.exists ? (pasted.value as? String ?? "") : ""
    XCTAssertEqual(pastedValue, "", "Cancelled dictation must not paste any text")
  }

  /// A completed dictation lands in the app's recent-dictations list
  /// (`AppCoordinator.recentDictations`, its newest entry surfaced by the
  /// harness's echo read-out) — the data path the ready window's "Recent"
  /// section renders. The list persists (no revert), so we only assert it
  /// populates.
  func testTranscriptLandsInRecentDictations() {
    let harness = harnessWindow()
    harness.buttons[UITestIdentifiers.setKeyButton].click()

    let echo = harness.staticTexts[UITestIdentifiers.transcriptEchoLabel]

    harness.buttons[UITestIdentifiers.startButton].click()
    harness.buttons[UITestIdentifiers.stopButton].click()

    waitForLabel(
      echo, equals: UITestIdentifiers.defaultCannedTranscript, timeout: 15,
      "Completed dictation should appear as the newest recent-dictations entry")
  }
}
