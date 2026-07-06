import BlurtEngine
import SwiftUI

private enum ReadyBrandPalette {
  static func keycapFill(for colorScheme: ColorScheme) -> Color {
    switch colorScheme {
    case .dark:
      return Color(red: 0.12, green: 0.16, blue: 0.2)
    default:
      return Color(red: 0.965, green: 0.985, blue: 1.0)
    }
  }

  static func keycapStroke(for colorScheme: ColorScheme) -> Color {
    switch colorScheme {
    case .dark:
      return Color(red: 0.38, green: 0.82, blue: 0.96).opacity(0.85)
    default:
      return Color(red: 0.42, green: 0.82, blue: 0.95).opacity(0.4)
    }
  }

  static func settingsButtonFill(for colorScheme: ColorScheme, isHovered: Bool, isPressed: Bool) -> Color {
    guard isHovered || isPressed else { return .clear }

    let opacity = isPressed ? 0.11 : 0.06
    switch colorScheme {
    case .dark:
      return Color.white.opacity(opacity)
    default:
      return Color.black.opacity(opacity)
    }
  }
}

/// The "you're all set" screen shown in the main window once setup is complete.
/// It just states the dictation shortcut and offers a native-feeling link to the
/// Settings window — there's nothing to configure here.
struct ReadyView: View {
  var coordinator: AppCoordinator
  var openSettings: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // Observe the persisted trigger keycode directly so changing the dictation key
  // in the (separate) Settings window re-renders this window's keycap live.
  // `@AppStorage` reflects writes to the same default across windows; reading
  // `TriggerKeyStore` (plain UserDefaults) would not trigger a re-render.
  @AppStorage(TriggerKeyStore.defaultsKey) private var triggerKeyCode: Int =
    TriggerKey.rightCommand.rawValue

  var body: some View {
    VStack(spacing: 18) {
      ReadyBrandingView()
        // The logo PNG carries ~16% transparent margin top & bottom. The top
        // margin gives welcome clearance from the traffic lights; cancel the
        // bottom one so the gap to the text is the VStack spacing, not ~2x it.
        .padding(.bottom, -16)

      if let transcript = coordinator.lastTranscript {
        transcriptReadout(transcript)
      } else {
        shortcutReadout
      }

      Button(action: openSettings) {
        Label("Settings", systemImage: "gearshape")
      }
      .buttonStyle(ReadySettingsButtonStyle())
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 32)
    .padding(.top, 4)
    .padding(.bottom, 26)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: coordinator.lastTranscript)
  }

  /// "Tap or hold ⌘ to blurt", with the key drawn as a rounded keycap.
  private var shortcutReadout: some View {
    HStack(spacing: 6) {
      Text("Tap or hold")
        .foregroundStyle(.secondary)
      KeyCap(label: TriggerKey.fromPersisted(triggerKeyCode).label)
      Text("to blurt")
        .foregroundStyle(.secondary)
    }
    .font(.title3)
  }

  /// The just-dictated text, shown in place of the shortcut readout for a few
  /// seconds after a dictation completes (see `AppCoordinator.lastTranscript`).
  /// Capped at a few lines with tail truncation so a long dictation can't grow
  /// the fixed-width window unboundedly.
  private func transcriptReadout(_ text: String) -> some View {
    Text(text)
      .font(.title3)
      .foregroundStyle(.primary)
      .multilineTextAlignment(.center)
      .lineLimit(4)
      .truncationMode(.tail)
      .transition(.opacity)
      .accessibilityIdentifier("ready.transcript")
      .accessibilityLabel("You dictated: \(text)")
  }
}

private struct ReadyBrandingView: View {
  var body: some View {
    if let brandingURL,
      let image = NSImage(contentsOf: brandingURL)
    {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 280)
        .accessibilityLabel("Blurt logo")
    } else {
      // Fallback if the bundled logo can't be loaded — keep the ready screen's
      // identity (icon + name) rather than rendering an empty, contextless view.
      VStack(spacing: 8) {
        Image(systemName: "mic.fill")
          .font(.system(size: 44))
          .foregroundStyle(.secondary)
        Text("Blurt is ready")
          .font(.title2.weight(.semibold))
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Blurt is ready")
    }
  }

  private var brandingURL: URL? {
    Bundle.main.url(forResource: "blurt-ready-logo", withExtension: "png")
  }
}

/// A single rounded key-cap, e.g. "⌃" or "D".
private struct KeyCap: View {
  var label: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(label)
      .font(.title3.weight(.medium).monospaced())
      .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(ReadyBrandPalette.keycapFill(for: colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(ReadyBrandPalette.keycapStroke(for: colorScheme), lineWidth: 1)
      )
  }
}

private struct ReadySettingsButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ReadySettingsButton(configuration: configuration)
  }
}

private struct ReadySettingsButton: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .font(.subheadline.weight(.medium))
      .labelStyle(.titleAndIcon)
      .symbolRenderingMode(.hierarchical)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            ReadyBrandPalette.settingsButtonFill(
              for: colorScheme,
              isHovered: isHovered,
              isPressed: configuration.isPressed
            )
          )
      )
      .foregroundStyle(.secondary)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .onHover { isHovered = $0 }
  }
}
