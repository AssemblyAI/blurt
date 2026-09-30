import BlurtEngine
import Foundation
import UIKit

// MARK: - Typing and the app

extension KeyboardModel {
  func type(_ text: String) {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      termDraft?.append(text)
      updateShift()
      return
    }
    proxy?.insertText(text)
    if shifted, !symbolsPage { shifted = false }
  }

  func deleteBackward() {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      _ = termDraft?.popLast()
      updateShift()
      return
    }
    proxy?.deleteBackward()
  }

  func newline() {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      saveTerm()
      return
    }
    proxy?.insertText("\n")
  }

  // MARK: Quick-add key term

  /// The most characters a highlighted word may have and still be offered as
  /// a key term: a name or a phrase, not a sentence.
  static let termLengthCap = 48

  /// A selection as a key term: trimmed, on one line, short enough to be a
  /// name or a phrase. Nil when it is none of those, or nothing is selected.
  static func termCandidate(from selected: String?) -> String? {
    guard let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
      trimmed.count <= termLengthCap, !trimmed.contains(where: \.isNewline)
    else { return nil }
    return trimmed
  }

  /// The chip: the highlighted word goes into Blurt's key terms as it stands
  /// — one tap, no typing, the text untouched. Nothing to do for a word Blurt
  /// already has.
  func addSelectedTerm() {
    guard let term = selectedTerm, !selectedTermIsKnown else { return }
    SharedStore.addKeyTerm(term)
    selectedTermIsKnown = true
    noteTermSaved()
  }

  /// The voice bar becomes a field and the keys type into it. If the user
  /// had selected a word — the one Blurt got wrong — it is the starting
  /// point, and saving also replaces it in the text with what they typed.
  func beginAddingTerm() {
    let seed = Self.termCandidate(from: proxy?.selectedText) ?? ""
    termDraftFromSelection = seed.isEmpty ? nil : seed
    termHostBaseline = proxy?.documentContextBeforeInput ?? ""
    termHostBaselineAfter = proxy?.documentContextAfterInput ?? ""
    termDraft = seed
    updateShift()
    onLayoutChange?()
  }

  func cancelAddingTerm() {
    termDraft = nil
    termDraftFromSelection = nil
    termHostBaseline = nil
    termHostBaselineAfter = nil
    // The highlight may still stand: the chip comes back as it is now.
    readSelection()
    updateShift()
    onLayoutChange?()
  }

  /// Saves the term to Blurt's key terms — read on the very next dictation —
  /// and, when it began as a selection, puts it into the text in place of the
  /// misheard word.
  func saveTerm() {
    guard let draft = termDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else {
      cancelAddingTerm()
      return
    }
    SharedStore.addKeyTerm(draft)
    // Out of the mode before touching the text, so the field's own change
    // notification can't read the replacement as typing to claim.
    let original = termDraftFromSelection
    termDraft = nil
    termDraftFromSelection = nil
    termHostBaseline = nil
    termHostBaselineAfter = nil
    if let original, original != draft, let selected = proxy?.selectedText,
      selected.trimmingCharacters(in: .whitespacesAndNewlines) == original
    {
      // The selection may have carried the spaces around the word; keep them.
      let lead = selected.prefix { $0.isWhitespace }
      let trail = selected.reversed().prefix { $0.isWhitespace }.reversed()
      proxy?.insertText(String(lead) + draft + String(trail))
    }
    // Saved as selected, the word is still highlighted: the chip knows it now.
    readSelection()
    noteTermSaved()
    updateShift()
    onLayoutChange?()
  }

  /// A success haptic, and the + (or the chip) shows a check for a moment.
  private func noteTermSaved() {
    if hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    termSavedAt = Date()
    termNotice?.cancel()
    termNotice = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      self?.termSavedAt = nil
    }
  }

  /// A space — or, tapped twice quickly after a word, the system keyboard's
  /// "." shortcut: the first space becomes a full stop and a space.
  func space() {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      if termDraft?.isEmpty == false, termDraft?.hasSuffix(" ") == false { termDraft?.append(" ") }
      return
    }
    let now = ContinuousClock.now
    let before = proxy?.documentContextBeforeInput ?? ""
    if let last = lastSpaceAt, now - last < .milliseconds(450), before.hasSuffix(" "), !before.hasSuffix("  "),
      let previous = before.dropLast().last, previous.isLetter || previous.isNumber
    {
      proxy?.deleteBackward()
      proxy?.insertText(". ")
      lastSpaceAt = nil
    } else {
      proxy?.insertText(" ")
      lastSpaceAt = now
    }
    updateShift()
  }

  func toggleShift() { shifted.toggle() }

  func toggleSymbols() { symbolsPage.toggle() }

  func globe() { controller?.advanceToNextInputMode() }

  /// Brings the app forward to open the microphone — the one thing a keyboard
  /// cannot do for itself. iOS gives extensions no `open(_:)`, so this walks the
  /// responder chain to the application object and asks it, the way every
  /// keyboard that opens its app does.
  func openApp() {
    guard let controller,
      let url = URL(string: "\(BlurtShared.urlScheme)://\(BlurtShared.startHost)")
    else { return }
    let selector = sel_registerName("openURL:")
    var responder: UIResponder? = controller
    while let current = responder {
      if current.responds(to: selector) {
        _ = current.perform(selector, with: url)
        return
      }
      responder = current.next
    }
  }
}

/// The three letter rows, by the language the user types in most.
nonisolated enum LetterLayout {
  static let qwerty = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  static let azerty = ["azertyuiop", "qsdfghjklm", "wxcvbn"]
  static let qwertz = ["qwertzuiop", "asdfghjkl", "yxcvbnm"]

  /// From the phone's own language order — no setting to make.
  static func forPreferredLanguages(_ languages: [String] = Locale.preferredLanguages) -> [String] {
    guard let first = languages.first?.lowercased() else { return qwerty }
    if first.hasPrefix("fr") { return azerty }
    if ["de", "cs", "sk", "hu"].contains(where: { first.hasPrefix($0) }) { return qwertz }
    return qwerty
  }
}
