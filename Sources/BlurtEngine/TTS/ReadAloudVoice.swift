/// A voice read-aloud can speak with: its id in a TTS request and the name the
/// Settings picker shows.
///
/// Which voices there are is the provider's to say
/// (`SpeechSynthesizing.voices`; `BlurtAssemblyAI`'s `ReadAloudVoice.assemblyAI`
/// lists AssemblyAI's), so the engine holds the shape and no catalog.
public struct ReadAloudVoice: Sendable, Equatable, Identifiable {
  public enum Group: String, Sendable, CaseIterable {
    case builtIn = "Built-in"
    case library = "Voice Library"
  }

  /// The id the provider's TTS request names the voice by.
  public let id: String
  public let name: String
  /// The accent the provider lists for the voice ("British"), or nil.
  public let accent: String?
  public let group: Group

  /// The picker's label: "Buford (British)", or just the name.
  public var label: String {
    accent.map { "\(name) (\($0))" } ?? name
  }

  /// A voice named `name`, which the provider's requests call `id`.
  public init(id: String, name: String, accent: String? = nil, group: Group) {
    self.id = id
    self.name = name
    self.accent = accent
    self.group = group
  }
}
