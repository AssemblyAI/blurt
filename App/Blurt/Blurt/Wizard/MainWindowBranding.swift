import SwiftUI

/// The `blurt` wordmark over the setup screen's form (`WizardView`; the ready
/// screen goes without, its toolbar holding the search): the brand-green mark
/// (`Design/brand/blurt-ready-logo.png`, a 720×180 rasterization of the design's
/// vector wordmark, so its 72×18 pt slot is fed nearly 7× the pixels it needs and
/// stays crisp at any display scale). Smoothly interpolated — it's curved
/// letterforms now, not the pixel-art mark it replaced, which needed
/// nearest-neighbor to keep its pixels square. A header mark, not the window's
/// identity — the standard titlebar names the app — which is why it simply
/// omits itself if the PNG can't load rather than swapping in a fallback
/// identity view.
struct MainWindowBranding: View {
  /// Loaded once for the process rather than per `body` evaluation: a bundle
  /// lookup plus a PNG decode is not something to re-do on the main thread
  /// each time the setup screen re-renders.
  ///
  /// Left to the target's `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` default
  /// rather than spelled `nonisolated(unsafe)`: `body` reads it on the main actor
  /// either way, and this can't then break if a future SDK marks `NSImage`
  /// `Sendable` (which would make the attribute an "unnecessary" warning, and the
  /// app target builds with warnings-as-errors).
  private static let logo: NSImage? = Bundle.main
    .url(forResource: "blurt-ready-logo", withExtension: "png")
    .flatMap(NSImage.init(contentsOf:))

  var body: some View {
    if let image = Self.logo {
      Image(nsImage: image)
        // Drawn as a template tinted with the accent rather than shipped in its
        // own color. The design draws the wordmark in two shades — `#01762F` on
        // light, `#67AD82` on dark (its `Logo_Dark` / `Logo_Light` pair) — and
        // those are precisely the accent's two appearances, so tinting gets the
        // dark-mode variant for free from one asset. A fixed-color PNG kept the
        // dark green on a dark window, where it goes muddy. It also means the
        // mark and the accent-filled buttons beside it can't drift apart: they
        // now resolve the same color, rather than agreeing by coincidence.
        .renderingMode(.template)
        .interpolation(.high)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 64)
        .foregroundStyle(BlurtBrand.accent)
        .accessibilityLabel("Blurt logo")
    }
  }
}
