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
  static let verticalMargin = DesignTokens.Metrics.marginVertical

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
    .background { SurfaceFinish.Ground(surface: model.palette.surface) }
    .overlay { SurfaceFinish.Grain() }
    .clipped()
    .environment(\.keyboardPalette, model.palette)
    .simultaneousGesture(swipe, including: model.layout == .panel ? .all : .subviews)
    .animation(reduceMotion ? nil : .easeInOut(duration: DesignTokens.Motion.flip), value: model.panelShowsKeys)
  }

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }

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
    DragGesture(minimumDistance: DesignTokens.Metrics.gestureSwipeMin)
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
    HStack(spacing: DesignTokens.Metrics.slimSpacing) {
      if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
      VoiceBar(model: model)
      KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() }
      KeyCap(systemImage: "return", dark: true) { model.newline() }
    }
  }
}

/// A big orb, centred, that dissipates into the wave while recording; cancel
/// in the corner while something is in flight; one row of keys. 216 pt.
struct PanelView: View {
  var model: KeyboardModel

  var body: some View {
    VStack(spacing: DesignTokens.Metrics.panelSpacing) {
      Spacer(minLength: 0)
      MicKey(
        model: model, size: DesignTokens.Metrics.orbPanel,
        wave: CGSize(width: DesignTokens.Metrics.wavePanelWidth, height: DesignTokens.Metrics.wavePanelHeight))
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
        KeyCap(systemImage: "xmark", tint: BlurtBrand.errorOrange, bare: true) { model.cancel() }
          .accessibilityLabel("Cancel dictation")
          .transition(.opacity)
      }
    }
    .overlay(alignment: .topLeading) { AddTermKey(model: model).padding(DesignTokens.Metrics.addtermInset) }
  }
}

/// The mic key is the brand orb, and it says everything without a word or a
/// glyph. Finger down starts, finger up decides tap (latched) or hold
/// (push-to-talk) — `KeyboardModel` runs the engine's gate. What it does:
/// dimmed when Blurt isn't ready (no Full Access, or the app isn't listening;
/// the tap opens Blurt); on a tap the ring sweeps as the app's orb does while
/// the mic comes up; then the orb dissipates — swells a little, softens to a
/// haze, is gone — and in its place the voice is a thin wave, flat on the
/// surface, for as long as you talk, and the wave is the key; on the stop
/// the wave fades and the orb condenses back with the ring sweeping while
/// the words come; then a green ring for a moment when they landed (the
/// violet drop with it), a clipboard on a green ring when they went to the
/// clipboard instead, an orange ring and an exclamation mark when something
/// failed. Each also has its haptic.
///
/// Nothing snaps or springs: the orb and the wave cross over `waveFade`,
/// every other change over `stateFade`. Only the press itself answers at
/// once.
struct MicKey: View {
  var model: KeyboardModel
  var size: CGFloat
  /// The wave the orb dissipates into while recording — wide and slim —
  /// or nil for none (the orb stays). The key's frame is the wave's width
  /// throughout, so nothing moves while the two cross; only the circle
  /// answers a touch until the wave is up, then the wave's band does.
  var wave: CGSize?
  @State private var pressed = false
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  @Environment(\.keyboardPalette) private var palette
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }

  /// The orb and the wave crossing, either way.
  static let waveFade = DesignTokens.Motion.waveFade
  /// Every other change on the key: the ring, a glyph, the dimming.
  static let stateFade = DesignTokens.Motion.stateFade

  var body: some View {
    ZStack {
      if let wave, isRecording {
        WaveformMeter(
          level: Float(model.snapshot.level), animated: !reduceMotion, color: palette.signal,
          barWidth: WaveformMeter.slimBar, barSpacing: WaveformMeter.slimGap
        )
        .frame(width: wave.width, height: wave.height)
        .transition(.opacity)
      } else {
        PrismOrb(mood: mood, landedAt: model.resultLandedAt, animated: !reduceMotion)
          .clipShape(Circle())
          .overlay { ring }
          .frame(width: size, height: size)
          .saturation(isReady ? 1 : DesignTokens.Metrics.opacityDimSaturation)
          .opacity(isReady ? 1 : DesignTokens.Metrics.opacityDim)
          .transition(reduceMotion ? .opacity : .dissipate(size: size))
      }
      if let glyph {
        Image(systemName: glyph)
          .font(
            .system(size: size * DesignTokens.Typography.ratioOrbGlyph, weight: DesignTokens.Typography.weightOrbGlyph)
          )
          .foregroundStyle(.white)
          .transition(.opacity)
      }
    }
    .frame(width: wave.map { max($0.width, size) } ?? size, height: size)
    .animation(.easeInOut(duration: Self.waveFade), value: isRecording)
    .animation(.easeInOut(duration: Self.stateFade), value: model.snapshot.state)
    .animation(.easeInOut(duration: Self.stateFade), value: isReady)
    .scaleEffect(pressed ? DesignTokens.Metrics.pressScale : 1)
    .animation(.easeOut(duration: DesignTokens.Motion.press), value: pressed)
    .contentShape(showsWave ? AnyShape(Capsule()) : AnyShape(Circle()))
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
  /// or orange, for a notice; still while recording.
  @ViewBuilder private var ring: some View {
    let width = isWorking || isNotice ? DesignTokens.Metrics.ringActive : DesignTokens.Metrics.ringStill
    if isWorking, !isRecording, !reduceMotion {
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
        Circle()
          .strokeBorder(BlurtBrand.orbRingGradient, lineWidth: width)
          .rotationEffect(
            .degrees(
              MeterBarGeometry.rotationDegrees(
                time: timeline.date.timeIntervalSinceReferenceDate, period: BrandOrb.period)))
      }
    } else if let ringColor {
      Circle().strokeBorder(ringColor, lineWidth: width)
    } else {
      Circle().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: width)
    }
  }

  private var isReady: Bool { model.isReady }
  /// The wave is up, and is the key.
  private var showsWave: Bool { isRecording && wave != nil }

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
/// modifier keys, a step darker as on the system keyboard; `bare` for a glyph
/// with no cap at all (the panel's cancel). `flexible` keys (the space bar)
/// take the width they're given, `width` fixes one, and the rest are 44 wide.
struct KeyCap: View {
  var title: String?
  var systemImage: String?
  var tint: Color?
  var flexible = false
  var dark = false
  var bare = false
  var width: CGFloat?
  var action: () -> Void
  @Environment(\.keyboardPalette) private var palette

  static let height = DesignTokens.Metrics.keyHeight

  init(
    title: String? = nil, systemImage: String? = nil, tint: Color? = nil, flexible: Bool = false,
    dark: Bool = false, bare: Bool = false, width: CGFloat? = nil, action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.flexible = flexible
    self.dark = dark
    self.bare = bare
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
    .font(.system(size: DesignTokens.Typography.sizeLegend, weight: DesignTokens.Typography.weightLegend))
    .foregroundStyle(tint ?? palette.keyText)
    .opacity(DesignTokens.Metrics.opacityLegend)
    .frame(maxWidth: flexible ? .infinity : nil)
    .frame(width: width)
    .frame(minWidth: width == nil ? DesignTokens.Metrics.keyMinWidth : nil, minHeight: Self.height)
    .padding(.horizontal, flexible || width != nil ? 0 : DesignTokens.Metrics.keyPad)
    .keyCap(bare ? .clear : dark ? palette.keyDark : palette.key)
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
      .brightness(pressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
      .animation(.easeOut(duration: DesignTokens.Motion.keyPress), value: pressed)
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
