import XCTest

/// The Library with entries, its menus open, its Delete confirmation, an
/// open transcript in each of its views, and a live recording's page (on
/// Record's offline doubles) with its Discard question.
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

  /// A recording's live page: listening, with two speakers' turns streamed
  /// in, paused, and asking before Discard.
  func testLiveRecordingPage() throws {
    var found: [String] = []
    let (harness, main) = readyScreenWindows()
    startLiveRecording(in: main)
    try audit("live recording, listening", into: &found)

    for _ in 0..<4 { releaseLiveTurn(in: harness) }
    let lastTurn = NSPredicate(format: "label CONTAINS %@", UITestIdentifiers.liveFinalB)
    XCTAssertTrue(main.descendants(matching: .any).matching(lastTurn).firstMatch.waitForExistence(timeout: 5))
    try audit("live recording, two speakers", into: &found)

    main.buttons[UITestIdentifiers.liveRecordingPause].click()
    // The status line is one Text around a live timer: "Paused" can come
    // through as its value rather than its label, as TranscriptionUITests reads it.
    let paused = main.staticTexts
      .matching(NSPredicate(format: "label CONTAINS 'Paused' OR value CONTAINS 'Paused'")).firstMatch
    XCTAssertTrue(paused.waitForExistence(timeout: 5), "Pause should say so")
    try audit("live recording, paused", into: &found)

    main.buttons[UITestIdentifiers.liveRecordingDiscard].click()
    XCTAssertTrue(main.sheets.buttons["Discard"].firstMatch.waitForExistence(timeout: 5), "Discard… should ask first")
    try audit("live recording, Discard question", into: &found)
    app.typeKey(.escape, modifierFlags: [])
    assertNoAccessibilityIssues(found)
  }
}
