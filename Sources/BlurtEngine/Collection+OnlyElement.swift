extension Collection {
  /// The one element, when there is exactly one: nil for none, and for several
  /// (where taking any of them would be a guess).
  var onlyElement: Element? { count == 1 ? first : nil }
}
