import XCTest

/// What the two geometry probes share: the keys on screen as a JSON record
/// — every key's frame by its name, the window's frame, whatever else sits
/// in the keyboard — attached beside a screenshot, so `scripts/apple-geometry.sh`
/// and `scripts/keyboard-parity.sh` can read Apple's keyboard and Blurt's the
/// same way and put the two side by side.
@MainActor
enum KeyboardMeasure {
  /// Launches the app on `-BlurtProbeField <face>` and returns it with the
  /// field up and the keyboard asked for.
  static func launch(face: String, arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-BlurtProbeField", face] + arguments
    app.launch()
    return app
  }

  /// Cycles the globe until Blurt's keyboard is up — its `+`, which no
  /// system keyboard has, says so. Blurt must be enabled as a keyboard on
  /// the simulator once by hand (Settings → General → Keyboard → Keyboards).
  static func bringUpBlurt(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    bringUp(
      app, until: blurtMark(app), named: "Blurt's keyboard (enable it in Settings → General → Keyboard)",
      file: file, line: line)
  }

  /// Cycles the globe until the system keyboard is up — XCUITest's one
  /// `Keyboard` element, which a custom keyboard never is. Blurt may be the
  /// keyboard the field remembers from the last run.
  static func bringUpSystem(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    bringUp(
      app, until: app.keyboards.firstMatch,
      named: "the system keyboard (turn off 'simulate hardware keyboard' in Device Hub / Simulator)", file: file,
      line: line)
  }

  /// Blurt's own control: the + that adds a key term.
  private static func blurtMark(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Add a key term")).firstMatch
  }

  /// Waits for any keyboard, then hops with the globe until `target` is on
  /// screen. XCUITest sees the system keyboard as a keyboard and a custom one
  /// only through its controls, so the wait is for either.
  private static func bringUp(
    _ app: XCUIApplication, until target: XCUIElement, named what: String, file: StaticString, line: UInt
  ) {
    let blurt = blurtMark(app)
    let system = app.keyboards.firstMatch
    let deadline = Date().addingTimeInterval(15)
    while !blurt.exists, !system.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    XCTAssertTrue(blurt.exists || system.exists, "no on-screen keyboard", file: file, line: line)
    var hops = 0
    while !target.waitForExistence(timeout: 2), hops < 4 {
      let globe = app.buttons["Next keyboard"]
      XCTAssertTrue(
        globe.waitForExistence(timeout: 5), "no globe key: is more than one keyboard enabled?", file: file, line: line)
      globe.tap()
      hops += 1
    }
    XCTAssertTrue(target.exists, "\(what) never came up", file: file, line: line)
  }

  /// The record for one face: every key by name, the window, the keyboard's
  /// own frame (`keyboard`, or the union of the keys for a custom keyboard,
  /// which XCUITest shows only through its controls) and the other elements
  /// in it. `keys` are the elements that are keys; `others` whatever else
  /// the caller hands in.
  static func record(
    face: String, app: XCUIApplication, keyboard: CGRect, keys: [XCUIElement], others: [XCUIElement]
  ) -> [String: Any] {
    var named: [String: Any] = [:]
    for key in keys {
      let name = key.identifier.isEmpty ? key.label : key.identifier
      guard !name.isEmpty, named[name] == nil else { continue }
      named[name] = rect(key.frame)
    }
    var rest: [String: Any] = [:]
    for element in others {
      let name = element.identifier.isEmpty ? element.label : element.identifier
      guard !name.isEmpty, rest[name] == nil else { continue }
      rest[name] = rect(element.frame)
    }
    return [
      "face": face, "window": rect(app.windows.firstMatch.frame), "keyboard": rect(keyboard), "keys": named,
      "others": rest,
    ]
  }

  /// Attaches the record as `<prefix>-geometry-<face>.json` and the screen
  /// as `<prefix>-keyboard-<face>.png`, kept always.
  static func attach(_ record: [String: Any], prefix: String, face: String, app: XCUIApplication, to test: XCTestCase)
    throws
  {
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
    let json = XCTAttachment(string: text)
    json.name = "\(prefix)-geometry-\(face).json"
    json.lifetime = .keepAlways
    test.add(json)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "\(prefix)-keyboard-\(face).png"
    shot.lifetime = .keepAlways
    test.add(shot)
  }

  static func rect(_ r: CGRect) -> [String: Double] {
    ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
  }
}
