#if os(macOS)
  import Carbon.HIToolbox
  import Foundation

  /// The characters the user's keyboard layout types, by virtual key code
  /// (the approach of AXorcist's `Element+Keyboard.swift`, MIT). What every
  /// synthesized shortcut is resolved against — the paste's ⌘V, the read-aloud
  /// copy's ⌘C, a voice command's chord — because macOS matches a ⌘ shortcut by
  /// the character its key types, not by the key's US position: on Dvorak the
  /// US "V" key types "k", so a hardcoded `kVK_ANSI_V` is ⌘K there.
  enum KeyboardLayout {
    /// Each lowercase character the current ASCII-capable layout types, and the
    /// first key code that types it — the main row's digits before the
    /// keypad's. With `commandHeld` the layout is read as it types under ⌘,
    /// which differs for layouts like "Dvorak – QWERTY ⌘" (QWERTY while ⌘ is
    /// down). Empty when the layout can't be read. Main-actor: Text Input
    /// Sources must be asked from the main thread.
    @MainActor
    static func current(commandHeld: Bool = false) -> [Character: UInt16] {
      guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
      else { return [:] }
      // `UCKeyTranslate` takes the Carbon modifier mask shifted down a byte.
      let modifiers = commandHeld ? UInt32((cmdKey >> 8) & 0xFF) : 0
      let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
      return data.withUnsafeBytes { buffer in
        guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
        var map: [Character: UInt16] = [:]
        for code in UInt16(0)..<128 {
          guard let character = character(typedBy: code, modifiers: modifiers, on: layout), map[character] == nil
          else { continue }
          map[character] = code
        }
        return map
      }
    }

    /// The key that types `character` with ⌘ held on the user's layout, or
    /// `ansiFallback` (its US position) when the layout can't be read or has no
    /// key for it. Hops to the main actor for the layout read.
    static func commandKeyCode(for character: Character, ansiFallback: UInt16) async -> UInt16 {
      await MainActor.run { current(commandHeld: true)[character] } ?? ansiFallback
    }

    private static func character(
      typedBy code: UInt16, modifiers: UInt32, on layout: UnsafePointer<UCKeyboardLayout>
    ) -> Character? {
      var deadKeys: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
      guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]) else { return nil }
      return Character(String(scalar).lowercased())
    }
  }
#endif
