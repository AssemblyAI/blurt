#if os(macOS)  // swiftlint:disable:this file_name
  import AppKit
  import CoreGraphics

  // A shortcut step's keys: the chord resolved on the user's own keyboard
  // layout, then posted as the paste's ⌘V is.
  //
  // Named apart from `SystemVoiceCommandPerformer*` on purpose (hence the
  // `file_name` exemption on the first line): check.sh's coverage gate
  // excludes that prefix as the untestable system shell, and these key
  // chords are policy that the tests do cover.
  extension SystemVoiceCommandPerformer {
    /// The virtual key code that presses `chord` on the user's layout. A
    /// character key is looked up on the current ASCII-capable layout (what
    /// macOS itself reads shortcuts against: a Russian keyboard's ⌘K is ABC's),
    /// with ⌘ held when the chord holds it (so a "Dvorak – QWERTY ⌘" layout is
    /// read the way it types under ⌘), falling back to its US position; a named
    /// key is the same everywhere.
    @MainActor
    static func keyCode(for chord: KeyChord) -> UInt16 {
      guard case .character(let character) = chord.key else {
        return chord.ansiKeyCode
      }
      return KeyboardLayout.current(commandHeld: chord.modifiers.contains(.command))[character]
        ?? chord.ansiKeyCode
    }

    /// The chord's key-down/key-up pair on `keyCode`: `KeyInjector`'s, which
    /// the paste's ⌘V is built by too, with every modifier on both events.
    static func events(for chord: KeyChord, keyCode: UInt16) -> (down: CGEvent, up: CGEvent)? {
      KeyInjector.keyEvents(virtualKey: keyCode, flags: flags(for: chord.modifiers))
    }

    static func flags(for modifiers: KeyChord.Modifiers) -> CGEventFlags {
      var flags: CGEventFlags = []
      if modifiers.contains(.command) { flags.insert(.maskCommand) }
      if modifiers.contains(.shift) { flags.insert(.maskShift) }
      if modifiers.contains(.option) { flags.insert(.maskAlternate) }
      if modifiers.contains(.control) { flags.insert(.maskControl) }
      return flags
    }
  }
#endif
