#if os(macOS)
  import AppKit
  import Carbon.HIToolbox
  import CoreGraphics

  // A shortcut step's keys: the chord resolved on the user's own keyboard
  // layout, then posted as the paste's ⌘V is.
  extension SystemVoiceCommandPerformer {
    /// The virtual key code that presses `chord` on the user's layout. A
    /// character key is looked up on the current ASCII-capable layout (what
    /// macOS itself reads shortcuts against: a Russian keyboard's ⌘K is ABC's),
    /// falling back to its US position; a named key is the same everywhere.
    @MainActor
    static func keyCode(for chord: KeyChord) -> UInt16 {
      guard case .character(let character) = chord.key else { return chord.ansiKeyCode }
      return KeyboardLayout.current()[character] ?? chord.ansiKeyCode
    }

    /// The chord's key-down/key-up pair on `keyCode`, or nil when CoreGraphics
    /// refuses to build them. Split from `post` for the reason
    /// `KeyInjector.cmdVEvents` is: building an event is testable, posting
    /// one types into the machine.
    static func events(for chord: KeyChord, keyCode: UInt16) -> (down: CGEvent, up: CGEvent)? {
      guard let source = CGEventSource(stateID: .combinedSessionState),
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
      else { return nil }
      // On both, as `KeyInjector`'s ⌘V sets them: a key-up without its
      // modifiers reads as the chord released part-way.
      let flags = flags(for: chord.modifiers)
      down.flags = flags
      up.flags = flags
      return (down, up)
    }

    static func flags(for modifiers: KeyChord.Modifiers) -> CGEventFlags {
      var flags: CGEventFlags = []
      if modifiers.contains(.command) { flags.insert(.maskCommand) }
      if modifiers.contains(.shift) { flags.insert(.maskShift) }
      if modifiers.contains(.option) { flags.insert(.maskAlternate) }
      if modifiers.contains(.control) { flags.insert(.maskControl) }
      return flags
    }

    /// Posted to the annotated session tap, as the paste's ⌘V is: it honours
    /// exactly these flags rather than OR-ing in a trigger modifier still held,
    /// and it sits after the trigger's own tap, so `DictationKeyTap` never
    /// reads the shortcut as a combo.
    static func post(_ events: (down: CGEvent, up: CGEvent)?) -> Bool {
      guard let (down, up) = events else { return false }
      down.post(tap: .cgAnnotatedSessionEventTap)
      up.post(tap: .cgAnnotatedSessionEventTap)
      return true
    }
  }

  /// The characters the user's keyboard layout types, by virtual key code
  /// (the approach of AXorcist's `Element+Keyboard.swift`, MIT).
  enum KeyboardLayout {
    /// Each lowercase character the current ASCII-capable layout types with no
    /// modifier, and the first key code that types it — the main row's digits
    /// before the keypad's. Empty when the layout can't be read. Main-actor:
    /// Text Input Sources must be asked from the main thread.
    @MainActor
    static func current() -> [Character: UInt16] {
      guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
      else { return [:] }
      let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
      return data.withUnsafeBytes { buffer in
        guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
        var map: [Character: UInt16] = [:]
        for code in UInt16(0)..<128 {
          guard let character = character(typedBy: code, on: layout), map[character] == nil else { continue }
          map[character] = code
        }
        return map
      }
    }

    private static func character(typedBy code: UInt16, on layout: UnsafePointer<UCKeyboardLayout>) -> Character? {
      var deadKeys: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
      guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]) else { return nil }
      return Character(String(scalar).lowercased())
    }
  }
#endif
