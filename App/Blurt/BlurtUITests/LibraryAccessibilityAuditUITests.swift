import XCTest

/// The Library with entries, and an open transcript in each of its views.
final class LibraryAccessibilityAuditUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] {
    [UITestIdentifiers.readyLaunchArgument, UITestIdentifiers.seedHistoryLaunchArgument]
  }

  func testLibraryAndTranscriptPage() throws {
    var found: [String] = []
    mainWindow()
    let recording = row(titled: UITestIdentifiers.seededRecordingTitle)
    XCTAssertTrue(recording.waitForExistence(timeout: 10))
    // The toolbar's icon-only menus say what they are, not what their symbol
    // is called (VoiceOver read the View menu as "Sparkle").
    let filter = app.windows[UITestIdentifiers.mainWindowTitle].menuButtons[UITestIdentifiers.libraryFilterMenu]
    XCTAssertEqual(filter.label, "Filter")
    try audit("Library, seeded", into: &found)

    recording.doubleClick()
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 5), "The transcript page should open")
    XCTAssertEqual(viewPicker.label, "View")
    try audit("transcript page, Full", into: &found)
    showView("Plain text")
    try audit("transcript page, Plain text", into: &found)
    showView("Meeting notes")
    let result = NSPredicate(
      format: "label CONTAINS %@ OR value CONTAINS %@",
      UITestIdentifiers.cannedTaskResult,
      UITestIdentifiers.cannedTaskResult
    )
    XCTAssertTrue(app.descendants(matching: .any).matching(result).firstMatch.waitForExistence(timeout: 10))
    try audit("transcript page, Meeting notes", into: &found)
    assertNoAccessibilityIssues(found)
  }
}
