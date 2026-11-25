public import BlurtEngine

/// AssemblyAI's read-aloud voices: what `AssemblyAISpeechSynthesizer` offers
/// the engine (`SpeechSynthesizing.voices`) and the Settings picker lists.
///
/// The English voices from the TTS docs' Voices page
/// (https://www.assemblyai.com/docs/tts/voices). English only, because a read
/// sends no `language`: without one a voice speaks the language it was recorded
/// in, so a Spanish voice would read an English selection as Spanish. The
/// built-in voices are always loaded on the server; any other voice loads when a
/// session first opens with it, so its first read after a quiet spell starts a
/// little later.
extension ReadAloudVoice {
  /// The service's own default, `aai-jane`, so an untouched install sounds as a
  /// session with no `voice_id` would. First in `assemblyAI`.
  public static let assemblyAIDefaultID = "aai-jane"

  /// Every voice, built-ins first, the default leading.
  public static let assemblyAI: [Self] =
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

  /// The voice `id` names, or the default for nil or an id the list doesn't
  /// hold. The setting is a plain string anyone can `defaults write`, and an id
  /// the service doesn't know refuses the whole read (`3012`), so it is never
  /// passed through. The picker's binding resolves through this too, so a stale
  /// value shows as the voice that will actually speak.
  public static func assemblyAIVoice(id: String?) -> Self {
    assemblyAI.first { $0.id == id } ?? assemblyAI[0]
  }

  private static func builtIn(_ name: String) -> Self {
    Self(id: slug(name), name: name, group: .builtIn)
  }

  private static func library(_ name: String, accent: String?) -> Self {
    Self(id: slug(name), name: name, accent: accent, group: .library)
  }

  /// The docs' slugs are `aai-` and the lowercased name, for every voice listed.
  private static func slug(_ name: String) -> String { "aai-" + name.lowercased() }
}
