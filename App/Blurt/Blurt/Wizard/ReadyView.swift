import BlurtEngine
import SwiftUI

/// The "you're all set" screen shown in the main window once setup is complete.
/// It states the dictation shortcut, the style in effect, and the recent
/// dictations, and closes with a Settings button at the foot — the window's
/// own door to the Settings scene, alongside the standard app-menu
/// "Settings…" (⌘,) and the menu-bar item.
struct ReadyView: View {
  var coordinator: AppCoordinator
  var openSettings: () -> Void
  /// The style row's "+": opens Settings deep-linked to the Advanced pane,
  /// where styles are edited — a separate closure from `openSettings` so the
  /// plain Settings button keeps opening on General (see `MainWindowRoot`).
  var editStyles: () -> Void
  // Observed (not read once) so changing the dictation key in the separate
  // Settings window re-renders this window's keycap live — see `BoundTriggerKey`.
  @BoundTriggerKey private var triggerKey

  /// Observed for the same reason as the trigger key, and bound to *observe*,
  /// not to write: the store owns the decoding and the active-vs-Default rule
  /// (see `StyleProfileStore`), and `@AppStorage` is what re-renders this window
  /// when the settings sheet adds a style or the switcher changes the active
  /// one. Hoisted here rather than into the switcher because the status block
  /// needs the active style's name too.
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
    // The window's vertical rhythm, measured off the design rather than picked:
    // `sectionGap` between the stacked sections and between the wordmark and
    // the readout, `captionGap` from a caption to the card it names (captions
    // sit *above* their card, so the pair reads as label-then-thing), and a
    // wider `readoutGap` under the shortcut readout — the design gives that one
    // line noticeably more air before the controls start, which is what keeps
    // the window from reading as a single dense stack.
    VStack(spacing: MainWindow.sectionGap) {
      VStack(spacing: MainWindow.sectionGap) {
        ReadyBrandingView()

        statusBlock(activeStyleName: active?.name)
      }
      .padding(.bottom, MainWindow.readoutGap - MainWindow.sectionGap)

      // Always present, even with no custom styles: a pop-up holding Default
      // and "Edit Styles…" is the row's empty state, so the feature is
      // discoverable from the main window rather than only from Settings.
      VStack(alignment: .leading, spacing: MainWindow.captionGap) {
        Text("How Blurt cleans up your raw transcript")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)

        StyleRow(profiles: profiles, activeID: active?.id, editStyles: editStyles)
          // Locked while the mic is opening or capturing: a style picked
          // mid-utterance would disagree with what the request was built with.
          // `.disabled` propagates to the pop-up and the hidden ⌘1–⌘5 buttons,
          // whose shortcuts don't fire while disabled.
          .disabled(coordinator.isCapturing)
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
      // Prominent, so it takes the brand-green fill the design gives it: it's
      // the only button on the window's closing line.
      // Falls back to `.borderedProminent` on macOS 15–25 (see glassButtonStyleCompat).
      .glassButtonStyleCompat(prominent: true)
    }
    .frame(maxWidth: .infinity)
    // The design's margin on both comps (its cards run x 24.5 to 455.5 in a
    // 480-wide window). Was 32, which made this window's cards narrower than
    // the setup window's — the grouped `Form` there insets its rows to 20 and
    // can't be told otherwise. Named in `MainWindow` because `StyleRow` sizes
    // its pop-up against the width this leaves.
    .padding(.horizontal, MainWindow.contentMargin)
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
  private static let statusBlockHeight: CGFloat = 50

  /// The idle readout: "Tap **Right Command (⌘)** to start and stop." over
  /// "Or hold it to talk, then release." — the key spelled out and bolded
  /// inline (`TriggerKey.fullName`), no keycap chip. Static on purpose: which
  /// style is in effect is the Style row's job to say — its selected button
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

  /// The capture-in-progress face of the top block, mirroring the idle face's
  /// shape exactly — two centered lines on the shared tiers — so the swap
  /// reads as the same surface changing words: the pill's waveform cue in the
  /// accent (`#01762F` on light, `#67AD82` on dark — the adaptive value, not a
  /// pinned shade, since this glyph lives in a window that follows the system
  /// appearance) inline with a bold "Listening…", then the way out. The style
  /// clause names the active profile; with none active the sentence starts at
  /// "Tap again" — "Blurting in Default." reads as if a profile by that
  /// name existed.
  private func listeningState(activeStyleName: String?) -> some View {
    VStack(spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "waveform")
          .foregroundStyle(BlurtBrand.accent)
          // The pill's live-capture heartbeat (`RecordingTag`), same cadence,
          // stilled under Reduce Motion the same way.
          .pulsingOpacity(period: 1.2, minOpacity: 0.4, animated: !reduceMotion)
        // Bold as inline emphasis, the same role the key name's bold plays on
        // the idle face.
        Text("Listening…")
          .bold()
      }
      // The tier on the line, not the text, so the SF Symbol scales with the
      // words it sits beside instead of carrying its own size.
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

/// The `blurt` wordmark over the status block: the brand-green mark
/// (`Branding/blurt-ready-logo.png`, a 720×180 rasterization of the design's
/// vector wordmark, so its 180×45 pt slot is fed 4× the pixels it needs and
/// stays crisp at any display scale). Smoothly interpolated — it's curved
/// letterforms now, not the pixel-art mark it replaced, which needed
/// nearest-neighbor to keep its pixels square. A header mark, not the window's
/// identity — the standard titlebar names the app — which is why it simply
/// omits itself if the PNG can't load rather than swapping in a fallback
/// identity view.
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
        .frame(maxWidth: 180)
        .foregroundStyle(BlurtBrand.accent)
        .accessibilityLabel("Blurt logo")
    }
  }
}

/// The status block's two line tiers, shared by its idle and Listening faces so
/// the swap can't drift into two designs trading places: identical size and
/// color per tier, with weight left to inline emphasis (the idle face bolds the
/// key name, the Listening face its "Listening…"). Private to this file — these
/// name the top block's tiers, not an app-wide type ramp.
extension View {
  /// Tier 1: the sentence that says what to do (or what is happening). Set a
  /// step above body and semibold, the weight carried by the whole line rather
  /// than the key name alone — this is the window's headline, and the design
  /// gives it the visual rank to match. The inline `.bold()` on the key name
  /// still reads as emphasis against semibold.
  fileprivate func statusPrimaryLine() -> some View {
    font(.title2.weight(.semibold))
  }

  /// Tier 2: the supporting line beneath it, quieter in color and one tier
  /// down in size — a step below tier 1 rather than two, so the pair reads as
  /// one block instead of a heading with a caption.
  fileprivate func statusSecondaryLine() -> some View {
    font(.title3)
      .foregroundStyle(.secondary)
  }
}
