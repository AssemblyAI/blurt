import SwiftUI

/// Picks the layout the user chose. All three share `MicKey`, `StatusPill` and
/// the same model underneath; they differ in how much keyboard surrounds the mic.
struct KeyboardRootView: View {
  var model: KeyboardModel

  var body: some View {
    Group {
      switch model.layout {
      case .slimBar: SlimBarView(model: model)
      case .panel: PanelView(model: model)
      case .full: FullKeyboardView(model: model)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemGroupedBackground))
  }
}

/// A slim strip: the mic, delete, return and the globe.
struct SlimBarView: View {
  var model: KeyboardModel

  var body: some View {
    HStack(spacing: 8) {
      if model.needsGlobe { KeyCap(systemImage: "globe") { model.globe() } }
      StatusPill(model: model)
      MicKey(model: model, size: 48)
      KeyCap(systemImage: "delete.left") { model.deleteBackward() }
      KeyCap(systemImage: "return") { model.newline() }
    }
  }
}

/// A mic panel: big mic, the status pill, cancel, and a row of keys.
struct PanelView: View {
  var model: KeyboardModel

  var body: some View {
    VStack(spacing: 10) {
      StatusPill(model: model)
      HStack(spacing: 24) {
        Spacer()
        MicKey(model: model, size: 84)
        if !model.isSettledState {
          KeyCap(systemImage: "xmark", tint: BlurtBrand.errorOrange) { model.cancel() }
        }
        Spacer()
      }
      HStack(spacing: 8) {
        if model.needsGlobe { KeyCap(systemImage: "globe") { model.globe() } }
        KeyCap(title: "space", flexible: true) { model.space() }
        KeyCap(systemImage: "delete.left") { model.deleteBackward() }
        KeyCap(systemImage: "return") { model.newline() }
      }
    }
  }
}

/// The phase line: what the app is doing, with a live meter while it records.
struct StatusPill: View {
  var model: KeyboardModel

  var body: some View {
    HStack(spacing: 8) {
      if model.snapshot.state == .recording {
        MeterBars(level: model.snapshot.level)
      }
      Text(text)
        .font(.footnote.weight(.medium))
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(BlurtBrand.ink, in: Capsule())
  }

  private var text: String {
    guard model.hasFullAccess else { return "Allow Full Access for Blurt in Settings → Keyboards" }
    guard model.isListening else { return "Tap the mic to start Blurt" }
    switch model.snapshot.state {
    case .idle: return "Tap to talk, or hold to talk"
    case .connecting: return "Connecting…"
    case .recording: return "Listening…"
    case .processing: return "Transcribing…"
    case .pasted: return "Pasted"
    case .copied: return "Copied"
    case .error: return model.snapshot.message ?? "Something went wrong"
    }
  }

  private var tint: Color {
    model.snapshot.state == .error ? BlurtBrand.errorOrange : BlurtBrand.greenOnDark
  }
}

/// A handful of bars that follow the microphone level.
struct MeterBars: View {
  let level: Double

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<5, id: \.self) { index in
        Capsule()
          .fill(BlurtBrand.greenOnDark)
          .frame(width: 3, height: 4 + 12 * CGFloat(max(0, level - Double(index) * 0.15)))
      }
    }
    .frame(height: 16)
    .animation(.easeOut(duration: 0.08), value: level)
  }
}

/// The mic. Finger down starts, finger up decides tap (latched) or hold
/// (push-to-talk) — `KeyboardModel` runs the engine's gate. When the app isn't
/// listening the key reads "Start" and opens the app instead.
struct MicKey: View {
  var model: KeyboardModel
  var size: CGFloat
  @State private var pressed = false

  var body: some View {
    ZStack {
      Circle().fill(fill)
      if model.snapshot.state == .recording {
        Circle().strokeBorder(BlurtBrand.greenOnDark, lineWidth: 3).scaleEffect(1.12)
      }
      Image(systemName: model.isListening || !model.hasFullAccess ? "mic.fill" : "play.fill")
        .font(.system(size: size * 0.42, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
    .scaleEffect(pressed ? 0.94 : 1)
    .animation(.easeOut(duration: 0.1), value: pressed)
    .accessibilityLabel(model.isListening ? "Dictate" : "Start Blurt")
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

  private var fill: Color {
    switch model.snapshot.state {
    case .recording: BlurtBrand.errorOrange
    case .connecting, .processing: BlurtBrand.ink
    case .idle, .pasted, .copied, .error: BlurtBrand.green
    }
  }
}

/// One ordinary key. `flexible` keys (the space bar) take the width they're
/// given; the rest are square.
struct KeyCap: View {
  var title: String?
  var systemImage: String?
  var tint: Color = .primary
  var flexible = false
  var action: () -> Void

  init(
    title: String? = nil, systemImage: String? = nil, tint: Color = .primary, flexible: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.flexible = flexible
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
      .font(.system(size: 17, weight: .medium))
      .foregroundStyle(tint)
      .frame(maxWidth: flexible ? .infinity : 44, minHeight: 40)
      .frame(minWidth: 44)
      .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
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
