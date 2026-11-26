import Foundation

/// The on-disk form of a per-key setting — one JSON object, keycode → string —
/// shared by `TriggerKeyStyleStore` (actions and styles) and
/// `TriggerKeySoundStore` (cue voices), so the encoding and its one
/// safety rule are written once.
enum TriggerKeyMap {
  /// The map behind a raw slot value. Blank or undecodable reads as empty, and
  /// an entry for a keycode outside `TriggerKey` is dropped, so a hand-edited
  /// value can't bind a new key.
  static func decode(_ raw: String) -> [TriggerKey: String] {
    guard let decoded = JSONText.decode([String: String].self, from: raw) else {
      return [:]
    }
    var map: [TriggerKey: String] = [:]
    for (code, value) in decoded {
      if let key = Int(code).flatMap(TriggerKey.init(rawValue:)) { map[key] = value }
    }
    return map
  }

  /// Writes `map` to `slot` in `defaults`. A string map always encodes.
  static func write(_ map: [TriggerKey: String], to slot: String, in defaults: UserDefaults) {
    let raw = Dictionary(uniqueKeysWithValues: map.map { (String($0.key.rawValue), $0.value) })
    JSONText.write(raw, to: defaults, forKey: slot)
  }
}
