/// The "speak all punctuation" pass (`SpokenPunctuationStore`): strips every
/// mark the service put in a transcript, then turns the punctuation the user
/// *said* back into symbols — "hello comma how are you question mark" →
/// "hello, how are you?". Pure and local, like `TextShortcutExpander`, and run
/// before it so a shortcut's saved text is pasted with its own punctuation.
///
/// - **What is stripped**: sentence and phrase punctuation — `. , ? ! : ;`,
///   quotes, brackets, dashes, ellipses, `¿ ¡`. Symbols someone may well have
///   dictated as words (`% $ @ & # /`) stay. A `.` `,` `:`, apostrophe or hyphen
///   *between* two letters or digits is part of a word and stays too: "don't",
///   "well-known", "3.5", "1,000", "10:30", "cal.com".
/// - **What is recognized**: the phrases in `vocabulary`, case-insensitively and
///   as whole words. Deliberately literal — in this mode "period" is always a
///   `.`, the trade every spoken-punctuation mode makes. Bare "quote" and "dot"
///   are left out as too common as ordinary words.
/// - **Spacing** follows the mark: closing marks hug the word before, opening
///   ones the word after, hyphens and dashes both, and a line break takes the
///   spaces on either side.
/// - **Case**: a word after a spoken sentence end or line break is capitalized.
///   A word the service capitalized only because *its* period came first —
///   "Hello comma. How are you" — is lowercased again, unless it doesn't look
///   like a sentence-start capital ("I", "I'm", "NASA", "iPhone"). A name right
///   after a stripped period loses its capital too; that is the price of not
///   pasting "Hello, How are you?".
enum SpokenPunctuationFormatter {
  /// How a mark sits against the words either side of it.
  enum Spacing {
    /// Hugs the word before it: `.` `,` `)`.
    case closing
    /// Hugs the word after it: `(` and an opening quote.
    case opening
    /// Hugs both: a hyphen, a dash, an apostrophe.
    case joining
    /// A line break: no space on either side.
    case lineBreak
  }

  struct Mark {
    let symbol: String
    let spacing: Spacing
    /// Whether the word after it starts a sentence, and so is capitalized.
    let endsSentence: Bool
  }

  /// One recognized phrase: its words, spelled as `matchKey` reads them, and
  /// the mark it stands for.
  struct Entry {
    let words: [String]
    let mark: Mark
  }

  /// A word left once the service's punctuation is stripped.
  struct Word {
    let text: String
    /// Whether a sentence end the *service* inserted came right before it —
    /// the case where its capital letter may be an artifact of that period.
    let followsStrippedSentenceEnd: Bool
  }

  enum Piece {
    case word(Word)
    case mark(Mark)
  }

  /// Every spoken phrase the formatter recognizes, longest first so "question
  /// mark" claims its words before any shorter phrase could.
  static let vocabulary: [Entry] = {
    func entries(
      _ phrases: [String], _ symbol: String, _ spacing: Spacing, endsSentence: Bool = false
    ) -> [Entry] {
      let mark = Mark(symbol: symbol, spacing: spacing, endsSentence: endsSentence)
      return phrases.map { Entry(words: $0.split(separator: " ").map(String.init), mark: mark) }
    }
    let groups = [
      entries(["period", "full stop"], ".", .closing, endsSentence: true),
      entries(["comma"], ",", .closing),
      entries(["question mark"], "?", .closing, endsSentence: true),
      entries(["exclamation point", "exclamation mark"], "!", .closing, endsSentence: true),
      entries(["colon"], ":", .closing),
      entries(["semicolon", "semi colon"], ";", .closing),
      entries(["ellipsis", "dot dot dot"], "…", .closing),
      entries(["hyphen"], "-", .joining),
      entries(["dash", "em dash"], "—", .joining),
      entries(["apostrophe"], "'", .joining),
      entries(["open paren", "open parenthesis", "left paren", "left parenthesis"], "(", .opening),
      entries(["close paren", "close parenthesis", "right paren", "right parenthesis"], ")", .closing),
      entries(["open bracket", "left bracket"], "[", .opening),
      entries(["close bracket", "right bracket"], "]", .closing),
      entries(["open quote", "begin quote", "start quote"], "\"", .opening),
      entries(["close quote", "end quote", "unquote"], "\"", .closing),
      entries(["new line", "newline"], "\n", .lineBreak, endsSentence: true),
      entries(["new paragraph"], "\n\n", .lineBreak, endsSentence: true),
    ]
    return groups.flatMap { $0 }.sorted { $0.words.count > $1.words.count }
  }()

  /// Stripped wherever they sit — inside a token too, where they split it:
  /// "yes—no" is two words.
  private static let alwaysStripped: Set<Character> = [
    "?", "!", ";", "\"", "“", "”", "„", "‘", "«", "»", "‹", "›", "(", ")", "[", "]", "{", "}",
    "…", "—", "–", "¿", "¡",
  ]

  /// Stripped from either end of a word, but kept between two of its letters
  /// or digits: "don't", "well-known", "3.5", "1,000", "10:30".
  private static let wordJoiners: Set<Character> = [".", ",", ":", "'", "’", "-", "‐"]

  /// The stripped marks that end a sentence, for `Word.followsStrippedSentenceEnd`.
  private static let sentenceEnds: Set<Character> = [".", "?", "!", "…"]

  static func format(_ text: String) -> String {
    render(pieces(from: strippedWords(in: text)))
  }

  /// A token as `vocabulary` spells it: lowercased letters only, so "Comma,",
  /// "semi-colon" and "new-line" all read as vocabulary words.
  static func matchKey(_ word: String) -> String {
    word.lowercased().filter(\.isLetter)
  }

  /// `text`'s words with the service's punctuation gone.
  static func strippedWords(in text: String) -> [Word] {
    var words: [Word] = []
    var afterSentenceEnd = false
    func add(_ piece: String) {
      let trailing = piece.reversed().prefix(while: wordJoiners.contains)
      let core = piece.drop(while: wordJoiners.contains).dropLast(trailing.count)
      if !core.isEmpty {
        words.append(Word(text: String(core), followsStrippedSentenceEnd: afterSentenceEnd))
        afterSentenceEnd = false
      }
      if trailing.contains(".") { afterSentenceEnd = true }
    }
    for token in text.split(whereSeparator: \.isWhitespace) {
      var piece = ""
      for character in token {
        guard alwaysStripped.contains(character) else {
          piece.append(character)
          continue
        }
        add(piece)
        piece = ""
        if sentenceEnds.contains(character) { afterSentenceEnd = true }
      }
      add(piece)
    }
    return words
  }

  /// `words` with each spoken phrase in `vocabulary` replaced by its mark.
  static func pieces(from words: [Word]) -> [Piece] {
    let keys = words.map { matchKey($0.text) }
    var pieces: [Piece] = []
    var index = 0
    while index < words.count {
      if let entry = vocabulary.first(where: { keys[index...].starts(with: $0.words) }) {
        pieces.append(.mark(entry.mark))
        index += entry.words.count
      } else {
        pieces.append(.word(words[index]))
        index += 1
      }
    }
    return pieces
  }

  static func render(_ pieces: [Piece]) -> String {
    var output = ""
    var previous: Piece?
    var capitalizeNext = false
    for piece in pieces {
      if let previous, spaceAfter(previous), spaceBefore(piece) { output += " " }
      switch piece {
      case .word(let word):
        output += cased(word, capitalize: capitalizeNext)
        capitalizeNext = false
      case .mark(let mark):
        output += mark.symbol
        capitalizeNext = capitalizeNext || mark.endsSentence
      }
      previous = piece
    }
    return output
  }

  private static func spaceAfter(_ piece: Piece) -> Bool {
    guard case .mark(let mark) = piece else { return true }
    return mark.spacing == .closing
  }

  private static func spaceBefore(_ piece: Piece) -> Bool {
    guard case .mark(let mark) = piece else { return true }
    return mark.spacing == .opening
  }

  private static func cased(_ word: Word, capitalize: Bool) -> String {
    let text = word.text
    if capitalize { return text.prefix(1).uppercased() + text.dropFirst() }
    guard word.followsStrippedSentenceEnd, isSentenceCapitalized(text) else { return text }
    return text.prefix(1).lowercased() + text.dropFirst()
  }

  /// "Hello", but not "I", "I'm", "NASA" or "iPhone" — the shape a capital
  /// from sentence position takes, as opposed to one the word always carries.
  private static func isSentenceCapitalized(_ text: String) -> Bool {
    guard let first = text.first, first.isUppercase else { return false }
    let rest = text.dropFirst()
    if rest.contains(where: \.isUppercase) { return false }
    let isPronounI = first == "I" && (rest.isEmpty || rest.first == "'" || rest.first == "’")
    return !isPronounI
  }
}
