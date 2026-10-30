import BlurtEngine

extension SoundPackCatalog {
  /// Read-aloud's cue voices: the same as dictation's, defaulting to the
  /// Juno-106's Brass, so a read sounds unlike a recording starting. Apart from
  /// the generated catalog file, which is the generator's to write.
  static let blurtReadAloud = SoundPackCatalog.blurt.defaulting(to: "juno-0")
}

extension SoundPackStore {
  /// Each cue's store, tied to its catalog here once, so a read-aloud setting
  /// can't be read under dictation's default or the other way round.
  static var dictation: SoundPackStore { SoundPackStore(catalog: .blurt) }
  static var readAloud: SoundPackStore { SoundPackStore(catalog: .blurtReadAloud, cue: .readAloud) }
}
