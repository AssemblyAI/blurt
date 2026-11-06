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

  /// The setting a key with no voice of its own follows: its action's. A read
  /// key sounds like a read and a command key like a command, and any other
  /// key — dictate, ask, rewrite, each a recording — like a dictation.
  static func fallback(for action: TriggerKeyAction) -> SoundPackStore {
    switch action {
    case .readAloud: .readAloud
    case .command: .command
    case .off, .dictate, .ask, .rewrite: .dictation
    }
  }
}

extension TriggerKeySoundStore {
  /// A key's cue voice: the one stored for it, decoded against the catalog, or
  /// else its action's setting (`SoundPackStore.fallback(for:)`), so a key
  /// nobody has given a voice sounds as it did before keys had their own.
  static func soundPack(id: String?, action: TriggerKeyAction) -> SoundPack {
    guard let id else { return SoundPackStore.fallback(for: action).soundPack }
    return SoundPackCatalog.blurt.fromPersisted(id)
  }

  /// `key`'s cue voice, from the stored settings.
  func soundPack(for key: TriggerKey) -> SoundPack {
    Self.soundPack(id: soundID(for: key), action: TriggerKeyBindings().action(for: key))
  }
}
