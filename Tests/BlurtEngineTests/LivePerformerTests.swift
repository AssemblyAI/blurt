#if os(macOS)
  import AppKit
  import ApplicationServices
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// The real performer (`SystemVoiceCommandPerformer`) against a real app:
  /// the fixture window (`Tests/CommandFixture`), which records what was done
  /// to it. Each step is judged by that record — a press it saw, a slider's
  /// value, the selected row — never a screenshot.
  ///
  /// Two gates, both needed: BLURT_LIVE_AX_TESTS=1, since the suite clicks,
  /// moves the pointer and drives the menu bar of the machine it runs on; and
  /// Accessibility trust for the process running it (the terminal, or Xcode).
  /// And one guard on every step: the fixture must be the app in front, or the
  /// suite stops — input meant for it must never land in another app.
  @Suite(
    "Live performer", .serialized, .tags(.drivesThisMac),
    .drivesThisMac("BLURT_LIVE_AX_TESTS", to: "run the performer against the fixture app"),
    .timeLimit(.minutes(1)))
  struct LivePerformerTests {
    @Test("every element action lands in the fixture, as the fixture records it")
    func elementActions() async throws {
      let fixture = try await CommandFixtureApp.launch()
      defer { fixture.quit() }
      let performer = SystemVoiceCommandPerformer()
      await performer.commandStarting()
      let screen = await performer.screenContext()
      #expect(screen.appName == "CommandFixture")
      func id(_ kind: String, _ label: String) throws -> Int {
        try #require(screen.elements.first { $0.kind == kind && $0.label == label }?.id, "\(kind) \(label) not listed")
      }
      func run(_ step: VoiceCommandStep) async throws -> String? {
        try await fixture.requireFrontmost()
        let how = try await performer.perform(step)
        // wall-clock-ok: drives real hardware or a real app, which run on real time
        try await Task.sleep(for: performer.settle)
        return how
      }

      // Each press's answer is held before it is checked, so a failure prints
      // what the performer did instead ("click: AXPress refused", say): with
      // the call inside the macro, a CI run that missed this press logged no
      // value, and the fixture never recorded it (run 46015518999).
      let reply = try await run(.pressElement(id("button", "Reply")))
      #expect(reply == "AXPress")
      #expect(try await fixture.state { $0.pressed == ["Reply"] }.pressed == ["Reply"])
      // A native app's press is trusted even when nothing it reads changes —
      // checked, a Send whose window stays put was pressed twice, and so was
      // every key of Calculator's (`SystemVoiceCommandPerformer.checksPress`).
      let send = try await run(.pressElement(id("button", "Send")))
      #expect(send == "AXPress")
      #expect(try await fixture.state { $0.pressed.count == 2 }.pressed == ["Reply", "Send"])

      await #expect(throws: VoiceCommandError.refused("press Delete")) {
        try await run(.pressElement(id("button", "Delete")))
      }
      #expect(try fixture.state().pressed == ["Reply", "Send"])

      let focused = try await run(.focusElement(id("text field", "Search")))
      let field = try await fixture.state { $0.focused == "Search" }
      #expect(field.selection == [0, "old search text".count], "focus noted: \(focused ?? "")")

      _ = try await run(.setValue(element: id("slider", "Volume"), value: "30"))
      #expect(try await fixture.state { $0.slider == 30 }.slider == 30)
      _ = try await run(.increment(id("slider", "Volume")))
      #expect(try await fixture.state { $0.slider > 30 }.slider > 30)

      _ = try await run(.select(id("row", "Albums")))
      #expect(try await fixture.state { $0.row == "Albums" }.row == "Albums")

      _ = try await run(.pressButton("reply"))
      #expect(try await fixture.state { $0.pressed.count == 3 }.pressed.last == "Reply")

      await performer.commandEnded()
    }

    @Test("menu items, scrolling and window arrangement land in the fixture; a destructive item is refused")
    func appActions() async throws {
      let fixture = try await CommandFixtureApp.launch()
      defer { fixture.quit() }
      let performer = SystemVoiceCommandPerformer()
      func run(_ step: VoiceCommandStep) async throws {
        try await fixture.requireFrontmost()
        _ = try await performer.perform(step)
      }

      try await run(.chooseMenuItem(["Fixture", "make noise"]))
      #expect(try await fixture.state { $0.menu == ["Make Noise"] }.menu == ["Make Noise"])
      await #expect(throws: VoiceCommandError.refused("choose Fixture › Move to Trash")) {
        try await run(.chooseMenuItem(["Fixture", "Move to Trash"]))
      }
      #expect(try fixture.state().menu == ["Make Noise"])
      // A wrong path whose last title is right: that item, wherever it is.
      try await run(.chooseMenuItem(["Edit", "Make Noise"]))
      #expect(try await fixture.state { $0.menu.count == 2 }.menu == ["Make Noise", "Make Noise"])

      _ = await performer.screenContext()
      let before = try fixture.state().scrollY
      try await run(.scroll(.down, element: nil))
      #expect(try await fixture.state { $0.scrollY != before }.scrollY != before)

      try await run(.window(.leftHalf))
      let screen = try #require(NSScreen.main?.visibleFrame)
      let moved = try await fixture.state { abs($0.windowX - screen.minX) < 2 }
      #expect(abs(moved.windowWidth - screen.width / 2) < 2)
    }
  }

#endif
