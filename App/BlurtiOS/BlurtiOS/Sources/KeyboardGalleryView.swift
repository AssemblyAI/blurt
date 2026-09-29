#if DEBUG
  import SwiftUI

  /// Every keyboard layout in every state, rendered inside the app: the design
  /// reference, and the way a screenshot of the keyboard is taken without
  /// tapping through Notes. Debug builds only, reached by launch argument:
  ///
  ///     -BlurtGallery <slimBar|panel|full> <state>[,<state>…] [theme] [-BlurtGalleryStill] [-BlurtGalleryBare]
  ///
  /// The last word is a theme id (`system`, `system-dark`, `ink`, `paper`,
  /// `lavender`, `mint`, `midnight`, `sunset`); the iPhone's light face when
  /// left out. Two switches make a capture reproducible for the design loop
  /// (DESIGN.md › Figma): `-BlurtGalleryStill` holds every motion at time
  /// zero — the ring, the meter's wave, the orb's fluid and grain — so two
  /// captures of one state are the same pixels; `-BlurtGalleryBare` draws the
  /// first row alone, no caption, inside a 2 pt `#FF00FF` registration border
  /// that `scripts/design-diff.swift crop` cuts to. `-BlurtOrb <size> <mood>`
  /// renders one orb fill by itself the same way, for Figma's image fills.
  /// where a state is `off` (no Full Access), `start` (app not listening),
  /// `idle`, `connecting`, `recording`, `processing`, `pasted`, `copied`,
  /// `error`, `landed` (the drop, timed for a screenshot) or `live` (a whole
  /// dictation walked on a clock, over and over, for watching or recording
  /// the motion). `scripts/ios-sim.sh` passes `BLURT_LAUNCH_ARGS` through, so
  ///
  ///     BLURT_LAUNCH_ARGS="-BlurtGallery panel idle,recording,processing" \
  ///       scripts/ios-sim.sh --screenshot panel.png
  ///
  /// is the whole loop. The keyboard's sources are compiled into the app (see
  /// project.yml: the theme picker and the home screen draw the real keyboard
  /// and orb too); the keyboard itself never runs here.
  struct KeyboardGalleryView: View {
    struct Row: Identifiable {
      let id = UUID()
      let caption: String
      let model: KeyboardModel
    }

    /// The capture switches, read from the launch arguments.
    struct Options: Equatable {
      /// Hold every motion at time zero, as Reduce Motion does, so a capture
      /// is the same pixels every time.
      var still = false
      /// One row, no caption, a registration border round the keyboard.
      var bare = false

      static func parse(_ arguments: [String]) -> Options {
        Options(still: arguments.contains("-BlurtGalleryStill"), bare: arguments.contains("-BlurtGalleryBare"))
      }
    }

    let rows: [Row]
    var options = Options()

    /// The registration colour and width `scripts/design-diff.swift crop` looks
    /// for. Drawn outside the keyboard's frame, so what is inside the border
    /// is exactly the keyboard's pixels — above and below only, so the
    /// keyboard keeps the phone's full width (the crop reads a missing side
    /// border as "the edge of the screen").
    static let registration = Color(red: 1, green: 0, blue: 1)
    static let registrationWidth: CGFloat = 2

    var body: some View {
      if options.bare, let row = rows.first {
        VStack {
          Spacer(minLength: 0)
          keyboard(row)
            .padding(.vertical, Self.registrationWidth)
            .background(Self.registration)
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(rows) { row in
              VStack(alignment: .leading, spacing: 4) {
                Text(row.caption).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal)
                keyboard(row)
              }
            }
          }
          .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
      }
    }

    private func keyboard(_ row: Row) -> some View {
      KeyboardRootView(model: row.model)
        .frame(height: row.model.effectiveLayout.height)
        .clipped()
        .environment(\.keyboardMotionHeld, options.still)
    }

    /// The rows named by the launch arguments; empty when they don't ask for
    /// the gallery at all.
    static func rows(from arguments: [String]) -> [Row] {
      guard let flag = arguments.firstIndex(of: "-BlurtGallery"), arguments.count > flag + 2,
        let layout = KeyboardLayout(rawValue: arguments[flag + 1])
      else { return [] }
      // The theme is the next word unless it is a switch.
      let theme = arguments.count > flag + 3 && !arguments[flag + 3].hasPrefix("-") ? arguments[flag + 3] : "system"
      return arguments[flag + 2].split(separator: ",").map { name in
        Row(
          caption: "\(layout.rawValue) · \(name) · \(theme)",
          model: model(layout: layout, state: String(name), theme: theme))
      }
    }

    private static func model(layout: KeyboardLayout, state: String, theme: String) -> KeyboardModel {
      let model = KeyboardModel()
      model.layout = layout
      // `system` is the iPhone's light face, `system-dark` its dark one.
      model.paletteOverride = .resolve(theme == "system-dark" ? "system" : theme, dark: theme == "system-dark")
      // `keys` shows the panel's carousel flipped to its keyboard page;
      // `term` the voice bar as the key-term field, mid-typing.
      model.panelShowsKeys = state == "keys"
      if state == "term" { model.termDraft = "Rizz" }
      // `landed`: the words go in 2.4 s after launch, so a screenshot taken 3 s
      // in (scripts/ios-sim.sh) catches the drop at its fullest.
      if state == "landed" { model.resultLandedAt = Date().addingTimeInterval(2.4) }
      if state == "live" { walk(model) }
      model.hasFullAccess = state != "off"
      model.isListening = state != "off" && state != "start"
      let phase: PhaseSnapshot.State =
        switch state {
        case "connecting": .connecting
        case "recording": .recording
        case "processing": .processing
        case "pasted": .pasted
        case "copied": .copied
        case "error": .error
        default: .idle
        }
      model.snapshot = PhaseSnapshot(
        state: phase, message: phase == .error ? "The microphone didn't start." : nil,
        level: phase == .recording ? 0.62 : 0, at: Date())
      return model
    }

    /// `live`: the key walks a whole dictation, again and again — idle for
    /// 1.5 s, connecting for 1 s, 4.5 s of recording with a made-up voice at
    /// the app's 12 Hz, processing for 1.5 s, the words landing, the pasted
    /// notice, idle again — so the fades can be watched, or recorded with
    /// `xcrun simctl io booted recordVideo`.
    private static func walk(_ model: KeyboardModel) {
      Task { @MainActor in
        @MainActor func set(_ state: PhaseSnapshot.State, level: Double = 0) {
          model.snapshot = PhaseSnapshot(state: state, message: nil, level: level, at: Date())
        }
        while !Task.isCancelled {
          set(.idle)
          try? await Task.sleep(for: .seconds(1.5))
          set(.connecting)
          try? await Task.sleep(for: .seconds(1))
          let start = Date()
          while Date().timeIntervalSince(start) < 4.5 {
            let t = Date().timeIntervalSince(start)
            let voice = 0.15 + 0.55 * abs(sin(t * 2.6)) * (0.55 + 0.45 * sin(t * 7.1))
            set(.recording, level: min(1, max(0, voice)))
            try? await Task.sleep(for: .milliseconds(80))
          }
          set(.processing)
          try? await Task.sleep(for: .seconds(1.5))
          model.resultLandedAt = Date()
          set(.pasted)
          try? await Task.sleep(for: .seconds(1.2))
          set(.idle)
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }

    /// `-BlurtOrb <size> <off|idle|listening|working|landed>`: one orb fill,
    /// still, on the ink surface, inside the registration border — the image
    /// Figma's `Orb/Disc` component uses, since a mesh gradient under grain is
    /// nothing Figma can draw natively (DESIGN.md › Figma). `landed` is the
    /// drop at its peak; `listening` is the gallery's level, 0.62.
    struct OrbStillView: View {
      let size: CGFloat
      let mood: PrismOrb.Mood
      let landedAt: Date?

      var body: some View {
        VStack {
          Spacer(minLength: 0)
          PrismOrb(mood: mood, landedAt: landedAt, animated: false)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .padding(KeyboardGalleryView.registrationWidth)
            .background(KeyboardGalleryView.registration)
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Brand.ink)
        .ignoresSafeArea()
      }

      static func parse(_ arguments: [String]) -> OrbStillView? {
        guard let flag = arguments.firstIndex(of: "-BlurtOrb"), arguments.count > flag + 2,
          let size = Double(arguments[flag + 1])
        else { return nil }
        switch arguments[flag + 2] {
        case "off": return OrbStillView(size: size, mood: .off, landedAt: nil)
        case "idle": return OrbStillView(size: size, mood: .idle, landedAt: nil)
        case "listening": return OrbStillView(size: size, mood: .listening(level: 0.62), landedAt: nil)
        case "working": return OrbStillView(size: size, mood: .working, landedAt: nil)
        case "landed": return OrbStillView(size: size, mood: .idle, landedAt: Date().addingTimeInterval(-0.6))
        default: return nil
        }
      }
    }
  }
#endif
