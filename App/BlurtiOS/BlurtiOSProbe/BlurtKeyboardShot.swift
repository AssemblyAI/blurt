import XCTest

/// A screenshot of the real Blurt keyboard — the extension, in its own
/// process, over a text field — for the states the gallery cannot vouch
/// for. Launches the app on `-BlurtProbeField` (which also sets the face,
/// the mic concept and the layout), taps the system's globe until Blurt is
/// up, and attaches the screen. `scripts/ios-keyboard-shot.sh` runs it and
/// exports the attachment. Blurt must be enabled as a keyboard on the
/// simulator (Settings → General → Keyboard → Keyboards) once by hand.
final class BlurtKeyboardShot: XCTestCase {
  @MainActor
  func testShot() throws {
    let arguments =
      ProcessInfo.processInfo.environment["BLURT_PROBE_ARGS"]?.split(separator: " ").map(String.init) ?? []
    let app = XCUIApplication()
    app.launchArguments = ["-BlurtProbeField"] + (arguments.isEmpty ? ["light"] : arguments)
    app.launch()
    // Blurt's own control: the + that adds a key term, which no system
    // keyboard has. XCUITest sees the system keyboard as a keyboard and a
    // custom one only through its controls, so wait for either; then the
    // globe cycles the enabled keyboards until Blurt is up.
    let blurt = app.buttons["Add a key term"]
    let system = app.keyboards.firstMatch
    let deadline = Date().addingTimeInterval(15)
    while !blurt.exists, !system.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    XCTAssertTrue(blurt.exists || system.exists, "no on-screen keyboard")
    var hops = 0
    while !blurt.waitForExistence(timeout: 2), hops < 4 {
      let globe = app.buttons["Next keyboard"]
      XCTAssertTrue(globe.waitForExistence(timeout: 5), "no globe key: is more than one keyboard enabled?")
      globe.tap()
      hops += 1
    }
    XCTAssertTrue(blurt.exists, "Blurt's keyboard never came up: enable it in Settings → General → Keyboard")
    Thread.sleep(forTimeInterval: 2)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "blurt-keyboard.png"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
