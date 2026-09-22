import Foundation
import Testing

@testable import BlurtEngine

@Suite("TextShortcutExpander")
struct TextShortcutExpanderTests {
  private let email = TextShortcut(trigger: "personal email", expansion: "me@example.com")
  private let linktree = TextShortcut(
    trigger: "personal link tree", expansion: "https://linktr.ee/someone")
  private let cal = TextShortcut(trigger: "personal cal.com", expansion: "https://cal.com/someone")

  @Test("replaces a trigger mid-sentence, ignoring case")
  func midSentence() {
    let out = TextShortcutExpander.expand(
      "You can reach me at Personal Email anytime.", using: [email])
    #expect(out == "You can reach me at me@example.com anytime.")
  }

  @Test("a dictation that is only the trigger pastes the bare expansion")
  func loneTrigger() {
    #expect(TextShortcutExpander.expand("Personal email.", using: [email]) == "me@example.com")
    #expect(TextShortcutExpander.expand(" personal email ", using: [email]) == " me@example.com ")
  }

  @Test("separators between words are loose: spaces, dots, hyphens, or none")
  func looseSeparators() {
    #expect(
      TextShortcutExpander.expand("my personal Linktree is here", using: [linktree])
        == "my https://linktr.ee/someone is here")
    #expect(
      TextShortcutExpander.expand("book at personal Cal.com.", using: [cal])
        == "book at https://cal.com/someone.")
    #expect(
      TextShortcutExpander.expand("send it to personal-email", using: [email])
        == "send it to me@example.com")
  }

  @Test("never matches inside a longer word")
  func wholeWords() {
    let text = "That was impersonal emails, honestly."
    #expect(TextShortcutExpander.expand(text, using: [email]) == text)
  }

  @Test("replaces every occurrence, and the longest trigger wins")
  func longestFirst() {
    let work = TextShortcut(trigger: "personal email work", expansion: "me@work.example")
    let out = TextShortcutExpander.expand(
      "personal email work or personal email", using: [email, work])
    #expect(out == "me@work.example or me@example.com")
  }

  @Test("an expansion is inserted literally and never re-expanded")
  func literalExpansion() {
    let tricky = TextShortcut(trigger: "price tag", expansion: "$1 \\0 personal email")
    #expect(
      TextShortcutExpander.expand("the price tag", using: [tricky, email])
        == "the $1 \\0 personal email")
  }

  @Test("no shortcuts, or a punctuation-only trigger, leaves the text alone")
  func noOp() {
    #expect(TextShortcutExpander.expand("hello", using: []) == "hello")
    let junk = TextShortcut(trigger: "...", expansion: "x")
    #expect(TextShortcutExpander.expand("wait...", using: [junk]) == "wait...")
  }
}

@Suite("TextShortcutStore")
struct TextShortcutStoreTests {
  @Test("an untouched install has no shortcuts")
  func unsetIsEmpty() {
    #expect(TextShortcutStore(defaults: freshDefaults()).shortcuts.isEmpty)
  }

  @Test("shortcuts round-trip through defaults, in order")
  func roundTrip() {
    let store = TextShortcutStore(defaults: freshDefaults())
    let written = [
      TextShortcut(trigger: "personal email", expansion: "me@example.com"),
      TextShortcut(trigger: "personal github", expansion: "https://github.com/me"),
    ]
    store.shortcuts = written
    #expect(store.shortcuts == written)
  }

  @Test("normalization trims, drops blanks, and dedupes triggers case-insensitively")
  func normalization() {
    let store = TextShortcutStore(defaults: freshDefaults())
    store.shortcuts = [
      TextShortcut(trigger: "  personal email ", expansion: " me@example.com\n"),
      TextShortcut(trigger: "Personal Email", expansion: "other@example.com"),
      TextShortcut(trigger: "   ", expansion: "orphan"),
      TextShortcut(trigger: "empty", expansion: "  "),
    ]
    #expect(store.shortcuts.map(\.trigger) == ["personal email"])
    #expect(store.shortcuts.map(\.expansion) == ["me@example.com"])
  }

  @Test("an undecodable slot reads as no shortcuts")
  func corrupt() {
    let defaults = freshDefaults()
    defaults.set("not json", forKey: TextShortcutStore.defaultsKey)
    #expect(TextShortcutStore(defaults: defaults).shortcuts.isEmpty)
  }
}

@Suite("DictationSession text shortcuts", .timeLimit(.minutes(1)))
struct DictationSessionTextShortcutTests {
  @Test("the pasted text and the delivered transcript are expanded; the log is not")
  func expandsBeforePaste() async {
    let spy = StringListBox()
    let fixture = makeSession(
      mode: .transcript("Mail personal email."),
      textShortcuts: [TextShortcut(trigger: "personal email", expansion: "me@example.com")],
      onTranscriptDelivered: { text, _ in spy.append(text) })

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.injector.inserted == ["Mail me@example.com."])
    #expect(spy.values == ["Mail me@example.com."])
    #expect(fixture.log.transcripts.map(\.text) == ["Mail personal email."])
  }
}
