#if os(macOS)
  /// A best-effort snapshot of the whole pasteboard, taken before a paste so the
  /// user's contents can be put back afterwards.
  ///
  /// The distinction that matters: this type is only ever produced when the
  /// pasteboard was *readable*. `SystemClipboard.snapshot()` returns `nil` when the
  /// read itself failed, so a failure can never be mistaken for "the clipboard was
  /// empty" — conflating those two is what made the restore clear the user's
  /// clipboard instead of restoring it.
  ///
  /// Known, inherent limitation: pasteboard data can be *promised* (provided lazily
  /// by the owning app on demand). A promise cannot be copied, only materialized, and
  /// an app may decline. Types that decline are absent from `dataMap`, so a restore
  /// of promise-backed contents is a best-effort downgrade, not a byte-faithful
  /// round trip — `plainText` exists to keep at least the text when that happens.
  struct PasteboardSnapshot: Sendable {
    /// One entry per item the pasteboard held, in order. An entry with an empty
    /// `dataMap` means the item existed but none of its representations could be
    /// materialized — distinct from the pasteboard having held no items at all,
    /// which is `items.isEmpty`.
    let items: [SendablePasteboardItem]
    /// The pasteboard's plain-string flavor, kept separately as a restore floor for
    /// when no item's string representation could be materialized — whether
    /// nothing materialized at all or only types that aren't the text did.
    let plainText: String?
  }
#endif
