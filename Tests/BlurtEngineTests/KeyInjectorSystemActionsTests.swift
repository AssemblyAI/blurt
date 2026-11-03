#if os(macOS)
  import AppKit
  import CoreGraphics
  import Synchronization
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
  @Suite("KeyInjector system actions", .timeLimit(.minutes(1)))
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

    @Test("cmdCEvents builds a ⌘C pair on kVK_ANSI_C")
    func cmdCEventsBuildsPair() throws {
      let events = try #require(KeyInjector.cmdCEvents())
      #expect(events.down.type == .keyDown)
      #expect(events.up.type == .keyUp)
      #expect(events.down.getIntegerValueField(.keyboardEventKeycode) == 0x08)
      #expect(events.down.flags.contains(.maskCommand))
      #expect(events.up.flags.contains(.maskCommand))
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

    // MARK: - User-input idle probe

    @Test("secondsSinceHardwareInput reports the newest key or click across types")
    func secondsSinceHardwareInputIsNewestOfTypes() {
      // The host's real input history isn't ours to set, so the assertable claim is
      // that the seam takes the *newest* input (the minimum idle time) — a keypress
      // alone must be enough to drop the same-window separator fallback.
      let keyIdle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
      let idle = KeyInjector.secondsSinceHardwareInput()
      #expect(idle >= 0)
      #expect(idle <= keyIdle + 1)
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

    private static let checksPerBudget = Int(
      KeyInjector.frontmostWaitBudget / KeyInjector.frontmostPollInterval)

    /// Runs the frontmost wait on a `TestClock`, its check turning true from
    /// check number `trueFrom` (never, if nil), and advances the clock through
    /// `sleeps` of its polls the way `MicLivenessTests` drives its wait: each
    /// advance waits for the sleep it means to wake, matched on its deadline, so
    /// a loop sleeping some other interval hangs here (the suite's time limit
    /// catches it) rather than passing.
    private struct PollRun {
      let result: Bool
      let checks: Int
      let elapsed: Duration
    }

    private func runPoll(trueFrom: Int?, sleeps: Int) async -> PollRun {
      let clock = TestClock()
      let checks = Mutex(0)
      async let result = KeyInjector.poll(
        for: KeyInjector.frontmostWaitBudget, every: KeyInjector.frontmostPollInterval, clock: clock,
        until: {
          checks.withLock { count in
            count += 1
            return trueFrom.map { count >= $0 } ?? false
          }
        })
      for _ in 0..<sleeps {
        await clock.waitUntilSleeping(for: KeyInjector.frontmostPollInterval)
        clock.advance(by: KeyInjector.frontmostPollInterval)
      }
      return PollRun(result: await result, checks: checks.withLock { $0 }, elapsed: clock.now.offset)
    }

    @Test("the frontmost wait gives up once its budget is spent instead of hanging")
    func pollIsBounded() async {
      // Sits on the press→paste path, so an unbounded wait would freeze the
      // paste, not just slow it. One check per interval across the budget, plus
      // the last read past the deadline.
      let run = await runPoll(trueFrom: nil, sleeps: Self.checksPerBudget)
      #expect(run.result == false)
      #expect(run.checks == Self.checksPerBudget + 1)
      #expect(run.elapsed == KeyInjector.frontmostWaitBudget)
    }

    @Test("the frontmost wait returns as soon as the target is frontmost")
    func pollStopsEarly() async {
      let run = await runPoll(trueFrom: 3, sleeps: 2)
      #expect(run.result)
      #expect(run.checks == 3)
    }

    @Test("the last read past the deadline still catches an activation that just landed")
    func pollTakesTheLastRead() async {
      let run = await runPoll(trueFrom: Self.checksPerBudget + 1, sleeps: Self.checksPerBudget)
      #expect(run.result)
      #expect(run.checks == Self.checksPerBudget + 1)
    }
  }
#endif
