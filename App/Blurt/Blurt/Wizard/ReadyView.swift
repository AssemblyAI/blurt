import BlurtEngine
import SwiftUI

/// The "you're all set" screen shown in the main window once setup is complete:
/// the wordmark over a grouped form — the shortcut and the style in effect,
/// then the recent dictations — and a bottom bar with the attribution links
/// and a Settings button, the window's own door to the Settings scene
/// alongside the app-menu "Settings…" (⌘,) and the menu-bar item.
///
/// A grouped `Form`, the same surface the Settings window's panes use, rather
/// than hand-drawn cards: one inset-grouped style for every container means
/// one set of fills, radii and separators — the system's, which also carry
/// dark mode, Increase Contrast and vibrancy — instead of several custom greys
/// that each nearly matched.
struct ReadyView: View {
  var coordinator: AppCoordinator
  var openSettings: () -> Void
  // Observed (not read once) so changing the dictation key in the separate
  // Settings window re-renders this window's keycap live — see `BoundTriggerKey`.
  @BoundTriggerKey private var triggerKey
  /// Tap or hold, tap, or hold — observed like the key, so the shortcut row's
  /// words follow a change made in Settings. Raw slot, decoded through
  /// `fromPersisted`, which owns the unset default.
  @AppStorage(TriggerActivationStore.defaultsKey) private var activationRaw = ""
  private var activation: TriggerActivation { .fromPersisted(activationRaw) }

  /// Kept as view state because Settings is a separate scene: its defaults
  /// write can otherwise leave this already-open window displaying the old
  /// pop-up until relaunch. The store posts an explicit change notification
  /// after each list write, and this window reloads through the store so its
  /// decoding and normalization rules remain the single source of truth.
  @State private var profiles = StyleProfileStore().profiles
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var rawActiveID = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // Decoded and resolved once per render: `body` re-runs on every dictation
    // (the Recent list is live), and both answers cost a JSON decode. Which
    // style is active is the engine's rule — the stored pointer, `nil` for the
    // Default sentinel, or the first profile when it names nothing — never a
    // second reading here.
    let active = StyleProfileStore.active(in: profiles, id: rawActiveID)
    VStack(spacing: 0) {
      ReadyBrandingView()
        .padding(.top, 24)
        .padding(.bottom, 2)

      Form {
        Section {
          shortcutRow
          // Always present, even with no custom styles, so the active treatment
          // remains visible from the main window.
          StyleRow(profiles: profiles, activeID: active?.id)
            // Locked while the mic is opening or capturing: a style picked
            // mid-utterance would disagree with what the request was built
            // with. `.disabled` propagates to the pop-up and the hidden
            // ⌘1–⌘5 buttons, whose shortcuts don't fire while disabled.
            .disabled(coordinator.isCapturing)
        } footer: {
          StylesInertNotice()
        }

        // `displayed`, not `entries`: the ring remembers 100 dictations (they
        // are also request context — see `ConversationContext`) and this list
        // is three rows tall.
        RecentDictationsSection(
          entries: coordinator.recentDictations.displayed, triggerKey: triggerKey,
          activation: activation)
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)

      bottomBar
        // The grouped form insets its sections by 20, so the bar lines up
        // with their edges.
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
    .frame(width: MainWindow.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
    .onReceive(
      NotificationCenter.default.publisher(for: StyleProfileStore.profilesDidChangeNotification)
    ) { _ in
      profiles = StyleProfileStore().profiles
    }
  }

  /// The dictation shortcut as a form row: "Shortcut" leading, and trailing
  /// the bound key as a keycap beside a word on what it does. The keycap fills
  /// with the accent the moment the key goes down (`isCapturing`, which
  /// includes the mic bring-up) — the window's proof the hotkey is registered —
  /// while the words swap from the configured gesture ("Tap or hold", "Tap",
  /// or "Hold" — `TriggerActivation.label`) to the live phase.
  ///
  /// The phase is gated on the same stream the overlay pill renders
  /// (`coordinator.menuBarStatus`, whose `.recording` deliberately excludes
  /// the mic bring-up) — during "Connecting…" nothing is captured yet, so
  /// claiming "Listening" would invite unrecoverable speech.
  private var shortcutRow: some View {
    SettingRow(title: "Shortcut", systemImage: "keyboard") {
      HStack(spacing: 8) {
        phaseText
          .foregroundStyle(.secondary)
        KeyCap(label: triggerKey.keycapLabel, isLit: coordinator.isCapturing)
      }
    }
    .help(activation.guidance)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shortcut: \(triggerKey.spokenName). \(phaseDescription)")
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

  /// The shortcut row's trailing words: how to use the key at rest, then what
  /// the dictation is doing.
  @ViewBuilder
  private var phaseText: some View {
    switch coordinator.menuBarStatus {
    case .recording:
      HStack(spacing: 4) {
        Image(systemName: "waveform")
          .foregroundStyle(BlurtBrand.accent)
          // The pill's live-capture heartbeat (`RecordingTag`), same cadence,
          // stilled under Reduce Motion the same way.
          .pulsingOpacity(period: 1.2, minOpacity: 0.4, animated: !reduceMotion)
        Text("Listening…")
      }
    case .transcribing:
      Text("Transcribing…")
    case .idle:
      Text(activation.label)
    }
  }

  /// The phase for VoiceOver, spelled out where the row abbreviates — naming
  /// only the gestures the configured activation responds to.
  private var phaseDescription: String {
    switch coordinator.menuBarStatus {
    case .recording: "Listening. \(activation.finishHint) Escape cancels."
    case .transcribing: "Transcribing."
    case .idle: activation.guidance
    }
  }

  /// The window's last row, laid out the way a macOS window's bottom bar is:
  /// the attribution on the leading edge, the one button on the trailing edge.
  /// A standard push button — Settings is a place visited once, and ⌘, and the
  /// app menu already reach it, so it takes neither the accent nor glass.
  private var bottomBar: some View {
    HStack {
      footerLinks
      Spacer()
      Button(action: openSettings) {
        Label("Settings…", systemImage: "gearshape")
          .labelStyle(.titleAndIcon)
      }
    }
  }

  /// "Powered by AssemblyAI · Report a bug", caption-level. Links retain
  /// the system's semantic link color instead of reusing the brand accent that
  /// also colors noninteractive glyphs elsewhere in the window.
  ///
  /// Split so the linked words keep their affordance: "Powered by" is quiet
  /// secondary prose, while each `Link` carries the platform's link color;
  /// making the entire line secondary leaves the interactive words
  /// indistinguishable from static attribution.
  ///
  /// Sharing lives in the Help menu (`BlurtCommands`) rather than here: a
  /// half-linked "Share Blurt on LinkedIn" read as an ad on the window's
  /// quietest line. Each link omits itself if its URL fails to build
  /// (`force_unwrapping` is banned repo-wide).
  private var footerLinks: some View {
    HStack(spacing: 3) {
      if let url = BlurtLinks.poweredBy {
        Text("Powered by").foregroundStyle(.secondary)
        Link("AssemblyAI", destination: url)
      }
      if let issuesURL = BlurtLinks.reportBug {
        // The dot is decoration, so VoiceOver skips it.
        Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
        Link("Report a bug", destination: issuesURL)
      }
    }
    .font(.caption)
  }
}

/// The app's outbound links, shared by the ready screen's footer and the Help
/// menu (`BlurtCommands`). Failable construction throughout, so a caller omits
/// its link rather than force-unwrapping.
enum BlurtLinks {
  /// Where "Powered by AssemblyAI" points.
  static let poweredBy = URL(string: "https://www.assemblyai.com/blurt")

  /// The repo's GitHub issues.
  static let reportBug = URL(string: "https://github.com/AssemblyAI/blurt/issues")

  /// LinkedIn's share intent. It takes only a URL to share, so this one
  /// carries no message.
  static let shareOnLinkedIn: URL? = {
    var components = URLComponents(string: "https://www.linkedin.com/sharing/share-offsite/")
    components?.queryItems = [URLQueryItem(name: "url", value: "https://www.assemblyai.com/blurt")]
    return components?.url
  }()
}

/// The `blurt` wordmark over the form: the brand-green mark
/// (`Branding/blurt-ready-logo.png`, a 720×180 rasterization of the design's
/// vector wordmark, so its 104×26 pt slot is fed nearly 7× the pixels it needs and
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
        .frame(maxWidth: 104)
        .foregroundStyle(BlurtBrand.accent)
        .accessibilityLabel("Blurt logo")
    }
  }
}
