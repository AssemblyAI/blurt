#if os(macOS)
  import AppKit
  import CoreGraphics
  import Testing

  @testable import BlurtEngine

  /// The system side of `KeyInjector`'s seams (`KeyInjector+SystemActions.swift`),
  /// covering the parts that can be asserted without changing the state of the
  /// machine running the suite.
  ///
  /// The line this suite draws: *reads* of process-global state are fair game
  /// (`accessibilityTrusted`, the frontmost-app poll), and so is *building* a
  /// CGEvent. What is deliberately left to running the real app is anything that
  /// mutates the session — `activate` steals focus, and `postCmdV`'s two `.post`
  /// calls would fire a live ⌘V into whatever the developer had open. That is the
  /// same reason `check.sh` runs the XCUITest suite on CI only: it commandeers the
  /// GUI session.
  @Suite("KeyInjector system actions")
  struct KeyInjectorSystemActionsTests {

    // MARK: - Cmd-V event construction

    @Test("cmdVEvents builds a V key-down/key-up pair")
    func cmdVEventsBuildsPair() throws {
      let events = try #require(KeyInjector.cmdVEvents())

      #expect(events.down.type == .keyDown)
      #expect(events.up.type == .keyUp)
      // 0x09 is kVK_ANSI_V. Asserted numerically because the Carbon constant isn't
      // importable here, which is why the source spells it as a literal too — this
      // is the check that keeps that literal honest.
      #expect(events.down.getIntegerValueField(.keyboardEventKeycode) == 0x09)
      #expect(events.up.getIntegerValueField(.keyboardEventKeycode) == 0x09)
    }

    @Test("both Cmd-V events carry the command flag")
    func cmdVEventsCarryCommand() throws {
      let events = try #require(KeyInjector.cmdVEvents())

      // A ⌘-less key-down is a plain "v" — it types a character into the target
      // instead of pasting, which is the visible failure this pins.
      #expect(events.down.flags.contains(.maskCommand))
      // And a ⌘-less key-up reads as the modifier having been released mid-chord.
      #expect(events.up.flags.contains(.maskCommand))
    }

    @Test("Cmd-V events carry no modifier beyond command")
    func cmdVEventsCarryNoOtherModifier() throws {
      let events = try #require(KeyInjector.cmdVEvents())

      // ⌘⌥V and ⌘⇧V are "paste and match style" in most apps, and ⌃⌘V is bound
      // elsewhere again — so a stray extra modifier doesn't fail loudly, it pastes
      // the wrong way. `flags` is assigned (not OR-ed) in `cmdVEvents`, and this is
      // what keeps it that way.
      for flags in [events.down.flags, events.up.flags] {
        #expect(!flags.contains(.maskAlternate))
        #expect(!flags.contains(.maskShift))
        #expect(!flags.contains(.maskControl))
        #expect(!flags.contains(.maskSecondaryFn))
      }
    }

    // MARK: - Accessibility trust probe

    @Test("accessibilityTrusted reports the process-wide AX trust state")
    func accessibilityTrustedMatchesSystem() {
      // The test host's trust state isn't ours to set, so the assertable claim is
      // that the seam is a pass-through and not, say, a hard-coded `true` that would
      // make `KeyInjector` skip its permission check in production.
      #expect(KeyInjector.accessibilityTrusted() == AXIsProcessTrusted())
    }

    // MARK: - Frontmost wait

    @Test("waitUntilFrontmost reports failure for an app that never comes frontmost")
    func waitUntilFrontmostGivesUp() async {
      // The test host is a command-line process with no windows, so the window
      // server never reports it frontmost — the deterministic "activation didn't
      // land" case. `KeyInjector.activateTargetApp` turns this `false` into
      // `.targetAppLost` rather than pasting into the wrong app.
      #expect(await KeyInjector.waitUntilFrontmost(.current) == false)
    }

    @Test("waitUntilFrontmost gives up on a bounded deadline instead of hanging")
    func waitUntilFrontmostIsBounded() async {
      // Sits on the press→paste path, so an unbounded wait would freeze the paste,
      // not just slow it. 350 ms budget; the ceiling leaves room for a loaded CI
      // box's scheduling without being loose enough to pass an unbounded loop.
      let clock = ContinuousClock()
      let elapsed = await clock.measure {
        _ = await KeyInjector.waitUntilFrontmost(.current)
      }
      #expect(elapsed < .seconds(3))
    }
  }
#endif
