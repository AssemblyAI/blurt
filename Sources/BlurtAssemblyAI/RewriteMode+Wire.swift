import AssemblyAI
import BlurtEngine

extension RewriteMode {
  /// What goes on the wire as `rewrite_mode`, or nil to omit the key. Fast
  /// **omits** it rather than sending `.fast`, so a Fast request stays
  /// byte-identical to the one that shipped before this setting existed.
  var wireValue: DictationRewriteMode? {
    switch self {
    case .fast:
      return nil

    case .smart:
      return .smart
    }
  }
}
