import Foundation
import Testing

@testable import BlurtEngine

/// The `CHANGELOG.md` format the What's New sheet reads. The shell that loads the
/// file has no test target, so a parse that quietly drops an entry would only
/// show up as a sheet that never appears — hence the suite parses the real file
/// too.
@Suite("Changelog")
struct ChangelogTests {
  private static let sample = """
    <!--
    Format notes, with a heading that must not parse:
    ## 9.9.9 — 2030-01-01
    -->

    # Changelog

    ## 0.1.57 — 2026-09-29

    ### Text shortcuts

    <!-- symbol: text.bubble -->

    Say "work email" and Blurt types the whole address.
    Save the phrases you repeat in Settings.

    ### fn to dictate

    If fn is easier to reach, make it your trigger key.

    ### Fixes

    - Blurt now runs natively on Intel Macs, too.
    - Better spacing in Google Docs after you click
      or type between dictations.

    ## 0.1.56 — 2026-09-22

    ### Fixes

    - An older fix.
    """

  private func version(_ string: String) throws -> SemanticVersion {
    try #require(SemanticVersion(string))
  }

  @Test("parses features, symbols and fixes, newest first")
  func parsesEntries() throws {
    let entries = Changelog(markdown: Self.sample).entries
    let versions = entries.map(\.version.description)
    #expect(versions == ["0.1.57", "0.1.56"])

    let latest = try #require(entries.first)
    let titles = latest.features.map(\.title)
    let symbols = latest.features.map(\.symbolName)
    #expect(titles == ["Text shortcuts", "fn to dictate"])
    #expect(symbols == ["text.bubble", Changelog.defaultSymbolName])
    // A paragraph's lines join into one summary.
    #expect(
      latest.features.first?.summary
        == "Say \"work email\" and Blurt types the whole address. Save the phrases you repeat in Settings.")
    // A wrapped bullet continues the one above it rather than starting another.
    #expect(
      latest.fixes == [
        "Blurt now runs natively on Intel Macs, too.",
        "Better spacing in Google Docs after you click or type between dictations.",
      ])
    let oldest = try #require(entries.last)
    #expect(oldest.features.isEmpty)
    #expect(oldest.fixes == ["An older fix."])
  }

  @Test("entries are ordered by version, not by where the file lists them")
  func sortsByVersion() {
    let markdown = """
      ## 0.1.9
      - ignored: no section yet
      ### Fixes
      - nine
      ## 0.1.10
      ### Fixes
      - ten
      """
    let entries = Changelog(markdown: markdown).entries
    let versions = entries.map(\.version.description)
    #expect(versions == ["0.1.10", "0.1.9"])
    #expect(entries.last?.fixes == ["nine"])
  }

  @Test("more than the feature limit keeps only the first ones")
  func capsFeatures() {
    let features = (1...5).map { "### Feature \($0)\nSummary \($0)." }.joined(separator: "\n")
    let entries = Changelog(markdown: "## 1.0.0\n" + features).entries
    let titles = entries.first?.features.map(\.title)
    #expect(titles == ["Feature 1", "Feature 2", "Feature 3"])
    #expect(Changelog.featureLimit == 3)
  }

  @Test("a heading that doesn't parse, or an entry with nothing in it, is skipped")
  func skipsMalformedEntries() {
    let markdown = """
      ## Unreleased
      ### Fixes
      - not shipped yet
      ## 1.0.0 — 2026-01-01
      ## 0.9.0
      ### Fixes
      - kept
      """
    // "Unreleased" isn't a version, and 1.0.0 has no features or fixes: neither
    // may open a sheet.
    let versions = Changelog(markdown: markdown).entries.map(\.version.description)
    #expect(versions == ["0.9.0"])
    #expect(Changelog(markdown: "").entries.isEmpty)
  }

  @Test("the heading's date formats as a long date on that day, whatever the time zone")
  func formatsDate() throws {
    let entry = try #require(Changelog(markdown: Self.sample).entries.first)
    let locale = Locale(identifier: "en_US")
    var calendar = Calendar(identifier: .gregorian)
    // A zone well west of UTC: formatting in it would give September 28.
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    #expect(entry.formattedDate(locale: locale, calendar: calendar) == "September 29, 2026")

    // No date, and a date that doesn't exist: both read as undated.
    let undated = Changelog(markdown: "## 1.0.0\n### Fixes\n- one\n## 0.9.0 — 2026-02-30\n### Fixes\n- two")
    #expect(undated.entries.count == 2)
    for undatedEntry in undated.entries {
      #expect(undatedEntry.dateLabel == nil)
    }
  }

  @Test("the title names the version the way the update alerts do")
  func titlesTheVersion() {
    let entry = Changelog(markdown: Self.sample).entries.first
    #expect(entry?.title == "What’s new in \(HostIdentity.current.productName) 0.1.57")
  }

  @Test("the Help menu's entry is this version's, or the newest before it")
  func entryForVersion() throws {
    let changelog = Changelog(markdown: Self.sample)
    let exact = try changelog.entry(for: version("0.1.57"))
    let newer = try changelog.entry(for: version("0.1.58"))
    let older = try changelog.entry(for: version("0.1.56"))
    let tooOld = try changelog.entry(for: version("0.1.55"))
    #expect(exact?.version.description == "0.1.57")
    #expect(newer?.version.description == "0.1.57")
    #expect(older?.version.description == "0.1.56")
    #expect(tooOld == nil)
  }

  @Test("the repo's CHANGELOG.md parses, every entry dated and within the feature limit")
  func realChangelogParses() throws {
    // The file the app bundles (see project.yml): Tests/BlurtEngineTests/ → repo root.
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("CHANGELOG.md")
    let markdown = try String(contentsOf: url, encoding: .utf8)
    let entries = Changelog(markdown: markdown).entries
    #expect(!entries.isEmpty)
    // One heading per release, so each version appears once.
    let versions = entries.map(\.version.description)
    #expect(Set(versions).count == versions.count)
    for entry in entries {
      #expect(entry.date != nil, "\(entry.version) has no date")
      for feature in entry.features {
        #expect(!feature.summary.isEmpty, "\(entry.version): \(feature.title) has no summary")
      }
    }
    // The cap drops extras silently, so check the file itself: no release may
    // list more headline features than the sheet will show.
    for release in markdown.components(separatedBy: "\n## ").dropFirst() {
      let sections = release.components(separatedBy: "\n### ").dropFirst()
      let featureCount = sections.filter { !$0.hasPrefix("Fixes") }.count
      #expect(featureCount <= Changelog.featureLimit, "too many features under ## \(release.prefix(20))")
    }
  }
}
