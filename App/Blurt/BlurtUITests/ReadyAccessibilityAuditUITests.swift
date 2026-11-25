import XCTest

/// The screens behind setup: the ready screen with an empty Library.
final class ReadyAccessibilityAuditUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] { [UITestIdentifiers.readyLaunchArgument] }

  func testReadyScreenEmptyLibrary() throws {
    var found: [String] = []
    mainWindow()
    try audit("ready, empty Library", into: &found)
    assertNoAccessibilityIssues(found)
  }

  /// The overlay pill while recording, and while reading aloud.
  func testOverlayPill() throws {
    var found: [String] = []
    let pill = app.anyDescendant(identified: UITestIdentifiers.overlayPill)
    let harness = readyHarness()
    harness.buttons[UITestIdentifiers.startButton].click()
    waitForLabel(pill, equals: "Recording.", "The pill should show the recording")
    try audit("overlay pill, recording", into: &found)
    harness.buttons[UITestIdentifiers.cancelButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusIdle)

    startRead(in: harness)
    waitForLabel(pill, equals: "Reading aloud.", "The pill should show the read")
    try audit("overlay pill, reading aloud", into: &found)
    assertNoAccessibilityIssues(found)
  }
}
