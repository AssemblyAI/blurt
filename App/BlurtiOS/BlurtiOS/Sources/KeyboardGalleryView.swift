#if DEBUG
  import SwiftUI

  /// Every keyboard layout in every state, rendered inside the app: the design
  /// reference, and the way a screenshot of the keyboard is taken without
  /// tapping through Notes. Debug builds only, reached by launch argument:
  ///
  ///     -BlurtGallery <slimBar|panel|full> <state>[,<state>…] [face] [-BlurtGalleryStill] [-BlurtGalleryBare] [-BlurtGalleryVoice a|b|c]
  ///
  /// The last word is a face, `light` or `dark` (the older theme words still
  /// land: `system` and `paper` are light, `system-dark` and `ink` dark); the
  /// light face when left out. Two switches make a capture reproducible for the design loop
  /// (DESIGN.md › Figma): `-BlurtGalleryStill` holds every motion at time
  /// zero — the ring, the meter's wave, the orb's fluid and grain — so two
  /// captures of one state are the same pixels; `-BlurtGalleryBare` draws the
  /// first row alone, no caption, inside a 2 pt `#FF00FF` registration border
  /// that `scripts/design-diff.swift crop` cuts to. `-BlurtGalleryVoice a|b|c`
  /// picks which mic concept draws (`VoiceElementKind`); `-BlurtVoice <a|b|c>
  /// <bar|panel|home> <state> [light|dark]` renders that element by itself.
  /// where a state is `off` (no Full Access), `start` (app not listening),
  /// `idle`, `connecting`, `recording`, `processing`, `pasted`, `copied`,
  /// `error`, `landed` (the drop, timed for a screenshot) or `live` (a whole
  /// dictation walked on a clock, over and over, for watching or recording
  /// the motion), plus the keyboard's own `keys` (the panel flipped to its
  /// keyboard page), `symbols`, `term` (the key-term field mid-typing),
  /// `send` (a return key with a label) and `saved` (the + just after a term
  /// was saved). `scripts/ios-sim.sh` passes `BLURT_LAUNCH_ARGS` through, so
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
        // The host's material, under a clear surface, as the app stands in for it.
        .background(row.model.palette.standIn)
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
      let theme = arguments.count > flag + 3 && !arguments[flag + 3].hasPrefix("-") ? arguments[flag + 3] : "light"
      let voice = VoiceElementKind.parse(arguments) ?? .shipped
      return arguments[flag + 2].split(separator: ",").map { name in
        Row(
          caption: "\(layout.rawValue) · \(name) · \(theme) · \(voice.rawValue)",
          model: model(layout: layout, state: String(name), theme: theme, voice: voice))
      }
    }

    /// The words that ask for the dark face; anything else is the light one.
    static let darkFaces: Set<String> = ["dark", "system-dark", "ink"]

    /// The pipeline's phases by gallery name; `landed` is pasted, the moment
    /// the words went in.
    private static let phases: [String: PhaseSnapshot.State] = [
      "connecting": .connecting, "recording": .recording, "processing": .processing, "pasted": .pasted,
      "copied": .copied, "error": .error, "landed": .pasted,
    ]

    private static func model(
      layout: KeyboardLayout, state: String, theme: String, voice: VoiceElementKind
    ) -> KeyboardModel {
      let model = KeyboardModel()
      model.layout = layout
      model.voiceKindOverride = voice
      model.paletteOverride = .resolve(KeyboardPalette.brandID, dark: Self.darkFaces.contains(theme))
      // `keys` shows the panel's carousel flipped to its keyboard page;
      // `term` the voice bar as the key-term field, mid-typing.
      model.panelShowsKeys = state == "keys" || state == "symbols"
      if state == "term" { model.termDraft = "Rizz" }
      // `symbols`: the keys on their symbols page; `send`: a field whose
      // return key says so; `saved`: the + a moment after a term was saved.
      model.symbolsPage = state == "symbols"
      if state == "send" { model.returnLabel = "send" }
      if state == "saved" { model.termSavedAt = Date() }
      // `landed`: the words go in 2.75 s after launch, so a screenshot taken
      // 3 s in (scripts/ios-sim.sh) catches the glint mid-sweep.
      if state == "landed" { model.resultLandedAt = Date().addingTimeInterval(2.75) }
      if state == "live" { walk(model) }
      model.hasFullAccess = state != "off"
      model.isListening = state != "off" && state != "start"
      let phase = Self.phases[state] ?? .idle
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

    /// `-BlurtVoice <a|b|c> <bar|panel|home> <state> [light|dark]`: one voice
    /// element by itself, in its slot's box, on the face's surface, inside the
    /// registration border — for the review sheet and for Figma. States are
    /// the pipeline's plus `off` (not ready) and `landed` (the glint, timed
    /// for a 3 s screenshot).
    struct VoiceStillView: View {
      let kind: VoiceElementKind
      let slot: VoiceSlot
      let state: VoiceState
      let landedAt: Date?
      let dark: Bool

      var body: some View {
        let palette: KeyboardPalette = dark ? .brandDark : .brandLight
        VStack {
          Spacer(minLength: 0)
          VoiceElementView(
            inputs: VoiceElementInputs(state: state, landedAt: landedAt, animated: true, palette: palette, slot: slot)
          )
          .frame(width: slot.box.width, height: slot.box.height)
          .padding(KeyboardGalleryView.registrationWidth)
          .background(KeyboardGalleryView.registration)
          .environment(\.voiceElementKind, kind)
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.standIn)
        .ignoresSafeArea()
      }

      static func parse(_ arguments: [String]) -> VoiceStillView? {
        guard let flag = arguments.firstIndex(of: "-BlurtVoice"), arguments.count > flag + 3,
          let kind = VoiceElementKind(rawValue: arguments[flag + 1]),
          let slot = VoiceSlot(rawValue: arguments[flag + 2])
        else { return nil }
        let dark = arguments.count > flag + 4 && darkFaces.contains(arguments[flag + 4])
        guard let (state, landedAt) = Self.state(named: arguments[flag + 3]) else { return nil }
        return VoiceStillView(kind: kind, slot: slot, state: state, landedAt: landedAt, dark: dark)
      }

      /// The states by name: the pipeline's, `off` (not ready) and `landed`
      /// (pasted, with the glint timed for the screenshot).
      private static func state(named name: String) -> (VoiceState, Date?)? {
        let states: [String: VoiceState] = [
          "off": VoiceState(phase: .idle, isReady: false),
          "idle": VoiceState(phase: .idle, isReady: true),
          "connecting": VoiceState(phase: .connecting, isReady: true),
          "recording": VoiceState(phase: .recording, isReady: true, level: 0.62),
          "processing": VoiceState(phase: .processing, isReady: true),
          "pasted": VoiceState(phase: .pasted, isReady: true),
          "copied": VoiceState(phase: .copied, isReady: true),
          "error": VoiceState(phase: .error, isReady: true, message: "The microphone didn't start."),
          "landed": VoiceState(phase: .pasted, isReady: true),
        ]
        guard let state = states[name] else { return nil }
        return (state, name == "landed" ? Date().addingTimeInterval(2.75) : nil)
      }
    }
  }
#endif
