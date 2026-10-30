/// A voice read-aloud can speak with: its `voice_id` in a TTS request and the
/// name the Settings picker shows.
///
/// `catalog` is the English voices from the TTS docs' Voices page
/// (https://www.assemblyai.com/docs/tts/voices). English only, because a read
/// sends no `language`: without one a catalog voice speaks the language it was
/// recorded in, so a Spanish voice would read an English selection as Spanish.
/// The built-in voices are always loaded on the server; any other voice loads
/// when a session first opens with it, so its first read after a quiet spell
/// starts a little later.
public struct ReadAloudVoice: Sendable, Equatable, Identifiable {
  public enum Group: String, Sendable, CaseIterable {
    case builtIn = "Built-in"
    case library = "Voice Library"
  }

  /// The `voice_id` query parameter: an AssemblyAI library slug.
  public let id: String
  public let name: String
  /// The accent the docs list for a library voice ("British"), or nil.
  public let accent: String?
  public let group: Group

  /// The picker's label: "Buford (British)", or just the name.
  public var label: String {
    accent.map { "\(name) (\($0))" } ?? name
  }

  /// The service's own default, `aai-jane`, so an untouched install sounds as
  /// a session with no `voice_id` would.
  public static let defaultID = "aai-jane"

  public static let catalog: [ReadAloudVoice] =
    [
      "Jane", "Alba", "Anna", "Charles", "Eve", "George", "Jean", "Mary", "Michael", "Paul", "Vera",
    ].map { builtIn($0) }
    + [
      ("Aaliyah", "American"), ("Abdiel", nil), ("Annabelle", "American"), ("April", "American"),
      ("Audrey", "American"), ("Buford", "British"), ("Carrie", "British"), ("Cloyd", "British"),
      ("Dorsey", nil), ("Ernest", "American"), ("Ewald", "American"), ("Gunnar", nil),
      ("Hailey", "American"), ("Kyla", "American"), ("Lilla", "British"), ("Nancy", "British"),
      ("Percival", "British"), ("Peter", "American"), ("Sara", "American"), ("Steven", "Australian"),
      ("Titus", "American"), ("Troy", "Scottish"), ("Yasmin", "British"),
    ].map { library($0.0, accent: $0.1) }

  /// The catalog entry for `id`, or nil for an id that isn't one.
  public static func voice(id: String) -> ReadAloudVoice? {
    catalog.first { $0.id == id }
  }

  private static func builtIn(_ name: String) -> ReadAloudVoice {
    ReadAloudVoice(id: slug(name), name: name, accent: nil, group: .builtIn)
  }

  private static func library(_ name: String, accent: String?) -> ReadAloudVoice {
    ReadAloudVoice(id: slug(name), name: name, accent: accent, group: .library)
  }

  /// The docs' slugs are `aai-` and the lowercased name, for every voice listed.
  private static func slug(_ name: String) -> String { "aai-" + name.lowercased() }
}
