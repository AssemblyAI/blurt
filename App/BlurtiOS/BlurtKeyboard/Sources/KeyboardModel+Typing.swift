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

  /// The voice bar becomes a field and the keys type into it. If the user
  /// had selected a word — the one Blurt got wrong — it is the starting
  /// point, and saving also replaces it in the text with what they typed.
  func beginAddingTerm() {
    let selected = proxy?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let seed = selected.count <= 48 && !selected.contains("\n") ? selected : ""
    termDraftFromSelection = seed.isEmpty ? nil : seed
    termDraft = seed
    updateShift()
    onLayoutChange?()
  }

  func cancelAddingTerm() {
    termDraft = nil
    termDraftFromSelection = nil
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
    if let original = termDraftFromSelection, original != draft, proxy?.selectedText == original {
      proxy?.insertText(draft)
    }
    termDraft = nil
    termDraftFromSelection = nil
    if hasFullAccess { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    termSavedAt = Date()
    termNotice?.cancel()
    termNotice = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      self?.termSavedAt = nil
    }
    updateShift()
    onLayoutChange?()
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
