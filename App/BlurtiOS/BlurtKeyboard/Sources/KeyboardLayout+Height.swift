import BlurtDesign
import BlurtiOSCore
import CoreFoundation

extension KeyboardLayout {
  /// The keyboard's height on screen, from the layout's rows at the iPhone
  /// keyboard's own spacing: see `App/BlurtiOS/DESIGN.md` for the arithmetic.
  var height: CGFloat {
    let metrics = DesignTokens.Metrics.self
    return switch self {
    case .slimBar: 2 * metrics.marginVertical + metrics.voicebarHeight
    case .panel: metrics.layoutPanel
    case .full:
      metrics.marginVertical + metrics.voicebarHeight + 4 * metrics.keyHeight + 3 * metrics.rowGap
        + metrics.marginBottomKeys
    }
  }
}
