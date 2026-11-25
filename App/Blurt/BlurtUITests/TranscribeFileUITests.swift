import XCTest

/// Transcribing a file end to end: launched with `-BlurtUITestTranscribeSample`,
/// the app transcribes a sample file at launch through the canned async API —
/// XCUITest can't drive a Finder drag — and names it with the canned LLM.
final class TranscribeFileUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] {
    [UITestIdentifiers.readyLaunchArgument, UITestIdentifiers.transcribeSampleLaunchArgument]
  }

  func testTranscribingAFileSavesItUnderItsTitle() {
    let main = mainWindow()
    // The window slides to the new transcript, its turns under each speaker…
    let speakerPredicate = NSPredicate(
      format: "label CONTAINS %@ OR value CONTAINS %@",
      UITestIdentifiers.cannedFileSpeakerA,
      UITestIdentifiers.cannedFileSpeakerA
    )
    let speakerTurn = app.descendants(matching: .any).matching(speakerPredicate).firstMatch
    XCTAssertTrue(
      speakerTurn.waitForExistence(timeout: 15),
      "The window opens the new transcript"
    )
    // …and the entry is saved under the LLM's title.
    let title = UITestIdentifiers.cannedFileTitle
    XCTAssertTrue(
      main.descendants(matching: .any)
        .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", title, title)).firstMatch
        .waitForExistence(timeout: 15),
      "The transcribed file is saved under the LLM's title"
    )
  }
}
