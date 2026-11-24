#if os(macOS)
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// The pasteboard queue a paste and the read-aloud copy fallback share
  /// (issue #341): one borrower at a time, in arrival order, with a paste's
  /// settle/restore inside its turn.
  @Suite("ClipboardTurns", .timeLimit(.minutes(1)))
  struct ClipboardTurnsTests {
    private struct Refused: Error {}

    @Test("a turn queued during another's settle runs only once that settle ends")
    func waitsOutTheSettle() async throws {
      let turns = ClipboardTurns()
      let events = StringListBox()
      let settle = AsyncGate()
      let (paste, _) = turns.enqueue {
        events.append("paste")
      } thenHolding: { _ in
        await settle.wait()
        events.append("restore")
      }
      try await paste.value
      let copy = Task { await turns.run { events.append("copy") } }
      // Only ever waiting here: a correct queue holds the copy however long
      // this is, so the check can't flake the right way round.
      try await Task.sleep(for: .milliseconds(50))
      #expect(events.values == ["paste"])
      settle.open()
      await copy.value
      #expect(events.values == ["paste", "restore", "copy"])
    }

    @Test("a turn whose work fails skips its settle and lets the next one run")
    func failedTurnReleases() async {
      let turns = ClipboardTurns()
      let settled = ValueBox(false)
      let (paste, _) = turns.enqueue { () async throws -> Int in
        throw Refused()
      } thenHolding: { _ in
        settled.value = true
      }
      await #expect(throws: Refused.self) { try await paste.value }
      #expect(await turns.run { 42 } == 42)
      #expect(!settled.value)
    }

    @Test("a ⌘C copy right after a paste sees the user's clipboard, not the transcript")
    func copyAfterPasteSeesUserClipboard() async throws {
      // The issue's first race, end to end: a read-aloud press inside the
      // paste's settle used to snapshot the transcript as the user's clipboard.
      let turns = ClipboardTurns()
      let clip = FakeClipboard(string: "user-clipboard")
      let injector = KeyInjector(
        pasteSettleDuration: .milliseconds(200), postPaste: { true }, clipboard: clip, turns: turns)
      try await injector.insert("dictated text")

      let atCopy = ValueBox<String?>(nil)
      let copy = SelectionCopy(
        pasteboard: FakeCopyPasteboard(),
        postCopy: {
          atCopy.value = clip.string
          return true
        },
        timeout: .milliseconds(20), lateCopyWindow: .zero, turns: turns)
      _ = await copy.copySelection(maxCharacters: 100)
      #expect(atCopy.value == "user-clipboard")
    }
  }
#endif
