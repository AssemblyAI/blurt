import BlurtEngine

extension SoundPackCatalog {
  /// Read-aloud's cue voices: the same as dictation's, defaulting to the
  /// Juno-106's Brass, so a read sounds unlike a recording starting. Apart from
  /// the generated catalog file, which is the generator's to write.
  static let blurtReadAloud = SoundPackCatalog.blurt.defaulting(to: "juno-0")
  /// Control Your Mac's: the same voices, defaulting to the DX7's Piano 1, so
  /// a command sounds unlike a dictation or a read.
  static let blurtCommand = SoundPackCatalog.blurt.defaulting(to: "rom1a-7")
}

extension SoundPackStore {
  /// Each cue's store, tied to its catalog here once, so a read-aloud setting
  /// can't be read under dictation's default or the other way round.
  static var dictation: SoundPackStore { SoundPackStore(catalog: .blurt) }
  static var readAloud: SoundPackStore { SoundPackStore(catalog: .blurtReadAloud, cue: .readAloud) }
  static var command: SoundPackStore { SoundPackStore(catalog: .blurtCommand, cue: .command) }
}
