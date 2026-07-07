import XCTest

/// Launch-time performance guard. Deliberately *not* a `BlurtUITestCase`
/// subclass: that base launches the app in `setUp`, but this test owns the
/// launch so it can time it. Swift Testing has no performance API, so this stays
/// XCTest.
///
/// Like the engine perf tests, this asserts an explicit budget rather than an
/// XCTest baseline (baselines are device-keyed and wouldn't gate on CI). The
/// budget is generous versus the ~0.4 s cold launch measured locally — enough
/// headroom for slower CI hardware, tight enough to catch a launch that
/// regresses into seconds (e.g. synchronous work added to
/// `applicationDidFinishLaunching`).
@MainActor
final class LaunchPerformanceUITests: XCTestCase {
  func testLaunchWithinBudget() {
    var samples: [Duration] = []
    for i in 0..<3 {
      let app = XCUIApplication()
      app.launchArguments += [UITestIdentifiers.launchArgument]
      let elapsed = ContinuousClock().measure { app.launch() }
      XCTAssertTrue(
        app.windows[UITestIdentifiers.harnessWindowTitle].waitForExistence(timeout: 15),
        "app did not present its window after launch")
      if i > 0 { samples.append(elapsed) }  // drop warm-up
      app.terminate()
    }
    let median = samples.sorted()[samples.count / 2]
    XCTAssertLessThan(
      median, .seconds(5),
      "cold launch regressed: median \(median) over budget")
  }
}
