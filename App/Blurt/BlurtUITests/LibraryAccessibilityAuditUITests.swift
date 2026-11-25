import XCTest

/// The Library with entries, its menus open, its Delete confirmation, and an
/// open transcript in each of its views.
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

  /// The Library's menus while open — the toolbar's Filter and a row's
  /// context menu — and the confirmation its Delete… asks for, cancelled.
  func testLibraryMenusAndDeleteConfirmation() throws {
    var found: [String] = []
    let main = mainWindow()
    let dictation = row(titled: UITestIdentifiers.seededDictationText)
    XCTAssertTrue(dictation.waitForExistence(timeout: 10))

    main.menuButtons[UITestIdentifiers.libraryFilterMenu].click()
    XCTAssertTrue(app.menuItems["Recordings"].waitForExistence(timeout: 5), "The Filter menu should open")
    try audit("Library, Filter menu open", into: &found)
    app.typeKey(.escape, modifierFlags: [])

    dictation.rightClick()
    let deleteItem = app.menuItems["Delete…"]
    XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), "A row's context menu should open")
    try audit("Library, row context menu open", into: &found)
    deleteItem.click()

    // Scoped to the window's sheet: a bare "Delete" also matches the Touch Bar's.
    let confirmation = main.sheets.firstMatch
    XCTAssertTrue(confirmation.buttons["Delete"].waitForExistence(timeout: 5), "Delete… should ask first")
    try audit("Library, Delete confirmation", into: &found)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5), "Escape should cancel the confirmation")
    XCTAssertTrue(dictation.exists, "Cancelling deletes nothing")
    assertNoAccessibilityIssues(found)
  }
}
