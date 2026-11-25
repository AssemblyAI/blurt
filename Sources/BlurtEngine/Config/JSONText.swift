import Foundation

/// A value as JSON text, for a store that keeps it in `UserDefaults` as a string.
enum JSONText {
  /// `value` encoded and read back as UTF-8, or nil. A list of strings can't
  /// realistically fail either step — `JSONEncoder` emits UTF-8 by definition —
  /// but both are spelled failably anyway: a store's setter dropping the write
  /// beats trapping in a settings sheet, and the non-failable
  /// `String(decoding:as:)` would quietly substitute U+FFFD for a malformed byte
  /// instead of saying so.
  static func encode(_ value: some Encodable) -> String? {
    guard let data = try? JSONEncoder().encode(value) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  /// Writes `value` to `defaults` under `key` as JSON text; false, writing
  /// nothing, when it can't be encoded (`encode`).
  @discardableResult
  static func write(_ value: some Encodable, to defaults: UserDefaults, forKey key: String) -> Bool {
    guard let json = encode(value) else {
      return false
    }
    defaults.set(json, forKey: key)
    return true
  }
}
