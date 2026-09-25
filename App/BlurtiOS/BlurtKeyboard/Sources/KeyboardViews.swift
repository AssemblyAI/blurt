import SwiftUI

/// Picks the layout the user chose. All three share `VoiceBar`/`MicKey` and
/// `KeyCap`, and the same model underneath; they differ in how much keyboard
/// surrounds the mic. The surface is Blurt's ink in every appearance — it
/// floats over whichever app the user is typing in, like the Mac pill — at
/// the iPhone keyboard's own spacing.
struct KeyboardRootView: View {
  var model: KeyboardModel

  /// The keyboard's top and bottom margin: the arithmetic in
  /// `KeyboardLayout.height` is built on it and the palette's row gap.
  static let verticalMargin: CGFloat = 8

  var body: some View {
    Group {
      switch model.effectiveLayout {
      case .slimBar: SlimBarView(model: model)
      case .panel:
        PanelView(model: model)
          .id("panel")
          .transition(flip)
      case .full:
        FullKeyboardView(model: model)
          .id(model.layout == .panel ? "panel-keys" : "full")
          .transition(flip)
      }
    }
    .padding(.horizontal, KeyboardPalette.margin)
    .padding(.vertical, Self.verticalMargin)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(model.palette.surface)
    .clipped()
    .environment(\.keyboardPalette, model.palette)
    .simultaneousGesture(swipe, including: model.layout == .panel ? .all : .subviews)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.panelShowsKeys)
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The carousel's slide: the incoming page arrives from the side the finger
  /// moved towards, the outgoing one leaves the other way.
  private var flip: AnyTransition {
    model.flipTowardsLeading
      ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
      : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
  }

  /// A horizontal swipe anywhere on the panel flips it; taps and holds on keys
  /// never travel this far, and the keys ignore a touch that did.
  private var swipe: some Gesture {
    DragGesture(minimumDistance: 24)
      .onEnded { value in
        let dx = value.translation.width
        guard abs(dx) > 48, abs(dx) > abs(value.translation.height) * 1.5 else { return }
        model.flipPanel(towardsLeading: dx < 0)
      }
  }
}

/// One row: the globe, the voice bar, delete and return. 60 pt.
struct SlimBarView: View {
  var model: KeyboardModel

  var body: some View {
    HStack(spacing: 8) {
      if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
      VoiceBar(model: model)
      KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
      KeyCap(systemImage: "return", dark: true) { model.newline() }
    }
  }
}

/// A big orb with cancel beside it while something is in flight, the meter
/// under it while recording, and one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 12) {
      Spacer(minLength: 0)
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
      WaveformMeter(level: Float(model.snapshot.level), animated: !reduceMotion, color: BlurtBrand.greenOnDark)
        .frame(width: 180, height: 24)
        .opacity(model.snapshot.state == .recording ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: model.snapshot.state)
        .accessibilityHidden(true)
      Spacer(minLength: 0)
      HStack(spacing: KeyboardPalette.keyGap) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
        KeyCap(systemImage: "return", dark: true) { model.newline() }
      }
    }
  }
}

/// The mic key is the brand orb, and it says everything without a word.
/// Finger down starts, finger up decides tap (latched) or hold (push-to-talk)
/// — `KeyboardModel` runs the engine's gate. The Mac's orb carries no glyph;
/// here it is a key, so a mic sits on it. Then: dimmed when Blurt isn't ready
/// (no Full Access, or the app isn't listening — the tap opens Blurt); the
/// ring sweeping while connecting and transcribing; a stop glyph, the sweep
/// and a glow with the voice level while recording; a check for a moment
/// after the words landed, a clipboard when they went to the clipboard
/// instead, an orange ring and an exclamation mark when something failed.
/// Each of those also has its haptic.
struct MicKey: View {
  var model: KeyboardModel
  var size: CGFloat
  @State private var pressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let level = CGFloat(model.snapshot.level)
    ZStack {
      BrandOrb(
        diameter: size, animated: isWorking && !reduceMotion, ringWidth: isWorking || isNotice ? 2 : 1,
        ringColor: ringColor
      )
      .saturation(isReady ? 1 : 0.35)
      .opacity(isReady ? 1 : 0.8)
      Image(systemName: glyph)
        .font(.system(size: size * 0.36, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .contentTransition(.symbolEffect(.replace))
    }
    .animation(.easeInOut(duration: 0.15), value: model.snapshot.state)
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
        .onEnded { value in
          pressed = false
          // A finger that swiped across the orb was flipping the panel, not
          // releasing a hold: undo the press instead of ending a dictation.
          if abs(value.translation.width) > 24 || abs(value.translation.height) > 24 {
            model.cancel()
          } else {
            model.micUp()
          }
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

  private var isNotice: Bool {
    switch model.snapshot.state {
    case .pasted, .copied, .error: true
    case .idle, .connecting, .recording, .processing: false
    }
  }

  private var ringColor: Color? {
    switch model.snapshot.state {
    case .error: BlurtBrand.errorOrange
    case .pasted, .copied: BlurtBrand.greenOnDark
    case .idle, .connecting, .recording, .processing: nil
    }
  }

  private var glyph: String {
    guard isReady else { return "mic.fill" }
    switch model.snapshot.state {
    case .recording: return "stop.fill"
    case .pasted: return "checkmark"
    case .copied: return "doc.on.clipboard"
    case .error: return "exclamationmark"
    case .idle, .connecting, .processing: return "mic.fill"
    }
  }
}

/// One ordinary key: a legend on a cap in the current palette; `dark` for the
/// modifier keys, a step darker as on the system keyboard. `flexible` keys
/// (the space bar) take the width they're given, `width` fixes one, and the
/// rest are 44 wide.
struct KeyCap: View {
  var title: String?
  var systemImage: String?
  var tint: Color?
  var flexible = false
  var dark = false
  var width: CGFloat?
  var action: () -> Void
  @Environment(\.keyboardPalette) private var palette

  static let height: CGFloat = 42

  init(
    title: String? = nil, systemImage: String? = nil, tint: Color? = nil, flexible: Bool = false,
    dark: Bool = false, width: CGFloat? = nil, action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.flexible = flexible
    self.dark = dark
    self.width = width
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
      .foregroundStyle(tint ?? palette.keyText)
      .frame(maxWidth: flexible ? .infinity : nil)
      .frame(width: width)
      .frame(minWidth: width == nil ? 44 : nil, minHeight: Self.height)
      .padding(.horizontal, flexible || width != nil ? 0 : 4)
      .keyCap(dark ? palette.keyDark : palette.key, palette: palette)
    }
    .buttonStyle(KeyPressStyle())
  }
}

extension View {
  /// The cap under a key's legend: the palette's fill, the system keyboard's
  /// corner radius and 1 pt drop, and a hairline so the cap reads on ink.
  func keyCap(_ fill: Color, palette: KeyboardPalette) -> some View {
    background {
      RoundedRectangle(cornerRadius: KeyboardPalette.keyRadius)
        .fill(fill)
        .shadow(color: palette.keyShadow, radius: 0, y: 1)
    }
    .overlay {
      RoundedRectangle(cornerRadius: KeyboardPalette.keyRadius).strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    }
  }
}

/// A key lightens while the finger is on it, the way the system's change
/// shade, instead of the default button dimming.
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
