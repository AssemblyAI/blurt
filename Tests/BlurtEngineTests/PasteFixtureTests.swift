#if os(macOS)
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// Paste situations recorded from real apps (`PasteFixtureRecorder`):
  /// what was focused when a dictation would land there, and whether it
  /// should be pasted or left on the clipboard — replayed every run through
  /// the decision `KeyInjector` makes (`PasteTarget.pastes`).
  @Suite("Paste fixtures")
  struct PasteFixtureTests {
    @Test("every recorded situation pastes, or copies, as it should")
    func replay() throws {
      let fixtures = try PasteFixture.loadAll()
      for fixture in fixtures {
        #expect(
          PasteTarget.pastes(fixture.facts) == fixture.pastes,
          "\(fixture.name): \(fixture.pastes ? "should paste" : "should copy"), facts \(fixture.facts)")
      }
    }

    @Test("a recorded password field — 1Password's, a secure subrole on a plain text field — is read as one")
    func secureFieldsRedact() throws {
      let fixtures = try PasteFixture.loadAll()
      let secure = fixtures.filter { FocusCapture.mustRedactContents(role: $0.facts.role, subrole: $0.facts.subrole) }
      // Its contents are never read and what's dictated into it never kept,
      // yet it still takes the paste, as any password field does.
      #expect(secure.map(\.name) == ["1password-unlock"])
      #expect(secure.allSatisfy { $0.pastes })
    }

    @Test("both outcomes are covered: places to paste, and places with nowhere to paste")
    func bothOutcomes() throws {
      let fixtures = try PasteFixture.loadAll()
      #expect(fixtures.contains { $0.pastes })
      #expect(fixtures.contains { !$0.pastes })
    }

    @Test("the fixtures are exactly the recorder's scenarios: none unrecorded, none left over")
    func everyScenarioRecorded() throws {
      let names = try PasteFixture.loadAll().map(\.name)
      #expect(names.count == Set(names).count)
      #expect(Set(names) == Set(PasteFixtureRecorder.scenarios.map(\.name)))
    }

    @Test("a fixture holds no text: only Accessibility role names and bundle ids, under the fields it's written with")
    func noText() throws {
      let raw = try String(contentsOf: PasteFixture.url, encoding: .utf8)
      let found = try TestFixtures.audit(
        raw, shapes: TestFixtures.personalShapes + TestFixtures.webShapes, allowedKeys: PasteFixture.keys)
      #expect(found.isEmpty, "\(found)")
      for fixture in try PasteFixture.loadAll() {
        for name in [fixture.facts.role, fixture.facts.subrole].compactMap({ $0 }) {
          #expect(name.range(of: #"^AX[A-Za-z]+$"#, options: .regularExpression) != nil, "\(fixture.name): \(name)")
        }
        if let bundle = fixture.facts.bundleID {
          #expect(bundle.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil, "\(fixture.name)")
        }
      }
    }
  }

  /// One recorded paste situation.
  struct PasteFixture: Codable, Equatable {
    let name: String
    /// The app opened for it, as `open_app` names it.
    let app: String
    /// Whether a dictation there should be pasted (else left on the clipboard).
    let pastes: Bool
    let facts: PasteFacts

    static let url = TestFixtures.url("Tests/PasteFixtures/pastes.json")

    /// Every key a fixture is written with, read off one with every field set.
    static var keys: Set<String> {
      let full = PasteFixture(
        name: "", app: "", pastes: true,
        facts: PasteFacts(focused: true, role: "", subrole: "", bundleID: ""))
      let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(full))) as? [String: Any] ?? [:]
      return Set(object.keys).union((object["facts"] as? [String: Any] ?? [:]).keys)
    }

    static func loadAll() throws -> [PasteFixture] {
      try JSONDecoder().decode([PasteFixture].self, from: Data(contentsOf: url))
    }

    static func save(_ fixtures: [PasteFixture]) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(fixtures).write(to: url)
    }
  }
#endif
