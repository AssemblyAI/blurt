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

// Scene support for Blurt's two windows.
//
// Neither window is a hand-rolled `NSWindow` (that's why this file no longer
// defines a window *controller*): both are SwiftUI `Window` scenes declared in
// `BlurtApp`, opened with the public `openWindow` action. These types are the
// glue between those scenes and the long-lived models the app delegate owns.
//
// - Main window (`MainWindow`): the primary window. While the app isn't fully
//   configured it shows the setup wizard; once it is, it shows `ReadyView` (the
//   shortcut readout). Auto-presented at launch only on first run.
// - Settings window (`SettingsWindow`): change the API key or dictation
//   shortcut. Opened via ⌘, and the ready screen's "Settings…" link.

// MARK: - Main window (wizard / ready)

enum MainWindow {
  /// Scene identifier for `openWindow(id:)` / the `Window(id:)` scene.
  static let id = "main"
}

enum SettingsWindow {
  static let id = "settings"
}

/// Root view of the main `Window` scene. It pulls the long-lived models off the
/// app delegate (created at launch, before any window appears) and routes between
/// the setup wizard (when the app isn't ready) and the ready screen (when it is).
struct MainWindowRoot: View {
  var appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if let controller = appDelegate.wizardController, let coordinator = appDelegate.coordinator {
      Group {
        if controller.isReady {
          ReadyView(openSettings: { openWindow(id: SettingsWindow.id) })
        } else {
          WizardView(controller: controller, coordinator: coordinator)
        }
      }
      .onAppear {
        // Permission polling runs for the app's whole life (started in the
        // controller's init), so the window only needs to refresh once on
        // appear to reflect any change made while it was closed. (The
        // `openWindowByID` opener is captured once, by `SettingsMenuButton` —
        // the launch-evaluated command view — not re-assigned here.)
        controller.refreshPermissions()
        // Now that the window is actually on screen, pull the app frontmost —
        // see `activateAtLaunchIfNeeded`. Done here rather than at launch-finish
        // because the window doesn't exist yet then.
        appDelegate.activateAtLaunchIfNeeded()
      }
      // Welcome-window chrome: the wizard and ready screen are splash-style
      // surfaces, not document/preferences windows, so hide the titlebar while
      // keeping the traffic lights. The Settings window keeps standard chrome.
      .chromeLightWindow()
      // Tag the window so `surfaceMainWindow()` can find and raise this exact
      // window (the menu bar's "Open Blurt" needs to deminiaturize/front it when
      // the app is already running).
      .windowIdentifier(MainWindow.id)
    } else {
      // Defensive only: `applicationDidFinishLaunching` creates the models
      // before the run loop presents any scene, so this branch shouldn't show.
      Color.clear.frame(width: 480, height: 320)
    }
  }
}

/// The "you're all set" screen shown in the main window once setup is complete.
/// It just states the dictation shortcut and offers a native-feeling link to the
/// Settings window — there's nothing to configure here.
struct ReadyView: View {
  var openSettings: () -> Void
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

      shortcutReadout

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

// MARK: - Settings window

/// Root view of the Settings `Window` scene: change the AssemblyAI API key or
/// the dictation shortcut. Reuses the same section views the wizard's setup step
/// uses, so the two stay in sync.
struct SettingsWindowRoot: View {
  var appDelegate: AppDelegate

  var body: some View {
    if let coordinator = appDelegate.coordinator {
      Form {
        APIKeyStepView(coordinator: coordinator)
        HotkeyStepView(coordinator: coordinator)
        SoundStepView(coordinator: coordinator)
        KeyTermsStepView()
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .frame(width: 480)
      .fixedSize(horizontal: false, vertical: true)
    } else {
      Color.clear.frame(width: 480, height: 240)
    }
  }
}

// MARK: - App-menu commands

/// App-menu commands. ⌘, opens the Settings window via the public `openWindow`
/// action — no custom window plumbing to manage. `CommandGroup` content is a
/// `@ViewBuilder`, so the `openWindow` action is read by a small menu *view*
/// (which receives the scene environment) rather than the `Commands` type itself.
struct BlurtCommands: Commands {
  var appDelegate: AppDelegate

  var body: some Commands {
    // Standard ⌘, entry point. Replaces the default Settings… item (there's no
    // SwiftUI `Settings` scene — that scene can't be opened with `openWindow`,
    // and we need the same opener for the ready screen's link).
    CommandGroup(replacing: .appSettings) {
      SettingsMenuButton(appDelegate: appDelegate)
    }
    // Updates are silent and automatic (checked at launch, installed without a
    // prompt — see `AutoUpdater`), so there is no "Check for Updates…" command.
    // Blurt ships no help book, so SwiftUI's default Help menu would show a
    // dead "Blurt Help" item that opens nothing. Remove it rather than leave
    // a control that does nothing.
    CommandGroup(replacing: .help) {}
  }
}

private struct SettingsMenuButton: View {
  var appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // Capture the open action at launch so a Dock click can reopen a window
    // even on a configured launch where one is never shown. Command views are
    // evaluated at launch (that's how ⌘, registers before any menu is opened),
    // so this is a reliable, idempotent capture point — and the ONLY one:
    // `openWindow(id:)` opens any Window scene regardless of which scene's
    // environment supplied the action, so the window roots don't re-capture it.
    appDelegate.openWindowByID = { openWindow(id: $0) }
    return Button("Settings…") {
      openWindow(id: SettingsWindow.id)
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}
