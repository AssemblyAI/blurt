import Foundation
import UIKit

// MARK: - The phone's word list, handed to the app

extension KeyboardModel {
  nonisolated private struct LexiconHandoff: @unchecked Sendable {
    let lexicon: UILexicon

    init(_ lexicon: UILexicon) { self.lexicon = lexicon }
  }

  /// Hands the word list to the app: written to the App Group, stamped, and
  /// signalled, so the next dictation spells the names right.
  func handOver(_ entries: [LexiconEntry]) {
    store.write(entries, forKey: BlurtShared.Key.lexicon)
    store.lexiconRefreshedAt = Date()
    store.post(BlurtShared.Signal.lexicon)
  }

  /// The phone's own word list — contact names and text replacements — for
  /// the app to spell names right with no setup. Read here because only the
  /// keyboard is offered it; the app reads it back out of the App Group.
  func requestLexicon() {
    let refreshed = store.lexiconRefreshedAt ?? .distantPast
    guard Date().timeIntervalSince(refreshed) > Self.lexiconRefreshInterval else {
      return
    }
    // UIKit calls back on an XPC queue, not the main thread (a main-actor
    // closure here traps), while the lexicon's entries are main-actor in
    // Swift's eyes. So: take the callback anywhere, hand the immutable lexicon
    // over, and read it on the main actor.
    controller?.requestSupplementaryLexicon { @Sendable [weak self] lexicon in
      let handoff = LexiconHandoff(lexicon)
      Task { @MainActor in
        let entries = handoff.lexicon.entries.map { entry in
          LexiconEntry(userInput: entry.userInput, documentText: entry.documentText)
        }
        self?.handOver(entries)
      }
    }
  }
}
