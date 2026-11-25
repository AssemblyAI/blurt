/// A short, stable fingerprint of a text — the planner's instruction and
/// schema — for the log: 64-bit FNV-1a, in hex. Not security, just "which
/// prompt was this".
enum PromptVersion {
  static func of(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}
