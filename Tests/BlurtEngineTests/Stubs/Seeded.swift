/// xorshift64*: small, fast, and the same sequence for the same seed — for
/// generated inputs (the reply-parser fuzz, the screen eval's cases) that
/// replay exactly when one fails.
struct Seeded: RandomNumberGenerator {
  var state: UInt64

  /// Seeded from a name, the same on every run (`hashValue` isn't): FNV-1a.
  init(name: String) {
    state = name.utf8.reduce(1_469_598_103_934_665_603) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
  }

  init(state: UInt64) {
    self.state = state
  }

  mutating func next() -> UInt64 {
    state ^= state >> 12
    state ^= state << 25
    state ^= state >> 27
    return state &* 2_685_821_657_736_338_717
  }
}
