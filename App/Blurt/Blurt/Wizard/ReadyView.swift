import BlurtEngine
import SwiftUI

/// The "you're all set" screen shown in the main window once setup is complete.
/// It states the dictation shortcut, the style in effect, and the recent
/// dictations — there's nothing to configure here, and deliberately no Settings
/// control: the standard app-menu "Settings…" (⌘,) and the menu-bar item are
/// the routes, so the window stays a status surface rather than growing a
/// second door to the same place.
struct ReadyView: View {
  var coordinator: AppCoordinator
  // Observed (not read once) so changing the dictation key in the separate
  // Settings window re-renders this window's keycap live — see `BoundTriggerKey`.
  @BoundTriggerKey private var triggerKey

  /// Observed for the same reason as the trigger key, and bound to *observe*,
  /// not to write: the store owns the decoding and the active-vs-Default rule
  /// (see `StyleProfileStore`), and `@AppStorage` is what re-renders this window
  /// when the settings sheet adds a style or the switcher changes the active
  /// one. Hoisted here rather than into the switcher because this view decides
  /// whether the row renders at all.
  @AppStorage(StyleProfileStore.defaultsKey) private var rawProfiles = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var rawActiveID = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Decoded and resolved once per render: `body` re-runs on every dictation
    // (the Recent list is live), and both answers cost a JSON decode. Which
    // style is active is the engine's rule — the stored pointer, `nil` for the
    // Default sentinel, or the first profile when it names nothing — never a
    // second reading here.
    let profiles = StyleProfileStore().profiles(decoding: rawProfiles)
    let active = StyleProfileStore.active(in: profiles, id: rawActiveID)
    // Sections sit 20 pt apart; the wordmark and the status block are one
    // idea, so they nest in a tighter 14 pt group rather than spreading to
    // match.
    VStack(spacing: 20) {
      VStack(spacing: 14) {
        ReadyBrandingView()
          // The logo PNG carries ~16% transparent margin top and bottom;
          // cancel the bottom one (scaled to today's 180 pt render, where the
          // old 280 pt cancelled 16) so the gap to the readout is the VStack
          // spacing, not ~2x it.
          .padding(.bottom, -10)

        statusBlock(activeStyleName: active?.name)
      }

      // No profiles, no row: an `if` with no `else` contributes no view and no
      // stack spacing, so the window is byte-identical to one without styles —
      // deliberately not an empty-state control inviting the user to make one,
      // which would be a permanent advert for an optional feature.
      if !profiles.isEmpty {
        StyleRow(profiles: profiles, activeID: active?.id)
          // Locked while the mic is opening or capturing: a style clicked
          // mid-utterance would disagree with what the request was built with.
          // `.disabled` propagates to the picker and the hidden ⌘1–⌘5 buttons,
          // whose shortcuts don't fire while disabled.
          .disabled(coordinator.isCapturing)
      }

      // `displayed`, not `entries`: the ring remembers 100 dictations (they are
      // also request context — see `ConversationContext`) and this list is three
      // rows tall.
      RecentDictationsSection(entries: coordinator.recentDictations.displayed)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 32)
    // The standard titlebar supplies the top clearance now (the logo's
    // transparent margin used to); match the section spacing top and bottom so
    // the readout and the Recent card sit in an evenly-padded window.
    .padding(.top, 20)
    .padding(.bottom, 20)
    .frame(width: MainWindow.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The window's top block: the shortcut readout at rest, swapped for the
  /// listening state while audio is actually being captured. Both render into
  /// one fixed-height slot (the `RecentDictationsSection` reservation trick) so
  /// the Style row and Recent list below never move on the swap. The swap is
  /// gated on the same phase stream the overlay pill renders
  /// (`coordinator.menuBarStatus`, whose `.recording` deliberately excludes the
  /// mic bring-up) — during "Connecting…" nothing is captured yet, so claiming
  /// "Listening" would invite unrecoverable speech; the readout stays put and
  /// the pill carries the warming-up state.
  private func statusBlock(activeStyleName: String?) -> some View {
    ZStack {
      if coordinator.menuBarStatus == .recording {
        listeningState(activeStyleName: activeStyleName)
      } else {
        shortcutReadout
      }
    }
    .frame(height: Self.statusBlockHeight)
    // Esc cancels the in-flight dictation — same command the overlay's owner
    // submits (`.cancel`), scoped to this window by living on a button in it.
    // Present through all of capture (not just `.recording`), so Esc during
    // the mic bring-up also cancels rather than beeping.
    .background {
      if coordinator.isCapturing {
        Button("Cancel Dictation") { coordinator.session.submit(.cancel) }
          .keyboardShortcut(.cancelAction)
          .hidden()
      }
    }
  }

  /// Both faces are two text lines on the shared tiers, so this is simply
  /// enough for either with breathing room; each centers in the same slot and
  /// nothing below moves on the swap.
  private static let statusBlockHeight: CGFloat = 44

  /// The idle readout: "Tap **Right Command (⌘)** to start and stop." over
  /// "Or hold it to talk, then release." — the key spelled out and bolded
  /// inline (`TriggerKey.fullName`), no keycap chip. Static on purpose: which
  /// style is in effect is the Style row's job to say — its selected segment
  /// is always visible right below — so repeating it here would be two
  /// readouts to keep in agreement. Both lines take their ideal size: inside
  /// the fixed-height slot a squeezed line can't fall back to wrapping, so
  /// without this the slightest width shortfall rendered as a truncated key
  /// name ("right…").
  private var shortcutReadout: some View {
    VStack(spacing: 2) {
      (Text("Tap ") + Text(triggerKey.fullName).bold() + Text(" to start and stop."))
        .statusPrimaryLine()
        .fixedSize()
      Text("Or hold it to talk, then release.")
        .statusSecondaryLine()
        .fixedSize()
    }
  }

  /// The capture-in-progress face of the top block: the pill's waveform cue in
  /// its color (`OverlayBrandPalette.cyan` — the tint `WaveformMeter` uses while
  /// recording), a bold "Listening…", and the way out. The style clause names
  /// the active profile; with none active the sentence starts at "Tap again" —
  /// "Blurting in Cleaned Up." reads as if a profile by that name existed.
  private func listeningState(activeStyleName: String?) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "waveform")
        .font(.title2)
        .foregroundStyle(OverlayBrandPalette.cyan)
        // The pill's live-capture heartbeat (`RecordingTag`), same cadence,
        // stilled under Reduce Motion the same way.
        .pulsingOpacity(period: 1.2, minOpacity: 0.4, animated: !reduceMotion)
      VStack(alignment: .leading, spacing: 2) {
        // Bold as inline emphasis, the same role the key name's bold plays on
        // the idle face — the tier itself (size, color) comes from the shared
        // style, so the swap reads as one surface changing words.
        Text("Listening…")
          .bold()
          .statusPrimaryLine()
          .fixedSize()
        Text(listeningSubtitle(activeStyleName: activeStyleName))
          .statusSecondaryLine()
          // One line, tail-truncated if a long style name pushes it past the
          // content width: at the slot's fixed height a wrap would clip mid
          // letter, and the sentence's load-bearing halves ("Blurting in
          // <style>", Esc) front-load ahead of the cut.
          .lineLimit(1)
      }
    }
    // One element, phrased once — the glyph is decoration and the ellipsis is
    // not worth hearing.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Listening. \(listeningSubtitle(activeStyleName: activeStyleName))")
  }

  /// The escape clause covers both end mechanisms honestly: a tap-mode
  /// dictation ends with another tap, a held key ends on release — the block
  /// can't know which started this one, so it names both.
  private func listeningSubtitle(activeStyleName: String?) -> String {
    let escape = "Tap again or release to finish — Esc cancels."
    guard let activeStyleName else { return escape }
    return "Blurting in \(activeStyleName). \(escape)"
  }
}

/// The BLURT wordmark over the status block. A header mark now, not the
/// window's identity — the standard titlebar names the app — which is why it
/// renders well under its old 280 pt and simply omits itself if the PNG can't
/// load rather than swapping in a fallback identity view.
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
        .frame(maxWidth: 180)
        .accessibilityLabel("Blurt logo")
    }
  }
}

/// The style switcher: a System Settings–style labeled row — leading "Style"
/// label, trailing segmented control — in the same rounded `.quinary` card as
/// the Recent list below it, so the window's two in-content surfaces match.
/// The control's first segment, **Cleaned Up**, is the base styling (no
/// profile instructions appended) and the rest are the user's profiles — the
/// HIG control for a small, always-visible set of mutually exclusive options,
/// so selection chrome, sizing and accessibility come from AppKit rather than
/// hand-rolled buttons. It sits between the shortcut readout and the Recent
/// list because which style is in effect is the one dictation setting worth
/// changing mid-flow — Settings owns creating and editing profiles (see
/// `SettingsWindowRoot`'s Styles section), this owns which one is in effect.
/// The choice is **sticky**: a selection holds until the user makes another,
/// so a switch is not something to redo before every dictation. `ReadyView`
/// renders it only while at least one profile exists — a lone Cleaned Up
/// segment would have nothing to switch to.
private struct StyleRow: View {
  /// Already decoded and resolved by `ReadyView`, which observes the slots —
  /// this view is pure render-and-write.
  let profiles: [StyleProfile]
  /// The active profile's id, or `nil` for Cleaned Up. `nil` is safe to *mean*
  /// Cleaned Up here even though an empty store also resolves to it, because
  /// this view only exists while `profiles` is non-empty.
  let activeID: StyleProfile.ID?

  /// Selection writes go through the store — never the raw slot — so the store
  /// keeps owning how a choice is encoded (a profile's id, or the store's
  /// "default" sentinel for Cleaned Up; see `HotkeyStepView.selection` for the
  /// precedent).
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
    // The row shape is `SettingRow`'s (leading label, trailing control, center
    // alignment) but built inline — `SettingRow` would wrap the title in an
    // icon-bearing `Label`. The visible "Style" text and the picker's title
    // are one element to VoiceOver, not two: a hidden picker label is still
    // its accessibility name (the `PickerSettingRow` pattern), so the visible
    // text is marked decorative rather than announced twice.
    HStack {
      Text("Style")
        .accessibilityHidden(true)
      Spacer(minLength: 12)
      Picker("Style", selection: selection) {
        Text(StyleProfileStore.defaultStyleName).tag(StyleProfile.ID?.none)
        ForEach(profiles) { profile in
          Text(profile.name).tag(StyleProfile.ID?.some(profile.id))
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier(UITestIdentifiers.styleProfilePicker)
      .background(shortcuts)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // Full width, like the Recent card below: both stretch to the one content
    // width `ReadyView`'s horizontal padding leaves, so the two cards' edges
    // align by construction rather than by matching numbers.
    .frame(maxWidth: .infinity)
    // The Recent card's container, so the two surfaces read as one family.
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.quinary)
    )
  }

  /// Keyboard shortcuts for the segments: ⌘1 selects Cleaned Up, ⌘2…⌘5 the
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
      Button(StyleProfileStore.defaultStyleName) { StyleProfileStore().activateDefault() }
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

/// The status block's two line tiers, shared by its idle and Listening faces so
/// the swap can't drift into two designs trading places: identical size and
/// color per tier, with weight left to inline emphasis (the idle face bolds the
/// key name, the Listening face its "Listening…"). Private to this file — these
/// name the top block's tiers, not an app-wide type ramp.
extension View {
  /// Tier 1: the sentence that says what to do (or what is happening).
  fileprivate func statusPrimaryLine() -> some View {
    font(.body)
  }

  /// Tier 2: the supporting line beneath it, quieter in size and color.
  fileprivate func statusSecondaryLine() -> some View {
    font(.subheadline)
      .foregroundStyle(.secondary)
  }
}
