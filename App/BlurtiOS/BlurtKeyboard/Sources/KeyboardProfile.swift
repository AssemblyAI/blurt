import BlurtDesign
import CoreFoundation
import Foundation

/// The keyboard's numbers for the phone it is on: which generation of the
/// iPhone keyboard the host draws around it, and how wide it is. Built once
/// per appearance (`KeyboardViewController`) from the OS, the width, whether
/// the keyboard draws its own globe, and whether the host wraps it in a
/// container; every view reads it from the environment and carries no
/// generation of its own.
///
/// Two generations. **Classic** — iOS 18 through 25, and an iOS 26 host that
/// has not adopted the new material (no container around the keyboard): keys
/// laid out as W/10 cells with the caps inset inside them, Apple's grey as the
/// surface, the system theme by default. **Glass** — iOS 26 and later with the
/// host's rounded container detected around the keyboard: the geometry
/// measured on the iPhone 18 Pro, the surface clear, the keys in the
/// container colours. The two sets of numbers are the `classic/*` and
/// `glass/*` tokens (DESIGN.md › Apple's geometry, measured).
nonisolated struct KeyboardProfile: Equatable, Sendable {
  enum Generation: String, Sendable {
    case classic
    case glass
  }

  /// Compact (375–402: every phone but the Plus and Max) or large (414 and
  /// up). The numbers are the same today; the class is here so a width that
  /// needs its own (the Max phones' taller keys, once measured) has a place.
  enum SizeClass: String, Sendable {
    case compact
    case large
  }

  private typealias Metrics = DesignTokens.Metrics

  let generation: Generation
  let sizeClass: SizeClass
  /// The keyboard's whole width, margins included.
  let width: CGFloat
  /// Whether the keyboard draws the globe (a Touch ID phone); a Face ID
  /// phone draws its own bar under the keyboard.
  let hasGlobe: Bool

  init(generation: Generation, width: CGFloat, hasGlobe: Bool) {
    self.generation = generation
    self.width = width
    self.hasGlobe = hasGlobe
    sizeClass = width >= Metrics.sizeLargeMinWidth ? .large : .compact
  }

  // MARK: - Resolving

  /// The first iOS that wraps a third-party keyboard in the host's own
  /// material. The one place the number lives: `generation(osMajor:…)` reads
  /// `osMajor` and nothing else asks the OS.
  static let glassOSMajor = 26

  /// This process's iOS major version, the one read of it.
  static var osMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

  /// Glass only on iOS 26 and later **and** with the host's container
  /// detected: an inset of at least `container/inset-min` above or below the
  /// keyboard, read from the input view's superview. An inset of nil is "not
  /// read yet" (before the view is in the hierarchy), and is taken as a
  /// container on an OS that has one, so the common case never flashes
  /// between heights; a host that has not adopted the material reports an
  /// inset of 0 and gets the classic keyboard.
  static func generation(osMajor: Int, hostContainerInset: CGFloat?) -> Generation {
    guard osMajor >= glassOSMajor else { return .classic }
    guard let hostContainerInset else { return .glass }
    return hostContainerInset >= Metrics.containerInsetMin ? .glass : .classic
  }

  /// The profile for this appearance: the OS this process runs on, the
  /// keyboard's width, its globe and the container inset read from the host.
  static func resolve(
    osMajor: Int = osMajor, width: CGFloat, hasGlobe: Bool, hostContainerInset: CGFloat?
  ) -> KeyboardProfile {
    KeyboardProfile(
      generation: generation(osMajor: osMajor, hostContainerInset: hostContainerInset), width: width,
      hasGlobe: hasGlobe)
  }

  /// A stand-in where no host is around — the gallery, the theme picker, a
  /// preview: this OS's generation at the given width, the container taken
  /// as present on an OS that has one.
  static func standIn(width: CGFloat, hasGlobe: Bool = true) -> KeyboardProfile {
    resolve(width: width, hasGlobe: hasGlobe, hostContainerInset: nil)
  }

  /// The generation a stand-in gets on this OS: what Settings names and
  /// offers before any keyboard has appeared.
  static var standInGeneration: Generation { generation(osMajor: osMajor, hostContainerInset: nil) }

  // MARK: - The numbers

  /// At the keyboard's sides: classic one cell inset, glass the measured
  /// cap margin.
  var marginSide: CGFloat {
    switch generation {
    case .classic: Metrics.classicMarginSide
    case .glass: Metrics.glassMarginSide
    }
  }

  /// A cap's inset inside its cell (classic), or the side margin (glass): the
  /// distance from the keyboard's edge to the first cap.
  var edgeInset: CGFloat { marginSide }

  var keyGap: CGFloat {
    switch generation {
    case .classic: Metrics.classicKeyGap
    case .glass: Metrics.glassKeyGap
    }
  }

  /// Shift and delete stand this far from the letters.
  var sideGap: CGFloat {
    switch generation {
    case .classic: Metrics.classicSideGap
    case .glass: Metrics.glassSideGap
    }
  }

  var keyHeight: CGFloat {
    switch generation {
    case .classic: Metrics.classicKeyHeight
    case .glass: Metrics.glassKeyHeight
    }
  }

  var rowGap: CGFloat {
    switch generation {
    case .classic: Metrics.classicRowGap
    case .glass: Metrics.glassRowGap
    }
  }

  /// The keyboard's top, above the voice row; the slim bar's bottom too.
  var marginTop: CGFloat {
    switch generation {
    case .classic: Metrics.classicMarginTop
    case .glass: Metrics.glassMarginTop
    }
  }

  /// Under the bottom row of keys.
  var bottomInset: CGFloat {
    switch generation {
    case .classic: Metrics.classicBottomInset
    case .glass: Metrics.glassBottomInset
    }
  }

  /// The band above the first key row: the voice row and the margin over it,
  /// where the system keyboard keeps its suggestions.
  var topBand: CGFloat { marginTop + Metrics.voicebarHeight }

  var keyRadius: CGFloat {
    switch generation {
    case .classic: Metrics.classicKeyRadius
    case .glass: Metrics.glassKeyRadius
    }
  }

  /// Whether the host wraps the keyboard in its own material: the surface
  /// goes clear and the keys take the container colours.
  var inContainer: Bool { generation == .glass }

  /// Whether the face's surface is painted under the keys: always outside a
  /// container (nothing else is under the keys there), and inside one only
  /// when `surface/paint` says so.
  var paintsSurface: Bool { !inContainer || Metrics.surfacePaint > 0 }

  /// 123 and the globe — the width every other bottom-row key is measured
  /// from — at a row width: classic a share of the W/10 cell, glass the
  /// measured width scaled from the reference width.
  func abcWidth(rowWidth: CGFloat) -> CGFloat {
    switch generation {
    case .classic:
      let cell = (rowWidth + 2 * marginSide) / 10
      return Metrics.classicAbcCells * cell - keyGap
    case .glass:
      return Metrics.glassAbcWidth402 * (rowWidth + 2 * marginSide) / Metrics.glassReferenceWidth
    }
  }
}
