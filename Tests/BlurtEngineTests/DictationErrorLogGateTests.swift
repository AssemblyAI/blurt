import Foundation
import Testing

@testable import BlurtEngine

/// The developer-mode gate on `appendError` — the same privacy guarantee the
/// transcript log's gate carries: a user who never opts in has nothing on disk.
/// Every case in the suites above drives `makeErrorEntry`/`writeError` directly,
/// so none of them cross this guard.
@Suite("DictationLog error-log developer-mode gate")
struct DictationErrorLogGateTests {
  @Test("with developer mode off, appendError writes nothing to disk")
  func gateClosedWritesNothing() {
    let url = makeTempErrorLogURL()
    // An unset key reads as off, which is the default a user who never opts in has.
    let store = DeveloperModeStore(defaults: freshDefaults())
    let context = TranscriptionContext(
      appName: "1Password",
      priorText: "hunter2",
      windowTitle: "Vault",
      fieldLabel: "Password",
      selectedText: nil
    )
    DictationLog.appendError(.targetAppLost, context: context, store: store, to: url)
    // A dispatched write would have landed by the time this drains the serial queue,
    // so a missing file means nothing was ever enqueued — not that we looked early.
    DictationLog.queue.sync {
      // Nothing to run: the empty sync just waits out the writes already queued.
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("with developer mode on, appendError writes the failure")
  func gateOpenWrites() {
    let url = makeTempErrorLogURL()
    let store = developerModeStore(enabled: true)
    DictationLog.appendError(.targetAppLost, store: store, to: url)
    DictationLog.queue.sync {
      // Nothing to run: the empty sync just waits out the writes already queued.
    }
    #expect(readLog(url).contains("targetAppLost"))
  }

  /// One switch, both logs — the Advanced pane shows a single toggle, so
  /// neither half may read a different default.
  @Test("both logs answer to the same switch")
  func sharesTheDeveloperModeSwitch() {
    let defaults = freshDefaults()
    let store = developerModeStore(enabled: true, defaults: defaults)
    let errorURL = makeTempErrorLogURL()
    let transcriptURL = makeTempErrorLogURL()
    DictationLog.appendError(.targetAppLost, store: store, to: errorURL)
    DictationLog.append(transcript: "logged", store: store, to: transcriptURL)
    DictationLog.queue.sync {
      // Nothing to run: the empty sync just waits out the writes already queued.
    }
    #expect(!readLog(errorURL).isEmpty)
    #expect(!readLog(transcriptURL).isEmpty)

    // Flip the slot the Settings toggle owns. The store reads through to `defaults`
    // on every access, so this same instance now gates both logs off.
    defaults.set(false, forKey: DeveloperModeStore.defaultsKey)
    let offErrorURL = makeTempErrorLogURL()
    let offTranscriptURL = makeTempErrorLogURL()
    DictationLog.appendError(.targetAppLost, store: store, to: offErrorURL)
    DictationLog.append(transcript: "private", store: store, to: offTranscriptURL)
    DictationLog.queue.sync {
      // Nothing to run: the empty sync just waits out the writes already queued.
    }
    #expect(!FileManager.default.fileExists(atPath: offErrorURL.path))
    #expect(!FileManager.default.fileExists(atPath: offTranscriptURL.path))
  }

  /// The two logs are separate files: an error row must never land in the
  /// prompt-iteration corpus, whose readers expect every line to carry a
  /// `transcript`.
  @Test("the error log is a sibling file, not the dictations log")
  func writesToASiblingFile() {
    #expect(DictationLog.defaultErrorURL != DictationLog.defaultURL)
    #expect(
      DictationLog.defaultErrorURL.deletingLastPathComponent()
        == DictationLog.defaultURL.deletingLastPathComponent())
    #expect(DictationLog.defaultErrorURL.lastPathComponent == "errors.jsonl")
  }
}
