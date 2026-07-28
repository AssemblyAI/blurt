import BlurtEngine
import SwiftUI

/// The "you're all set" screen shown in the main window once setup is complete.
/// It just states the dictation shortcut and offers a native-feeling link to the
/// Settings window — there's nothing to configure here.
struct ReadyView: View {
  var coordinator: AppCoordinator
  var openSettings: () -> Void
  // Observed (not read once) so changing the dictation key in the separate
  // Settings window re-renders this window's keycap live — see `BoundTriggerKey`.
  @BoundTriggerKey private var triggerKey

  var body: some View {
    // Sections sit 20 pt apart; the logo and shortcut readout are one idea,
    // so they nest in a tighter 14 pt group rather than spreading to match.
    VStack(spacing: 20) {
      VStack(spacing: 14) {
        ReadyBrandingView()
          // The logo PNG carries ~16% transparent margin top & bottom. The top
          // margin gives welcome clearance from the traffic lights; cancel the
          // bottom one so the gap to the text is the VStack spacing, not ~2x it.
          .padding(.bottom, -16)

        shortcutReadout
      }

      RecentDictationsSection(entries: coordinator.recentDictations.entries)

      Button(action: openSettings) {
        Label("Settings", systemImage: "gearshape")
          .labelStyle(.titleAndIcon)
          .symbolRenderingMode(.hierarchical)
      }
      // The system Liquid Glass button — hover/press chrome, edge highlights,
      // and accessibility fallbacks come from the style, not hand-rolled fills.
      // Falls back to `.bordered` on macOS 15–25 (see glassButtonStyleCompat).
      .glassButtonStyleCompat()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 32)
    .padding(.top, 4)
    .padding(.bottom, 20)
    .frame(width: MainWindow.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// "Tap or hold ⌘ to blurt", with the key drawn as a rounded keycap.
  private var shortcutReadout: some View {
    HStack(spacing: 6) {
      Text("Tap or hold")
        .foregroundStyle(.secondary)
      KeyCap(label: triggerKey.label)
      Text("to blurt")
        .foregroundStyle(.secondary)
    }
    .font(.title3)
  }
}

private struct ReadyBrandingView: View {
  /// Loaded once for the process rather than per `body` evaluation: this view
  /// sits in `ReadyView`, whose body re-runs on every new dictation
  /// (`recentDictations.entries`), and a bundle lookup plus a PNG decode is not
  /// something to re-do on the main thread each time.
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
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 280)
        .accessibilityLabel("Blurt logo")
    } else {
      // Fallback if the bundled logo can't be loaded — keep the ready screen's
      // identity (icon + name) rather than rendering an empty, contextless view.
      VStack(spacing: 8) {
        Image(systemName: "mic.fill")
          .font(.system(size: 44))
          .foregroundStyle(.secondary)
        Text("Blurt is ready")
          .font(.title2.weight(.semibold))
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Blurt is ready")
    }
  }
}

/// A single rounded key-cap, e.g. "⌃" or "D". A quiet semantic chip, not
/// Liquid Glass: over the ready window's flat background a glass chip has
/// nothing to refract and reads as bare floating text, and the HIG reserves
/// glass for the floating control layer rather than in-window content.
/// `.quinary` + `.separator` adapt to light/dark and Increase Contrast for
/// free, and match the Recent card's container fill above.
private struct KeyCap: View {
  var label: String

  var body: some View {
    Text(label)
      .font(.title3.weight(.medium).monospaced())
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.quinary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(.separator, lineWidth: 1)
      )
  }
}
