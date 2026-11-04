import BlurtDesign
import BlurtiOSCore
import CoreFoundation

extension KeyboardLayout {
  /// The keyboard's height on screen, from the layout's rows at the
  /// profile's spacing: see `App/BlurtiOS/DESIGN.md` for the arithmetic.
  func height(profile: KeyboardProfile) -> CGFloat {
    let metrics = DesignTokens.Metrics.self
    return switch self {
    case .slimBar: 2 * profile.marginTop + metrics.voicebarHeight
    case .panel: metrics.layoutPanel
    case .full:
      profile.marginTop + metrics.voicebarHeight + 4 * profile.keyHeight + 3 * profile.rowGap + profile.bottomInset
    }
  }
}
