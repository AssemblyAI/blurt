import XCTest

/// The real Blurt keyboard inside Messages — another host, another layout
/// history — repeated, since the system's keyboard container sometimes keeps
/// the previous keyboard's height. Attaches a screenshot per showing and
/// prints where Blurt's + landed, so the container's extra height (the
/// system's backdrop above our surface) can be measured.
final class MessagesKeyboardShot: XCTestCase {
  @MainActor
  func testShots() throws {
    let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    messages.launch()
    // A conversation if there is one, else a new message.
    let cell = messages.cells.firstMatch
    if cell.waitForExistence(timeout: 5) {
      cell.tap()
    } else {
      messages.buttons["compose"].firstMatch.tap()
    }
    // The message field, whatever element Messages makes it this year.
    let field = messages.descendants(matching: .any).matching(
      NSPredicate(format: "placeholderValue == %@ OR label == %@", "iMessage", "iMessage")
    ).firstMatch
    if !field.waitForExistence(timeout: 10) {
      let lines = messages.debugDescription.split(separator: "\n").filter {
        $0.contains("Message") || $0.contains("TextView") || $0.contains("TextField")
      }
      XCTFail("no message field; candidates:\n" + lines.prefix(30).joined(separator: "\n"))
      return
    }
    print("BLURT-FIELD \(field.elementType.rawValue) \(field.frame)")
    let blurt = messages.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add a key term")).firstMatch
    for round in 0..<3 {
      field.tap()
      // Round 1 comes to Blurt from the emoji keyboard, round 2 from the
      // system keyboard: the container keeps the previous keyboard's height
      // when it is taller, which is the band above the surface.
      if round > 0 {
        let globe = messages.buttons["Next keyboard"]
        if blurt.exists, globe.waitForExistence(timeout: 3) { globe.tap() }
        if round == 1 { Thread.sleep(forTimeInterval: 1.5) }
      }
      var hops = 0
      while !blurt.waitForExistence(timeout: 2), hops < 4 {
        let globe = messages.buttons["Next keyboard"]
        XCTAssertTrue(globe.waitForExistence(timeout: 5), "no globe key")
        globe.tap()
        hops += 1
      }
      XCTAssertTrue(blurt.exists, "Blurt never came up in Messages")
      Thread.sleep(forTimeInterval: 2.5)
      print("BLURT-FRAMES round \(round): plus \(blurt.frame) space \(messages.buttons["space"].firstMatch.frame)")
      let shot = XCTAttachment(screenshot: messages.screenshot())
      shot.name = "messages-\(round).png"
      shot.lifetime = .keepAlways
      add(shot)
      // Dismiss and bring it back: swipe the conversation down to hide the keyboard.
      messages.swipeDown()
      Thread.sleep(forTimeInterval: 1.5)
    }
  }
}
