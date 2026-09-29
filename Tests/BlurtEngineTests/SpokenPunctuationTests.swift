import Foundation
import Testing

@testable import BlurtEngine

@Suite("SpokenPunctuationFormatter")
struct SpokenPunctuationFormatterTests {
  private func format(_ text: String) -> String { SpokenPunctuationFormatter.format(text) }

  @Test("strips the service's punctuation and puts back only what was said")
  func replacesPunctuation() {
    #expect(format("Hello comma, how are you question mark?") == "Hello, how are you?")
    #expect(format("Hello, how are you?") == "Hello how are you")
  }

  /// The service capitalizes after the periods *it* inserts, which the strip
  /// removes — so "How" is lowercased again, while a spoken period capitalizes.
  @Test("recases around stripped and spoken sentence ends")
  func recases() {
    #expect(format("Hello comma. How are you.") == "Hello, how are you")
    #expect(format("done period thanks") == "done. Thanks")
    #expect(format("Fine. I agree. NASA called. iPhone ships.") == "Fine I agree NASA called iPhone ships")
  }

  @Test("marks sit against their neighbours by kind")
  func spacing() {
    #expect(format("he said open quote hello close quote period") == "he said \"hello\".")
    #expect(format("call me open paren maybe close paren") == "call me (maybe)")
    #expect(format("a well hyphen known fact") == "a well-known fact")
    #expect(format("wait dash what") == "wait—what")
    #expect(format("list colon eggs semicolon milk") == "list: eggs; milk")
    #expect(format("really exclamation point") == "really!")
  }

  @Test("line breaks take the spaces around them and start a sentence")
  func lineBreaks() {
    #expect(format("Dear Sam comma new paragraph thanks for writing") == "Dear Sam,\n\nThanks for writing")
    #expect(format("one new line two") == "one\nTwo")
  }

  @Test("phrases match case-insensitively through the service's own punctuation")
  func loosePhrases() {
    #expect(format("Wow, Exclamation. Point!") == "Wow!")
    #expect(format("eggs Semi-colon milk") == "eggs; milk")
    #expect(format("one New-line two") == "one\nTwo")
  }

  @Test("punctuation inside a word stays")
  func keepsWordInternalMarks() {
    #expect(format("Don't, it's well-known: 3.5% of 1,000 at 10:30.") == "Don't it's well-known 3.5% of 1,000 at 10:30")
    #expect(format("See cal.com, \"now\".") == "See cal.com now")
  }

  @Test("dashes, quotes and brackets are stripped, even inside a token")
  func stripsEverywhere() {
    #expect(format("yes—no (maybe) “sure” - fine…") == "yes no maybe sure fine")
  }

  @Test("only whole words are punctuation words")
  func wholeWords() {
    #expect(format("commas and periods") == "commas and periods")
  }

  @Test("nothing but punctuation formats to nothing; a lone spoken mark is itself")
  func edges() {
    #expect(format("") == "")
    #expect(format("...") == "")
    #expect(format("Period.") == ".")
  }
}

@Suite("SpokenPunctuationStore")
struct SpokenPunctuationStoreTests {
  @Test("defaults to off when unset")
  func defaultsToOff() {
    #expect(!SpokenPunctuationStore(defaults: freshDefaults()).isEnabled)
  }

  @Test("reads back the switch the Settings toggle writes")
  func readsBackTheToggledSlot() {
    let defaults = freshDefaults()
    let store = SpokenPunctuationStore(defaults: defaults)
    defaults.set(true, forKey: SpokenPunctuationStore.defaultsKey)
    #expect(store.isEnabled)
    defaults.set(false, forKey: SpokenPunctuationStore.defaultsKey)
    #expect(!store.isEnabled)
  }
}

@Suite("DictationSession spoken punctuation", .timeLimit(.minutes(1)))
struct DictationSessionSpokenPunctuationTests {
  @Test("with the mode on, the paste is formatted; the log and history keep the service's text")
  func formatsBeforePaste() async {
    let spy = StringListBox()
    let fixture = makeSession(
      mode: .transcript("Hello comma, world period."), spokenPunctuation: true,
      onTranscriptDelivered: { text, _ in spy.append(text) })

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.injector.inserted == ["Hello, world."])
    #expect(spy.values == ["Hello, world."])
    #expect(fixture.log.transcripts.map(\.text) == ["Hello comma, world period."])
    #expect(await fixture.session.recentDictations.spokenOldestFirst == ["Hello comma, world period."])
  }

  @Test("with the mode off, the transcript is pasted untouched")
  func offLeavesTextAlone() async {
    let fixture = makeSession(mode: .transcript("Hello comma, world."))

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.injector.inserted == ["Hello comma, world."])
  }

  /// Formatting first means a shortcut's saved text keeps its own punctuation,
  /// which the strip would otherwise remove.
  @Test("shortcuts expand after formatting, keeping their own punctuation")
  func shortcutsAfterFormatting() async {
    let fixture = makeSession(
      mode: .transcript("Sign off, comma. Signature."),
      textShortcuts: [TextShortcut(trigger: "signature", expansion: "Thanks, Sam.")],
      spokenPunctuation: true)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.injector.inserted == ["Sign off, Thanks, Sam."])
  }

  @Test("a transcript that is only the service's punctuation pastes nothing")
  func punctuationOnlyIdles() async {
    let fixture = makeSession(mode: .transcript("..."), spokenPunctuation: true)

    await fixture.session.press()
    await fixture.session.release()
    await fixture.session.waitForIdle()

    #expect(await fixture.injector.inserted.isEmpty)
  }
}
