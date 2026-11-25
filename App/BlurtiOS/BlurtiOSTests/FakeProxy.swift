import Foundation
import UIKit

@testable import BlurtiOSCore

/// A host text field the model can type into, remembering what it did.
final class FakeProxy: NSObject, UITextDocumentProxy {
  var before = ""
  var after = ""
  var selected: String?
  var autocapitalizationType: UITextAutocapitalizationType = .sentences
  var keyboardType: UIKeyboardType = .default
  var returnKeyType: UIReturnKeyType = .default
  var isSecureTextEntry = false
  var textContentType: UITextContentType?

  var documentContextBeforeInput: String? { before }
  var documentContextAfterInput: String? { after }
  var selectedText: String? { selected }
  var documentInputMode: UITextInputMode? { nil }
  var documentIdentifier = UUID()
  var hasText: Bool { !before.isEmpty || !after.isEmpty }

  func insertText(_ text: String) {
    if let selected, !selected.isEmpty {
      self.selected = nil
    }
    before += text
  }

  func deleteBackward() { _ = before.popLast() }
  func adjustTextPosition(byCharacterOffset _: Int) {
    // Nothing to move: the fake field has no caret apart from the end of `before`.
  }

  func setMarkedText(_: String, selectedRange _: NSRange) {
    // Nothing to mark: the keyboard under test never marks text.
  }

  func unmarkText() {
    // Nothing to unmark: no text is ever marked.
  }
}

/// A bare keyboard over a fake field holding `before` up to the caret, with
/// `selected` highlighted: what the typing and chip rules read. Internal so the
/// typing and chip suites share it.
func typingModel(before: String = "", selected: String? = nil) -> (KeyboardModel, FakeProxy) {
  let proxy = FakeProxy()
  proxy.before = before
  proxy.selected = selected
  let model = KeyboardModel()
  model.proxyOverride = proxy
  return (model, proxy)
}
