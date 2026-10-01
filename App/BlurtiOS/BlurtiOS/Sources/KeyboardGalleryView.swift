#if DEBUG
  import SwiftUI

  /// Every keyboard layout in every state, rendered inside the app: the design
  /// reference, and the way a screenshot of the keyboard is taken without
  /// tapping through Notes. Debug builds only, reached by launch argument:
  ///
  ///     -BlurtGallery <slimBar|panel|full> <state>[,<state>…] [theme]
  ///
  /// The last word is a theme id (`system`, `system-dark`, `ink`, `paper`,
  /// `lavender`, `mint`, `midnight`, `sunset`); the iPhone's light face when
  /// left out.
  /// where a state is `off` (no Full Access), `start` (app not listening),
  /// `idle`, `connecting`, `recording`, `processing`, `pasted`, `copied` or
  /// `error`. `scripts/ios-sim.sh` passes `BLURT_LAUNCH_ARGS` through, so
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

    let rows: [Row]

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 4) {
              Text(row.caption).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal)
              KeyboardRootView(model: row.model)
                .frame(height: row.model.effectiveLayout.height)
                .clipped()
            }
          }
        }
        .padding(.vertical, 12)
      }
      .background(Color(uiColor: .systemBackground))
    }

    /// The rows named by the launch arguments; empty when they don't ask for
    /// the gallery at all.
    static func rows(from arguments: [String]) -> [Row] {
      guard let flag = arguments.firstIndex(of: "-BlurtGallery"), arguments.count > flag + 2,
        let layout = KeyboardLayout(rawValue: arguments[flag + 1])
      else { return [] }
      let theme = arguments.count > flag + 3 ? arguments[flag + 3] : "system"
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
  }
#endif
