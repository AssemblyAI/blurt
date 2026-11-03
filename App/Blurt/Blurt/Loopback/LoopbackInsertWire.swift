import Foundation

/// The wire format's two decisions, as pure functions: whether a presented
/// token matches, and what a line's escapes mean.
enum LoopbackInsertWire {
  /// Compares in constant time over the token's bytes, so a client can't walk
  /// the secret out one byte at a time. The *length* still leaks, which is
  /// fine: every token Blurt mints is the same length.
  static func matches(token: String, presented: String) -> Bool {
    let expected = Array(token.utf8)
    let actual = Array(presented.utf8)
    guard !expected.isEmpty, expected.count == actual.count else { return false }
    var difference: UInt8 = 0
    for (lhs, rhs) in zip(expected, actual) { difference |= lhs ^ rhs }
    return difference == 0
  }

  /// `\n` becomes a newline and `\\` a backslash; every other backslash pair is
  /// left as the two characters it already was, and a trailing lone backslash
  /// stays one. Deliberately not a general escape language — a transcript is
  /// prose, and the only thing the frame takes away from it is the newline.
  static func unescape(_ line: String) -> String {
    guard line.contains("\\") else { return line }
    var unescaped = ""
    var isEscaping = false
    for character in line {
      guard isEscaping else {
        if character == "\\" { isEscaping = true } else { unescaped.append(character) }
        continue
      }
      switch character {
      case "n": unescaped.append("\n")
      case "\\": unescaped.append("\\")
      default:
        unescaped.append("\\")
        unescaped.append(character)
      }
      isEscaping = false
    }
    if isEscaping { unescaped.append("\\") }
    return unescaped
  }
}
