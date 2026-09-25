import SwiftUI

/// Picks the layout the user chose. All three share `StatusPill`, `MicKey` and
/// `KeyCap`, and the same model underneath; they differ in how much keyboard
/// surrounds the mic. The surface is the brand ink in every appearance, for the
/// reason the Mac pill is: it floats over whichever app the user is typing in.
struct KeyboardRootView: View {
  var model: KeyboardModel

  /// The keyboard's outer margin and the gap between rows: the arithmetic in
  /// `KeyboardLayout.height` is built on these.
  static let margin: CGFloat = 8
  static let rowGap: CGFloat = 8

  var body: some View {
    Group {
      switch model.layout {
      case .slimBar: SlimBarView(model: model)
      case .panel: PanelView(model: model)
      case .full: FullKeyboardView(model: model)
      }
    }
    .padding(Self.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(BlurtBrand.ink)
  }
}

/// One row: the globe, the pill, the mic, delete and return. 60 pt.
struct SlimBarView: View {
  var model: KeyboardModel

  var body: some View {
    HStack(spacing: 8) {
      if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
      StatusPill(model: model, compact: true)
      MicKey(model: model, size: 44)
      KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
      KeyCap(systemImage: "return", dark: true) { model.newline() }
    }
  }
}

/// The pill, a big mic with cancel beside it while something is in flight,
/// and one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel

  var body: some View {
    VStack(spacing: 12) {
      StatusPill(model: model)
        .frame(maxWidth: 260)
      ZStack {
        MicKey(model: model, size: 96)
        if !model.isSettledState {
          // Beside the orb, a hand's width off centre, rather than at the edge.
          KeyCap(systemImage: "xmark", tint: BlurtBrand.errorOrange, dark: true) { model.cancel() }
            .accessibilityLabel("Cancel dictation")
            .offset(x: 96)
        }
      }
      .frame(height: 96)
      HStack(spacing: 8) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
        KeyCap(systemImage: "return", dark: true) { model.newline() }
      }
    }
  }
}

/// The mic key is the brand orb. Finger down starts, finger up decides tap
/// (latched) or hold (push-to-talk) — `KeyboardModel` runs the engine's gate.
/// The Mac's orb carries no glyph; here it is a key, so a mic sits on it, and
/// while recording the ring sweeps and the disc glows with the voice level.
/// When the app isn't listening the orb sits dimmed and the tap opens Blurt.
struct MicKey: View {
  var model: KeyboardModel
  var size: CGFloat
  @State private var pressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let level = CGFloat(model.snapshot.level)
    ZStack {
      BrandOrb(diameter: size, animated: isWorking && !reduceMotion, ringWidth: isWorking ? 2 : 1)
        .saturation(isReady ? 1 : 0.35)
        .opacity(isReady ? 1 : 0.8)
      Image(systemName: glyph)
        .font(.system(size: size * 0.36, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
    .frame(width: size, height: size)
    .shadow(
      color: BlurtBrand.greenOnDark.opacity(isRecording ? 0.35 + 0.45 * level : 0),
      radius: isRecording ? size * 0.1 + level * size * 0.25 : 0
    )
    .animation(.easeOut(duration: 0.08), value: level)
    .scaleEffect(pressed ? 0.94 : 1)
    .animation(.easeOut(duration: 0.1), value: pressed)
    .contentShape(Circle())
    .accessibilityLabel(isReady ? (isRecording ? "Stop dictation" : "Dictate") : "Start Blurt")
    .accessibilityAddTraits(.isButton)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !pressed else { return }
          pressed = true
          model.micDown()
        }
        .onEnded { _ in
          pressed = false
          model.micUp()
        }
    )
  }

  private var isReady: Bool { model.hasFullAccess && model.isListening }
  private var isRecording: Bool { model.snapshot.state == .recording }
  private var isWorking: Bool {
    switch model.snapshot.state {
    case .connecting, .recording, .processing: isReady
    case .idle, .pasted, .copied, .error: false
    }
  }

  private var glyph: String { isRecording ? "stop.fill" : "mic.fill" }
}

/// One ordinary key: a warm-white legend on a raised ink cap; `dark` for the
/// modifier keys, a step darker as on the system keyboard. `flexible` keys (the
/// space bar) take the width they're given; the rest are 44 wide.
struct KeyCap: View {
  var title: String?
  var systemImage: String?
  var tint: Color = BlurtBrand.keyText
  var flexible = false
  var dark = false
  var action: () -> Void

  static let height: CGFloat = 42
  static let cornerRadius: CGFloat = 6

  init(
    title: String? = nil, systemImage: String? = nil, tint: Color = BlurtBrand.keyText, flexible: Bool = false,
    dark: Bool = false, action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.flexible = flexible
    self.dark = dark
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Group {
        if let systemImage {
          Image(systemName: systemImage)
        } else {
          Text(title ?? "")
        }
      }
      .font(.system(size: 16, weight: .medium))
      .foregroundStyle(tint)
      .frame(maxWidth: flexible ? .infinity : nil)
      .frame(minWidth: 44, minHeight: Self.height)
      .padding(.horizontal, flexible ? 0 : 4)
      .background(dark ? BlurtBrand.keyDark : BlurtBrand.key, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
      .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
    .buttonStyle(KeyPressStyle())
  }
}

/// A key lightens while the finger is on it, the way the system's do, instead
/// of the default button dimming.
struct KeyPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed ? 0.15 : 0)
      .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
  }
}

extension KeyboardModel {
  /// Whether nothing is in flight, for the views that hide the cancel key.
  var isSettledState: Bool {
    switch snapshot.state {
    case .idle, .pasted, .copied, .error: true
    case .connecting, .recording, .processing: false
    }
  }
}
