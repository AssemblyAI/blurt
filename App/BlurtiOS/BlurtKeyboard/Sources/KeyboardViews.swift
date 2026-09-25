import BlurtEngine
import SwiftUI

/// Picks the layout the user chose. All three share `VoiceBar`/`MicKey` and
/// `KeyCap`, and the same model underneath; they differ in how much keyboard
/// surrounds the mic. The surface is the theme's, fixed whatever the host
/// app's appearance — the keyboard floats over whichever app the user is
/// typing in, like the Mac pill — at the iPhone keyboard's own spacing.
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

/// A big orb, centred, that grows into the wave while recording; cancel in
/// the corner while something is in flight; one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel

  var body: some View {
    VStack(spacing: 12) {
      Spacer(minLength: 0)
      MicKey(model: model, size: 96, expandedWidth: 260)
      Spacer(minLength: 0)
      HStack(spacing: KeyboardPalette.keyGap) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
        KeyCap(systemImage: "return", dark: true) { model.newline() }
      }
    }
    .overlay(alignment: .topTrailing) {
      if !model.isSettled {
        KeyCap(systemImage: "xmark", tint: BlurtBrand.errorOrange, dark: true) { model.cancel() }
          .accessibilityLabel("Cancel dictation")
      }
    }
    .overlay(alignment: .topLeading) { AddTermKey(model: model).padding(6) }
  }
}

/// The mic key is the brand orb, and it says everything without a word or a
/// glyph. Finger down starts, finger up decides tap (latched) or hold
/// (push-to-talk) — `KeyboardModel` runs the engine's gate. What it does:
/// dimmed when Blurt isn't ready (no Full Access, or the app isn't listening;
/// the tap opens Blurt); on a tap the ring sweeps as the app's orb does while
/// the mic comes up; then the orb grows sideways into a capsule holding the
/// live wave for as long as you talk, glowing with your voice; on the stop it
/// shrinks back to the circle with the ring sweeping while the words come;
/// then a green ring for a moment when they landed, a clipboard on a green
/// ring when they went to the clipboard instead, an orange ring and an
/// exclamation mark when something failed. Each also has its haptic.
struct MicKey: View {
  var model: KeyboardModel
  var size: CGFloat
  /// How wide the orb grows while recording, to hold the wave.
  var expandedWidth: CGFloat
  @State private var pressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let level = CGFloat(model.snapshot.level)
    let width = isRecording ? expandedWidth : size
    ZStack {
      PrismOrb(mood: mood, landedAt: model.resultLandedAt, animated: !reduceMotion)
        .clipShape(Capsule())
        .overlay { ring }
        .saturation(isReady ? 1 : 0.35)
        .opacity(isReady ? 1 : 0.8)
      if isRecording {
        WaveformMeter(level: Float(model.snapshot.level), animated: !reduceMotion, color: .white.opacity(0.92))
          .frame(width: expandedWidth - size * 0.7, height: size * 0.5)
          .transition(.opacity)
      }
      if let glyph {
        Image(systemName: glyph)
          .font(.system(size: size * 0.34, weight: .semibold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .transition(.opacity)
      }
    }
    .frame(width: width, height: size)
    .shadow(
      color: BlurtBrand.greenOnDark.opacity(isRecording ? 0.35 + 0.45 * level : 0),
      radius: isRecording ? size * 0.1 + level * size * 0.25 : 0
    )
    .animation(.easeOut(duration: 0.08), value: level)
    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15), value: isRecording)
    .animation(.easeInOut(duration: 0.15), value: model.snapshot.state)
    .scaleEffect(pressed ? 0.94 : 1)
    .animation(.easeOut(duration: 0.1), value: pressed)
    .contentShape(Capsule())
    .accessibilityLabel(isReady ? (isRecording ? "Stop dictation" : "Dictate") : "Start Blurt")
    .accessibilityValue(model.snapshot.state == .error ? model.snapshot.message ?? "Dictation failed." : "")
    .accessibilityAddTraits(.isButton)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          if !pressed {
            pressed = true
            // The press waits a beat, so a swipe that starts on the orb (the
            // panel's carousel) never starts a dictation it must then cancel.
            pressTask = Task { [model] in
              try? await Task.sleep(for: Self.pressDelay)
              guard !Task.isCancelled else { return }
              pressSent = true
              model.micDown()
            }
          }
          if Self.travelled(value), !pressSent {
            pressTask?.cancel()
            pressTask = nil
          }
        }
        .onEnded { value in
          pressed = false
          pressTask?.cancel()
          pressTask = nil
          defer { pressSent = false }
          if Self.travelled(value) {
            // A swipe: undo a press that did go out, otherwise nothing.
            if pressSent { model.cancel() }
            return
          }
          // A tap quicker than the delay is still a tap.
          if !pressSent { model.micDown() }
          model.micUp()
        }
    )
  }

  /// How long a touch must stay before it counts as a press rather than the
  /// start of a swipe — well under a tap's own duration for a hold.
  static let pressDelay: Duration = .milliseconds(90)
  @State private var pressTask: Task<Void, Never>?
  @State private var pressSent = false

  private static func travelled(_ value: DragGesture.Value) -> Bool {
    abs(value.translation.width) > 24 || abs(value.translation.height) > 24
  }

  /// The ring: the app orb's sweep (one turn per 1.6 s, engine geometry)
  /// while the mic comes up and while the words come; still, and solid green
  /// or orange, for a notice; still on the capsule while recording.
  @ViewBuilder private var ring: some View {
    let width: CGFloat = isWorking || isNotice ? 2 : 1
    if isWorking, !isRecording, !reduceMotion {
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
        Capsule()
          .strokeBorder(BlurtBrand.orbRingGradient, lineWidth: width)
          .rotationEffect(
            .degrees(
              MeterBarGeometry.rotationDegrees(
                time: timeline.date.timeIntervalSinceReferenceDate, period: BrandOrb.period)))
      }
    } else if let ringColor {
      Capsule().strokeBorder(ringColor, lineWidth: width)
    } else {
      Capsule().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: width)
    }
  }

  private var isReady: Bool { model.isReady }

  /// The orb's story from the phase: green, greener with the voice; the
  /// violet drop is keyed to the moment the words landed, not to a phase.
  private var mood: PrismOrb.Mood {
    guard isReady else { return .off }
    switch model.snapshot.state {
    case .idle, .error, .pasted, .copied: return .idle
    case .connecting: return .listening(level: 0)
    case .recording: return .listening(level: Float(model.snapshot.level))
    case .processing: return .working
    }
  }
  private var isRecording: Bool { isReady && model.snapshot.state == .recording }
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

  /// Only the two notices that need saying carry a glyph.
  private var glyph: String? {
    guard isReady else { return nil }
    switch model.snapshot.state {
    case .copied: return "doc.on.clipboard"
    case .error: return "exclamationmark"
    case .idle, .connecting, .recording, .processing, .pasted: return nil
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
    .keyPress(action)
    .accessibilityLabel(title ?? systemImage ?? "")
  }
}

extension View {
  /// A key's touch: lights while the finger is down, acts on release — and
  /// only if the finger didn't travel, so a swipe across a key (the panel's
  /// carousel) never types. The system keyboard's own rule.
  func keyPress(_ action: @escaping () -> Void) -> some View {
    modifier(KeyPress(action: action))
  }
}

struct KeyPress: ViewModifier {
  let action: () -> Void
  @State private var pressed = false

  /// The most a touch may travel and still be a tap.
  static let tapTravel: CGFloat = 12

  func body(content: Content) -> some View {
    content
      .brightness(pressed ? 0.15 : 0)
      .animation(.easeOut(duration: 0.08), value: pressed)
      .contentShape(Rectangle())
      .accessibilityAddTraits(.isButton)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in pressed = true }
          .onEnded { value in
            pressed = false
            guard abs(value.translation.width) < Self.tapTravel, abs(value.translation.height) < Self.tapTravel
            else { return }
            action()
          }
      )
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
