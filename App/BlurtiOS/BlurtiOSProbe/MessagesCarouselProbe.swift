import XCTest

/// The panel's carousel inside Messages — Neil's host — swiped every which
/// way from one fixed point, with a screenshot after each swipe and a
/// FLOW line saying which page is up. Run under `simctl io recordVideo` to
/// see the motion itself. Blurt must be enabled as a keyboard on the
/// simulator, and the App Group set to the panel (`-BlurtProbeField light a
/// panel` once).
@MainActor
final class MessagesCarouselProbe: XCTestCase {
  private var shots = 0

  func testSwipes() throws {
    continueAfterFailure = true
    let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
    messages.launch()
    let plus = try bringUpBlurt(in: messages)
    Thread.sleep(forTimeInterval: 2)
    let mic = messages.buttons.matching(NSPredicate(format: "identifier == %@", "blurt-mic")).firstMatch
    XCTAssertTrue(mic.exists, "no mic key")
    print("FLOW-INFO mic \(mic.frame) plus \(plus.frame)")
    let inkUp = MicPixels.ink(messages, mic: mic) ?? 0
    print("FLOW-\(inkUp > MicPixels.drawnThreshold ? "OK" : "FAIL"): the mic is drawn on appearance (ink \(inkUp))")
    shot(messages, "up")
    // One fixed point: the gap under the panel's mic.
    let anchor = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.15)).screenPoint
    let fixed = messages.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: anchor.x, dy: anchor.y))
    let sequence = [
      Swipe("left", -160, 1.2), Swipe("right", 160, 1.2), Swipe("left", -160, 1.2), Swipe("left", -160, 1.2),
      Swipe("right", 160, 1.2), Swipe("right", 160, 1.2), Swipe("left", -160, 0), Swipe("right", 160, 1.2),
      Swipe("left", -160, 0), Swipe("left", -160, 1.2), Swipe("right", 160, 0), Swipe("left", -160, 1.2),
    ]
    for (index, swipe) in sequence.enumerated() {
      fixed.press(forDuration: 0.05, thenDragTo: fixed.withOffset(CGVector(dx: swipe.dx, dy: 0)))
      guard swipe.pause > 0 else { continue }
      Thread.sleep(forTimeInterval: swipe.pause)
      let keys = messages.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Q", "q")).firstMatch
      // The panel's mic is element-wide when aligned to an edge, so its
      // presence, not its width, says the panel is up.
      let up = keys.exists ? "keys" : (mic.exists ? "panel" : "NEITHER")
      let micFrame = mic.exists ? mic.frame : .zero
      let plusFrame = plus.exists ? plus.frame : .zero
      print("FLOW-INFO after \(index + 1) (\(swipe.name)): \(up) mic \(micFrame) plus \(plusFrame)")
      if up == "panel" {
        // The panel's mic key is the grille's box, the + beside it: anything
        // else is the vanished-mic state Neil sees in Messages.
        let beside = plusFrame.minX >= micFrame.maxX - 1 || plusFrame.maxX <= micFrame.minX + 1
        let sound = micFrame.width > 100 && micFrame.height > 60 && beside && abs(plusFrame.midY - micFrame.midY) < 4
        print("FLOW-\(sound ? "OK" : "FAIL"): panel back with the mic full size and the + beside it (\(index + 1))")
        let ink = MicPixels.ink(messages, mic: mic) ?? 0
        print(
          "FLOW-\(ink > MicPixels.drawnThreshold ? "OK" : "FAIL"): the mic is drawn after the return (\(index + 1), ink \(ink))"
        )
        if !sound {
          print(
            "FLOW-TREE\n\(messages.debugDescription.split(separator: "\n").filter { $0.contains("Button") || $0.contains("Other") }.prefix(60).joined(separator: "\n"))"
          )
        }
      }
      shot(messages, "\(index + 1)-\(swipe.name)")
    }
  }

  /// One swipe: how far, and how long to wait after it (0: the next comes at once).
  private struct Swipe {
    let name: String
    let dx: CGFloat
    let pause: TimeInterval
    init(_ name: String, _ dx: CGFloat, _ pause: TimeInterval) {
      self.name = name
      self.dx = dx
      self.pause = pause
    }
  }

  /// A conversation, its field, and Blurt on it: the globe's menu goes
  /// straight there; hopping does when there is no menu. Returns the +.
  private func bringUpBlurt(in messages: XCUIApplication) throws -> XCUIElement {
    let cell = messages.cells.firstMatch
    if cell.waitForExistence(timeout: 5) {
      cell.tap()
    } else {
      messages.buttons["compose"].firstMatch.tap()
    }
    let field = messages.descendants(matching: .any).matching(
      NSPredicate(format: "placeholderValue == %@ OR label == %@", "iMessage", "iMessage")
    ).firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10), "no message field")
    field.tap()
    let plus = messages.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add a key term")).firstMatch
    var hops = 0
    while !plus.waitForExistence(timeout: 2), hops < 12 {
      let globe = messages.buttons["Next keyboard"]
      XCTAssertTrue(globe.waitForExistence(timeout: 5), "no globe key")
      if hops == 0 {
        globe.press(forDuration: 1)
        let item = messages.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Blurt")).firstMatch
        if item.waitForExistence(timeout: 2) {
          item.tap()
          hops += 1
          continue
        }
      }
      globe.tap()
      hops += 1
    }
    XCTAssertTrue(plus.exists, "Blurt never came up in Messages")
    return plus
  }

  private func shot(_ app: XCUIApplication, _ name: String) {
    shots += 1
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "flow-\(String(format: "%02d", shots))-\(name).png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
