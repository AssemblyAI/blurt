import Foundation
import Testing
import UIKit

@testable import BlurtiOS

/// A host text field the model can type into, remembering what it did.
final class FakeProxy: NSObject, UITextDocumentProxy {
  var before = ""
  var after = ""
  var selected: String?
  var autocapitalizationType: UITextAutocapitalizationType = .sentences
  var keyboardType: UIKeyboardType = .default
  var returnKeyType: UIReturnKeyType = .default

  var documentContextBeforeInput: String? { before }
  var documentContextAfterInput: String? { after }
  var selectedText: String? { selected }
  var documentInputMode: UITextInputMode? { nil }
  var documentIdentifier: UUID { UUID() }
  var hasText: Bool { !before.isEmpty || !after.isEmpty }

  func insertText(_ text: String) {
    if let selected, !selected.isEmpty {
      self.selected = nil
    }
    before += text
  }

  func deleteBackward() { _ = before.popLast() }
  func adjustTextPosition(byCharacterOffset offset: Int) {}
  func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
  func unmarkText() {}
}

@Suite("Keyboard model: typing rules")
struct KeyboardModelTypingTests {
  private func model(before: String = "", selected: String? = nil) -> (KeyboardModel, FakeProxy) {
    let proxy = FakeProxy()
    proxy.before = before
    proxy.selected = selected
    let model = KeyboardModel()
    model.proxyOverride = proxy
    return (model, proxy)
  }

  @Test("sentence start: empty, after a full stop and a space, after a newline")
  func sentenceStart() {
    #expect(KeyboardModel.isSentenceStart(""))
    #expect(KeyboardModel.isSentenceStart("Hello. "))
    #expect(KeyboardModel.isSentenceStart("Hello?"))
    #expect(KeyboardModel.isSentenceStart("Line\n"))
    #expect(!KeyboardModel.isSentenceStart("Hello "))
    #expect(!KeyboardModel.isSentenceStart("Hello, "))
  }

  @Test("a letter goes to the field and lowers shift")
  func typing() {
    let (model, proxy) = model()
    model.shifted = true
    model.type("H")
    #expect(proxy.before == "H")
    #expect(!model.shifted)
  }

  @Test("two quick spaces after a word become a full stop and a space")
  func doubleSpace() {
    let (model, proxy) = model(before: "hello")
    model.space()
    #expect(proxy.before == "hello ")
    model.space()
    #expect(proxy.before == "hello. ")
  }

  @Test("two quick spaces after punctuation stay spaces")
  func doubleSpaceAfterPunctuation() {
    let (model, proxy) = model(before: "hello.")
    model.space()
    model.space()
    #expect(proxy.before == "hello.  ")
  }

  @Test("the term field takes the keys instead of the host, and return saves nothing empty")
  func termField() {
    let (model, proxy) = model(before: "yo ")
    model.beginAddingTerm()
    #expect(model.termDraft == "")
    #expect(model.effectiveLayout == .full)
    model.type("R")
    model.type("i")
    model.space()
    model.type("z")
    model.deleteBackward()
    #expect(model.termDraft == "Ri ")
    #expect(proxy.before == "yo ")
    model.cancelAddingTerm()
    #expect(model.termDraft == nil)
  }

  @Test("a selection seeds the term and is replaced on save")
  func termFromSelection() {
    let (model, proxy) = model(before: "he said ", selected: "riz")
    model.beginAddingTerm()
    #expect(model.termDraft == "riz")
    model.type("z")
    model.saveTerm()
    #expect(model.termDraft == nil)
    #expect(proxy.before == "he said rizz")
  }

  @Test("typing that reached the host field while the term is open moves into the term")
  func hardwareTypingClaimed() {
    let (model, proxy) = model(before: "yo ")
    model.beginAddingTerm()
    proxy.before = "yo Ri"
    model.contextChanged()
    #expect(model.termDraft == "Ri")
    #expect(proxy.before == "yo ")
  }

  @Test("the return key wears the field's word")
  func returnLabel() {
    let (model, proxy) = model()
    proxy.returnKeyType = .send
    model.contextChanged()
    #expect(model.returnLabel == "send")
    proxy.returnKeyType = .default
    model.contextChanged()
    #expect(model.returnLabel == nil)
  }
}
