import BlurtEngine
import Foundation
import UIKit

// MARK: - Typing and the app

extension KeyboardModel {
  package func type(_ text: String) {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      termDraft?.append(text)
      updateShift()
      return
    }
    proxy?.insertText(text)
    if shifted, !symbolsPage { shifted = false }
    typedIntoHost()
  }

  /// The keyboard's own edit to the host's text replaces whatever was
  /// highlighted: the picture follows at once, not on the host's next
  /// notification.
  private func typedIntoHost() {
    readSelection()
  }

  package func deleteBackward() {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      _ = termDraft?.popLast()
      updateShift()
      return
    }
    proxy?.deleteBackward()
    typedIntoHost()
  }

  package func newline() {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      saveTerm()
      return
    }
    proxy?.insertText("\n")
    typedIntoHost()
  }

  // MARK: Quick-add key term

  /// The most characters a highlighted word may have and still be offered as
  /// a key term: a name or a phrase, not a sentence.
  package static let termLengthCap = 48

  /// A selection as a key term: trimmed, on one line, short enough to be a
  /// name or a phrase. Nil when it is none of those, or nothing is selected.
  package static func termCandidate(from selected: String?) -> String? {
    guard let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
      trimmed.count <= termLengthCap, !trimmed.contains(where: \.isNewline)
    else { return nil }
    return trimmed
  }

  /// What is highlighted in the host's text, as a key-term candidate, and
  /// whether Blurt has it already. The list lives in the App Group, so only
  /// with Full Access — without it there is nothing the chip could do. A word
  /// the chip is done with (`dismissedSelection`) shows no chip while the
  /// same highlight stands.
  package func readSelection() {
    guard hasFullAccess, let term = Self.termCandidate(from: proxy?.selectedText) else {
      selectedTerm = nil
      selectedTermIsKnown = false
      dismissedSelection = nil
      return
    }
    if let dismissed = dismissedSelection {
      guard dismissed.caseInsensitiveCompare(term) != .orderedSame else {
        selectedTerm = nil
        selectedTermIsKnown = false
        return
      }
      dismissedSelection = nil
    }
    selectedTerm = term
    selectedTermIsKnown = SharedStore.keyTerms.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
  }

  /// The chip: the highlighted word goes into Blurt's key terms as it stands
  /// — one tap, no typing, the text untouched. The chip shows its check for
  /// the notice's moment and then gives way to the + (`dismissSelection`),
  /// highlight or not: the host may keep the word highlighted for as long as
  /// the user leaves it, and a chip that stayed with it read as stuck. A tap
  /// on a chip for a word Blurt already has puts the + back at once.
  package func addSelectedTerm() {
    guard let term = selectedTerm else { return }
    guard !selectedTermIsKnown else {
      dismissSelection()
      return
    }
    SharedStore.addKeyTerm(term)
    selectedTermIsKnown = true
    noteTermSaved(thenDismissChip: true)
  }

  /// The chip is done with the highlighted word: the + comes back and stays
  /// back while that highlight stands (`KeyboardModel.dismissedSelection`).
  package func dismissSelection() {
    dismissedSelection = selectedTerm
    selectedTerm = nil
    selectedTermIsKnown = false
  }

  /// The voice bar becomes a field and the keys type into it. If the user
  /// had selected a word — the one Blurt got wrong — it is the starting
  /// point, and saving also replaces it in the text with what they typed.
  /// The field takes the mic key's row, so a dictation in flight is closed
  /// first — nothing runs on with no key to stop it. From the plain + a
  /// recording is released and the words still land; from a highlighted
  /// word it is cancelled: the words would land *over* the word being fixed
  /// (a result replaces the selection), and the user's intent is the word.
  /// Words already being transcribed follow the same rule: from the plain +
  /// they still land (the mic is off; there is nothing to stop), from a
  /// highlighted word they are cancelled.
  package func beginAddingTerm() {
    let seed = Self.termCandidate(from: proxy?.selectedText) ?? ""
    switch snapshot.state {
    case .recording: perform(seed.isEmpty ? .stop : .cancel)
    case .connecting: perform(.cancel)
    case .processing:
      // The gate may still be latched from the tap that started it (an
      // auto-release has no finger event to close it): that is no reason to
      // cancel.
      if !seed.isEmpty { perform(.cancel) }
    case .idle, .pasted, .copied, .error:
      // A press the app hasn't answered yet would start a dictation under
      // the field: it is taken back.
      if unansweredPress != nil || !gate.isIdle { perform(.cancel) }
    }
    gate.reset()
    termDraftFromSelection = seed.isEmpty ? nil : seed
    termHostBaseline = proxy?.documentContextBeforeInput ?? ""
    termHostBaselineAfter = proxy?.documentContextAfterInput ?? ""
    termDraft = seed
    updateShift()
    onLayoutChange?()
  }

  package func cancelAddingTerm() {
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
  package func saveTerm() {
    guard let draft = termDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else {
      cancelAddingTerm()
      return
    }
    SharedStore.addKeyTerm(draft)
    // Out of the mode before touching the text, so the field's own change
    // notification can't read the replacement as typing to claim.
    let original = termDraftFromSelection
    let baseline = termHostBaseline
    termDraft = nil
    termDraftFromSelection = nil
    termHostBaseline = nil
    termHostBaselineAfter = nil
    // Only while the highlight the field opened over still stands where it
    // was: the host may report a selection a moment after the user moved on,
    // and inserting then would put the word in twice.
    if let original, original != draft, let selected = proxy?.selectedText,
      selected.trimmingCharacters(in: .whitespacesAndNewlines) == original,
      (proxy?.documentContextBeforeInput ?? "") == (baseline ?? "")
    {
      // The selection may have carried the spaces around the word; keep them.
      let lead = selected.prefix { $0.isWhitespace }
      let trail = selected.reversed().prefix { $0.isWhitespace }.reversed()
      proxy?.insertText(String(lead) + draft + String(trail))
    }
    // The word is saved; whatever is still highlighted, the + is back with
    // its check, not a chip for the word just dealt with.
    readSelection()
    dismissSelection()
    noteTermSaved(thenDismissChip: false)
    updateShift()
    onLayoutChange?()
  }

  /// A success haptic, and the + (or the chip) shows a check for a moment;
  /// after it, the chip gives way to the + when asked — only if it is still
  /// the chip for the word that was saved: a word highlighted meanwhile
  /// keeps its own chip.
  private func noteTermSaved(thenDismissChip: Bool) {
    if hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    termSavedAt = Date()
    termNotice?.cancel()
    let saved = selectedTerm
    termNotice = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.termNoticeDwell))
      guard !Task.isCancelled, let self else { return }
      termSavedAt = nil
      if thenDismissChip, let saved, let current = selectedTerm,
        current.caseInsensitiveCompare(saved) == .orderedSame
      {
        dismissSelection()
      }
    }
  }

  /// How long the + (or the chip) shows its check after a term was saved.
  package static let termNoticeDwell: TimeInterval = 1.2

  /// A space — or, tapped twice quickly after a word, the system keyboard's
  /// "." shortcut: the first space becomes a full stop and a space.
  package func space() {
    UIDevice.current.playInputClick()
    if termDraft != nil {
      if termDraft?.isEmpty == false, termDraft?.hasSuffix(" ") == false { termDraft?.append(" ") }
      updateShift()
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
    typedIntoHost()
    updateShift()
  }

  package func toggleShift() { shifted.toggle() }

  /// 123 / ABC: the symbols come up on their first page, or the letters return.
  package func toggleSymbols() {
    symbolsPage.toggle()
    morePage = false
  }

  /// #+= / 123: between the two symbol pages; nothing on the letters.
  package func toggleMore() {
    guard symbolsPage else { return }
    morePage.toggle()
  }

  package func globe() { controller?.advanceToNextInputMode() }

  /// Brings the app forward to open the microphone — the one thing a keyboard
  /// cannot do for itself. iOS gives extensions no `UIApplication.shared`, so
  /// this walks the responder chain to the application object and asks it, the
  /// way every keyboard that opens its app does. With `open(_:options:)`: since
  /// iOS 18 the old `openURL:` only logs "BUG IN CLIENT OF UIKIT" and opens
  /// nothing.
  package func openApp() {
    guard let controller,
      let url = URL(string: "\(BlurtShared.urlScheme)://\(BlurtShared.startHost)")
    else { return }
    var responder: UIResponder? = controller
    while let current = responder {
      if let application = current as? UIApplication {
        urlOpener(application, url)
        return
      }
      responder = current.next
    }
  }
}

/// The three letter rows, by the language the user types in most.
package nonisolated enum LetterLayout {
  package static let qwerty = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  package static let azerty = ["azertyuiop", "qsdfghjklm", "wxcvbn"]
  package static let qwertz = ["qwertzuiop", "asdfghjkl", "yxcvbnm"]

  /// From the phone's own language order — no setting to make.
  package static func forPreferredLanguages(_ languages: [String] = Locale.preferredLanguages) -> [String] {
    guard let first = languages.first?.lowercased() else { return qwerty }
    if first.hasPrefix("fr") { return azerty }
    if ["de", "cs", "sk", "hu"].contains(where: { first.hasPrefix($0) }) { return qwertz }
    return qwerty
  }
}
