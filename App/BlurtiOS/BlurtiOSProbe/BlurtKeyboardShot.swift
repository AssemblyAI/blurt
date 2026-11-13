import XCTest

/// A screenshot of the real Blurt keyboard — the extension, in its own
/// process, over a text field — on the face asked for. Launches the app on
/// `-BlurtProbeField`, taps the system's globe until Blurt is up, and
/// attaches the screen. `scripts/ios-keyboard-shot.sh` runs it and exports
/// the attachment.
final class BlurtKeyboardShot: XCTestCase {
  @MainActor
  func testShot() throws {
    let arguments =
      ProcessInfo.processInfo.environment["BLURT_PROBE_ARGS"]?.split(separator: " ").map(String.init) ?? []
    let app = KeyboardMeasure.launch(face: arguments.first ?? "light", arguments: Array(arguments.dropFirst()))
    KeyboardMeasure.bringUpBlurt(app)
    Thread.sleep(forTimeInterval: 2)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "blurt-keyboard.png"
    shot.lifetime = .keepAlways
    add(shot)
  }
}
