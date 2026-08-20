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

  /// Observed for the same reason as the trigger key, and bound to *observe*,
  /// not to write: the store owns the decoding and the active-vs-Default rule
  /// (see `StyleProfileStore`), and `@AppStorage` is what re-renders this window
  /// when the settings sheet adds a style or the switcher changes the active
  /// one. Hoisted here rather than into the switcher because the shortcut
  /// readout names the active style too.
  @AppStorage(StyleProfileStore.defaultsKey) private var rawProfiles = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var rawActiveID = ""

  var body: some View {
    // Decoded and resolved once per render: `body` re-runs on every dictation
    // (the Recent list is live), and both answers cost a JSON decode. Which
    // style is active is the engine's rule — the stored pointer, `nil` for the
    // Default sentinel, or the first profile when it names nothing — never a
    // second reading here.
    let profiles = StyleProfileStore().profiles(decoding: rawProfiles)
    let active = StyleProfileStore.active(in: profiles, id: rawActiveID)
    // Sections sit 20 pt apart; the logo and shortcut readout are one idea,
    // so they nest in a tighter 14 pt group rather than spreading to match.
    VStack(spacing: 20) {
      VStack(spacing: 14) {
        ReadyBrandingView()
          // The logo PNG carries ~16% transparent margin top & bottom. The top
          // margin gives welcome clearance from the traffic lights; cancel the
          // bottom one so the gap to the text is the VStack spacing, not ~2x it.
          .padding(.bottom, -16)

        shortcutReadout(styleName: active?.name)
      }

      // No profiles, no switcher: an `if` with no `else` contributes no view
      // and no stack spacing, so the window is byte-identical to one without
      // styles — deliberately not an empty-state control inviting the user to
      // make one, which would be a permanent advert for an optional feature.
      if !profiles.isEmpty {
        StyleProfilePicker(profiles: profiles, activeID: active?.id)
      }

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

  /// "Tap or hold ⌘ to blurt", with the key drawn as a rounded keycap — and,
  /// while a named style is active, "… to blurt in Casual style", so the window
  /// says what the next dictation will actually do. Default keeps exactly the
  /// pre-styles line: it *is* the pre-styles behaviour, and naming it would
  /// suggest a "Default style" exists to edit somewhere.
  private func shortcutReadout(styleName: String?) -> some View {
    HStack(spacing: 6) {
      Text("Tap or hold")
        .foregroundStyle(.secondary)
      KeyCap(label: triggerKey.label)
      Text(styleName.map { "to blurt in \($0) style" } ?? "to blurt")
        .foregroundStyle(.secondary)
        // Names are capped (`StyleProfileStore.nameLimit`) but the cap is sized
        // for the switcher's segments, so a long one could still outgrow this
        // line: truncate the tail rather than wrapping the readout to two lines
        // and shifting everything below it.
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .font(.title3)
  }
}

/// The style switcher: a native segmented control whose first segment,
/// **Default**, is the base styling (no profile instructions appended) and the
/// rest are the user's profiles — the HIG control for a small, always-visible
/// set of mutually exclusive options, so selection chrome, sizing and
/// accessibility come from AppKit rather than hand-rolled buttons. It sits
/// between the shortcut readout and the Recent list because which style is in
/// effect is the one dictation setting worth changing mid-flow — Settings owns
/// creating and editing profiles (see `SettingsWindowRoot`'s Styles section),
/// this owns which one is in effect. The choice is **sticky**: a selection
/// holds until the user makes another, so a switch is not something to redo
/// before every dictation. `ReadyView` renders it only while at least one
/// profile exists — a lone Default segment would have nothing to switch to.
private struct StyleProfilePicker: View {
  /// Already decoded and resolved by `ReadyView`, which observes the slots —
  /// this view is pure render-and-write.
  let profiles: [StyleProfile]
  /// The active profile's id, or `nil` for Default. `nil` is safe to *mean*
  /// Default here even though an empty store also resolves to it, because this
  /// view only exists while `profiles` is non-empty.
  let activeID: StyleProfile.ID?

  /// Selection writes go through the store — never the raw slot — so the store
  /// keeps owning how a choice is encoded (a profile's id, or the Default
  /// sentinel; see `HotkeyStepView.selection` for the precedent).
  private var selection: Binding<StyleProfile.ID?> {
    Binding(
      get: { activeID },
      set: { newValue in
        let store = StyleProfileStore()
        if let profile = profiles.first(where: { $0.id == newValue }) {
          store.activate(profile)
        } else {
          store.activateDefault()
        }
      })
  }

  var body: some View {
    // The picker keeps its own (hidden) title so VoiceOver reads a meaningful
    // name for the control rather than an empty string — the same pattern as
    // `PickerSettingRow`.
    Picker("Dictation style", selection: selection) {
      Text("Default").tag(StyleProfile.ID?.none)
      ForEach(profiles) { profile in
        Text(profile.name).tag(StyleProfile.ID?.some(profile.id))
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityIdentifier(UITestIdentifiers.styleProfilePicker)
    .background(shortcuts)
  }

  /// Keyboard shortcuts for the segments: ⌘1 selects Default, ⌘2…⌘5 the
  /// profiles in row order. Hidden buttons rather than a `Commands` menu block,
  /// because the scoping is the point: a menu command fires while *any* of the
  /// app's windows is key (Settings included), whereas a button's shortcut is
  /// resolved through the window that hosts it — so these fire exactly while
  /// the main window is key, and not at all while it shows the wizard or has no
  /// styles (this view doesn't exist then). `.hidden()` keeps the buttons out
  /// of sight, layout (they're parked in `background`) and accessibility while
  /// leaving their shortcuts registered; the writes go through the same store
  /// calls as the picker's binding. A "Style" submenu naming the shortcuts —
  /// menu-bar discoverability — is a possible follow-up; the segments
  /// themselves are always visible, so nothing here is *only* reachable by
  /// shortcut.
  private var shortcuts: some View {
    Group {
      Button("Default") { StyleProfileStore().activateDefault() }
        .keyboardShortcut("1", modifiers: .command)
      // The store caps the list at `profileLimit` (4), so the digits end at ⌘5.
      ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
        Button(profile.name) { StyleProfileStore().activate(profile) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: .command)
      }
    }
    .hidden()
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
