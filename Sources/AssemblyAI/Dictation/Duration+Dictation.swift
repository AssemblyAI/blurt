extension Duration {
  /// The duration in milliseconds, for the dictation client's latency lines.
  var dictationMilliseconds: Double {
    self / Self.milliseconds(1)
  }
}
