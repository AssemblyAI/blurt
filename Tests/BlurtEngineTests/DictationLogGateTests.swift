import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The developer-mode gate on `append` — the switch's entire privacy guarantee:
/// "a user who never opts in has no dictation text on disk." Every case in the
/// suites above drives `makeEntry`/`write` directly, so none of them cross this
/// guard.
@Suite("DictationLog developer-mode gate")
struct DictationLogGateTests {
  @Test("with developer mode off, append writes nothing to disk")
  func gateClosedWritesNothing() throws {
    try withTempLogURL { url in
      // An unset key reads as off, which is the default a user who never opts in has.
      let store = DeveloperModeStore(defaults: freshDefaults())
      DictationLog.append(transcript: "private dictation", store: store, to: url)
      // A dispatched write would have landed by the time this drains the serial queue,
      // so a missing file means nothing was ever enqueued — not that we looked early.
      DictationLog.queue.sync {
        // Nothing to run: the empty sync just waits out the writes already queued.
      }
      #expect(!FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("with developer mode on, append writes the transcript")
  func gateOpenWrites() throws {
    try withTempLogURL { url in
      let store = developerModeStore(enabled: true)
      DictationLog.append(transcript: "logged dictation", store: store, to: url)
      DictationLog.queue.sync {
        // Nothing to run: the empty sync just waits out the writes already queued.
      }
      #expect(readLog(url).contains("logged dictation"))
    }
  }

  @Test("the gate is checked before the context is touched, for both settings")
  func gateAppliesToContextualEntries() throws {
    // The pipeline always passes the captured context, which is the part carrying
    // prior text and the assembled context turns. Off must persist none of it.
    let context = TranscriptionContext(
      appName: "1Password",
      priorText: "hunter2",
      windowTitle: "Vault",
      fieldLabel: "Password",
      selectedText: nil
    )
    try withTemporaryDirectory(named: "BlurtLogTests") { directory in
      let offURL = directory.appending(path: "off.jsonl")
      DictationLog.append(
        transcript: "p",
        context: context,
        store: DeveloperModeStore(defaults: freshDefaults()),
        to: offURL
      )

      let onStore = developerModeStore(enabled: true)
      let onURL = directory.appending(path: "on.jsonl")
      DictationLog.append(transcript: "p", context: context, store: onStore, to: onURL)

      DictationLog.queue.sync {
        // Nothing to run: the empty sync just waits out the writes already queued.
      }
      #expect(!FileManager.default.fileExists(atPath: offURL.path))
      #expect(readLog(onURL).contains("hunter2"))
    }
  }
}
