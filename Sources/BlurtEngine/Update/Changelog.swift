import Foundation

/// One release's notes, as written in the repo's `CHANGELOG.md`: a few headline
/// features and a list of fixes. What the What's New sheet renders.
public struct ChangelogEntry: Equatable, Sendable {
  /// One headline feature: an SF Symbol, a bold title, and one sentence or two.
  public struct Feature: Equatable, Sendable {
    public let title: String
    public let summary: String
    /// From the feature's `<!-- symbol: … -->` line, or `Changelog.defaultSymbolName`.
    public let symbolName: String
  }

  let version: SemanticVersion
  /// Midnight UTC of the heading's `YYYY-MM-DD`, or nil when the heading has none.
  let date: Date?
  public let features: [Feature]
  public let fixes: [String]

  /// "What’s new in Blurt 0.1.57" — named through `UpdateAlertContent.appVersionLabel`
  /// so the sheet and the update alerts can't word the version two ways.
  public var title: String { "What’s new in \(UpdateAlertContent.appVersionLabel(version))" }

  /// "September 29, 2026" in the user's locale, or nil when the heading has no date.
  public var dateLabel: String? { formattedDate(locale: .autoupdatingCurrent, calendar: .autoupdatingCurrent) }

  /// Formatted in UTC, the zone the date was parsed in: the user's own zone would
  /// show the day before anywhere west of Greenwich.
  func formattedDate(locale: Locale, calendar: Calendar) -> String? {
    date?.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: .gmt))
  }
}

/// The release notes parsed from `CHANGELOG.md`, the single hand-written source of
/// truth (bundled into the app at build time; see `project.yml`). Engine-side for
/// the reason `UpdateAlertContent` is: the format is a rule, and the shell that
/// reads the file has no test target.
///
/// The format, also documented at the top of the file itself:
///
/// ```markdown
/// ## 0.1.57 — 2026-09-29
/// ### Text shortcuts
/// <!-- symbol: text.bubble -->
/// One paragraph saying what it does for the user.
/// ### Fixes
/// - One line per fix.
/// ```
///
/// Anything else — the file's `#` title, other HTML comments, a heading whose
/// version doesn't parse — is skipped rather than rejected: a malformed entry
/// costs its own notes, never the sheet. `ChangelogTests` parses the real file,
/// so a slip there fails the build instead.
public struct Changelog: Sendable {
  /// At most this many headline features per release; extras are dropped. The
  /// sheet is laid out for a short list, and the cap keeps the notes to the
  /// changes worth interrupting someone for — the rest belong under Fixes.
  static let featureLimit = 3

  /// The glyph a feature gets when its section names none.
  static let defaultSymbolName = "sparkles"

  /// Every entry, newest version first, whatever order the file lists them in.
  let entries: [ChangelogEntry]

  public init(markdown: String) {
    var parser = Parser()
    for line in markdown.components(separatedBy: .newlines) {
      parser.consume(line.trimmingCharacters(in: .whitespaces))
    }
    entries = parser.finish().sorted { $0.version > $1.version }
  }

  /// The notes for `version`, or for the newest release before it when that
  /// version has no entry of its own — what Help → What's New in Blurt shows.
  public func entry(for version: SemanticVersion) -> ChangelogEntry? {
    entries.first { $0.version <= version }
  }
}

extension Changelog {
  /// A line-at-a-time reader for the format on `Changelog`.
  private struct Parser {
    private enum Section {
      case none
      case feature
      case fixes
    }

    private struct FeatureDraft {
      let title: String
      var lines: [String] = []
      var symbol: String?
    }

    private struct EntryDraft {
      let version: SemanticVersion
      let date: Date?
      var features: [FeatureDraft] = []
      var fixes: [String] = []
    }

    private var finished: [ChangelogEntry] = []
    private var draft: EntryDraft?
    private var section = Section.none
    private var inComment = false

    mutating func consume(_ line: String) {
      if consumeComment(line) { return }
      if line.hasPrefix("## ") {
        startEntry(heading: String(line.dropFirst(3)))
      } else if line.hasPrefix("### ") {
        startSection(title: line.dropFirst(4).trimmingCharacters(in: .whitespaces))
      } else if line.hasPrefix("#") {
        section = .none
      } else if !line.isEmpty {
        addText(line)
      }
    }

    mutating func finish() -> [ChangelogEntry] {
      closeEntry()
      return finished
    }

    /// Skips HTML comments, single- or multi-line (the format notes at the top of
    /// the file are one), picking up a feature's `<!-- symbol: … -->` on the way.
    /// True when the line was part of a comment.
    private mutating func consumeComment(_ line: String) -> Bool {
      if inComment {
        if line.contains("-->") { inComment = false }
        return true
      }
      guard line.hasPrefix("<!--") else { return false }
      if let symbol = Self.symbolName(in: line) {
        if section == .feature, let last = draft?.features.indices.last {
          draft?.features[last].symbol = symbol
        }
      } else if !line.contains("-->") {
        inComment = true
      }
      return true
    }

    /// `0.1.57 — 2026-09-29`: the version, then an optional date after a dash.
    private mutating func startEntry(heading: String) {
      closeEntry()
      section = .none
      let parts = heading.split(separator: " ", maxSplits: 1)
      guard let token = parts.first, let version = SemanticVersion(String(token)) else { return }
      let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "—–- ")) : ""
      draft = EntryDraft(version: version, date: Self.date(from: rest))
    }

    private mutating func startSection(title: String) {
      guard draft != nil else { return }
      if title.caseInsensitiveCompare("Fixes") == .orderedSame {
        section = .fixes
      } else {
        draft?.features.append(FeatureDraft(title: title))
        section = .feature
      }
    }

    private mutating func addText(_ line: String) {
      switch section {
      case .none:
        return
      case .feature:
        guard let last = draft?.features.indices.last else { return }
        draft?.features[last].lines.append(line)
      case .fixes:
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
          draft?.fixes.append(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        } else if let last = draft?.fixes.indices.last {
          // A bullet wrapped onto a second line continues the one above it.
          draft?.fixes[last] += " " + line
        }
      }
    }

    private mutating func closeEntry() {
      guard let draft else { return }
      self.draft = nil
      let features = draft.features.prefix(Changelog.featureLimit).map {
        ChangelogEntry.Feature(
          title: $0.title, summary: $0.lines.joined(separator: " "),
          symbolName: $0.symbol ?? Changelog.defaultSymbolName)
      }
      // An entry with nothing to say would open an empty sheet.
      guard !features.isEmpty || !draft.fixes.isEmpty else { return }
      finished.append(
        ChangelogEntry(version: draft.version, date: draft.date, features: features, fixes: draft.fixes))
    }

    /// `<!-- symbol: text.bubble -->` → `text.bubble`.
    private static func symbolName(in line: String) -> String? {
      guard line.hasSuffix("-->") else { return nil }
      let body = line.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
      guard body.hasPrefix("symbol:") else { return nil }
      return body.dropFirst("symbol:".count).trimmingCharacters(in: .whitespaces).trimmedNonEmpty()
    }

    /// `2026-09-29` → midnight UTC that day; nil for anything else.
    private static func date(from text: String) -> Date? {
      let fields = text.split(separator: "-")
      let parts = fields.compactMap { Int($0) }
      guard fields.count == 3, parts.count == 3 else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .gmt
      let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
      guard components.isValidDate(in: calendar) else { return nil }
      return calendar.date(from: components)
    }
  }
}
