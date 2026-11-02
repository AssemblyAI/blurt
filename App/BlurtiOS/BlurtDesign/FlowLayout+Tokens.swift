// `FlowLayout` itself lives in `App/Shared/FlowLayout.swift`, shared with the
// Mac app; the design system supplies only its spacing.
extension FlowLayout {
  /// The key-term pills' gap.
  package init() { self.init(spacing: DesignTokens.Metrics.appChipGap) }
}
