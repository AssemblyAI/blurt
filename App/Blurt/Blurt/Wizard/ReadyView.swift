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

      StyleProfileRow()

      // `displayed`, not `entries`: the ring remembers 100 dictations (they are
      // also request context — see `ConversationContext`) and this list is three
      // rows tall.
      RecentDictationsSection(entries: coordinator.recentDictations.displayed)

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

/// The style switcher: one button per defined style profile, the active one
/// drawn as selected. It sits between the shortcut readout and the Recent list
/// because which style is in effect is the one dictation setting worth changing
/// mid-flow — Settings owns creating and editing them (see
/// `SettingsWindowRoot`'s Styles section), this owns which one is in effect.
/// The choice is **sticky**: clicking a style leaves it active until another is
/// clicked, so a switch is not something to redo before every dictation.
///
/// **Renders nothing at all when no styles are defined**, which is every user
/// who has never opened that section: the window then looks exactly as it did
/// before styles existed. Deliberately not an empty-state chip inviting the
/// user to make one — a permanent advert for an optional feature.
private struct StyleProfileRow: View {
  /// Bound to observe: the store decodes and resolves both slots (see
  /// `StyleProfileStore`), and `@AppStorage` is what re-renders this row when
  /// the settings sheet adds a style or a click here changes the active one.
  @AppStorage(StyleProfileStore.defaultsKey) private var rawProfiles = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var rawActiveID = ""

  /// One fixed width for every button, so the row's size — and everything below
  /// it — can't shift with the length of a name. `StyleProfileStore.nameLimit`
  /// is the other half of that: a name too long to fit is capped, not wrapped.
  private static let buttonWidth: CGFloat = 96

  var body: some View {
    // Decoded and resolved once per render: `body` re-runs on every dictation
    // (the Recent list above is live), and both answers cost a JSON decode.
    // Which one reads as selected is the engine's rule — the stored pointer, or
    // the first profile when it names nothing — not a second one here.
    let defined = StyleProfileStore().profiles(decoding: rawProfiles)
    let activeID = StyleProfileStore.active(in: defined, id: rawActiveID)?.id
    // No profiles, no row: an `if` with no `else` contributes no view and no
    // stack spacing, so the window is byte-identical to one without styles.
    if !defined.isEmpty {
      HStack(spacing: 8) {
        // Enumerated for the accessibility identifier only; identity stays the
        // profile's own id so a rename doesn't rebuild the button.
        ForEach(Array(defined.enumerated()), id: \.element.id) { index, profile in
          Button(profile.name) { StyleProfileStore().activate(profile) }
            .lineLimit(1)
            // Style first, then the frame, so the button's own chrome fills the
            // fixed width rather than sitting centered inside it.
            .glassButtonStyleCompat(prominent: profile.id == activeID)
            .frame(width: Self.buttonWidth)
            // The prominent fill is the only visual cue, so state the selection
            // for VoiceOver too rather than leaving four identical buttons.
            .accessibilityAddTraits(profile.id == activeID ? [.isSelected] : [])
            .accessibilityIdentifier(UITestIdentifiers.styleProfileButton(index))
        }
      }
    }
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
