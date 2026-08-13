extension Duration {
  /// This duration in milliseconds as a Double (for latency logging). Expressed
  /// as a ratio of two `Duration`s rather than reassembled from `components`,
  /// which meant restating the attoseconds-per-millisecond constant by hand.
  var milliseconds: Double {
    self / Duration.milliseconds(1)
  }
}
