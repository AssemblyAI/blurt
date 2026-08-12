import BlurtEngine
import SwiftUI

/// Root view of the `Settings` scene. A `TabView` at the root of a `Settings`
/// scene renders as the standard macOS preferences window — a segmented toolbar
/// of panes (General / Advanced), each sized to its own content. This is the
/// HIG-native answer to a settings screen that outgrows one pane: keeping every
/// pane short means the window never has to grow past a small display (a single
/// stacked `Form` did, stranding the bottom section off-screen). Each pane
/// reuses the same section views the wizard's setup step uses, so the two stay
/// in sync.
struct SettingsWindowRoot: View {
  var appDelegate: AppDelegate

  private enum Tab: Hashable { case general, advanced }

  /// Drives the selected pane from `@State` (not the OS's persisted preference
  /// tab), so the window always opens on General. Without an explicit binding
  /// macOS restores the last-used pane across launches, which retitles the
  /// window ("General" → "Advanced") and made the settings window unfindable in
  /// UI tests from one run to the next.
  @State private var tab: Tab = .general

  var body: some View {
    if let coordinator = appDelegate.coordinator {
      TabView(selection: $tab) {
        GeneralSettingsTab(coordinator: coordinator)
          .tabItem { Label(UITestIdentifiers.generalSettingsTab, systemImage: "gearshape") }
          .tag(Tab.general)
        AdvancedSettingsTab(updateModel: appDelegate.updateCheckModel)
          .tabItem { Label(UITestIdentifiers.advancedSettingsTab, systemImage: "gearshape.2") }
          .tag(Tab.advanced)
      }
      .frame(width: MainWindow.contentWidth)
    } else {
      Color.clear.frame(width: MainWindow.contentWidth, height: 240)
    }
  }
}

/// The chrome every settings pane shares: a grouped, non-scrolling `Form` that
/// hugs its content, so each pane sizes the window to exactly its sections and
/// the panes can't drift apart in layout.
private struct SettingsPane<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The everyday setup a user changes: the AssemblyAI key, the dictation
/// shortcut, the cue sound, and the transcription key terms.
private struct GeneralSettingsTab: View {
  let coordinator: AppCoordinator

  var body: some View {
    SettingsPane {
      APIKeyStepView(apiKey: coordinator.apiKey)
      HotkeyStepView(coordinator: coordinator)
      SoundStepView(coordinator: coordinator)
      KeyTermsStepView()
    }
  }
}

/// The occasional stuff: the enhanced-transcripts switch, the custom style
/// instructions, checking for an update, and the developer-mode log toggle.
/// Kept out of General so the common pane stays short.
private struct AdvancedSettingsTab: View {
  let updateModel: UpdateCheckModel

  var body: some View {
    SettingsPane {
      TranscriptionSection()
      CustomStyleSection()
      UpdateSection(model: updateModel)
      DeveloperSection()
    }
  }
}

/// The Transcription section of the Settings window: the enhanced-transcripts
/// switch. While on (the default), every dictation request asks AssemblyAI's
/// dictation API for its server-side cleanup rewrite, so the pasted text is
/// the polished version; turned off, the request omits the rewrite and the
/// verbatim transcript is pasted exactly as spoken. The transcriber reads the
/// same default this toggle writes at every request, so a change applies to
/// the next dictation. Settings-only — not a wizard step, since it never
/// gates setup.
private struct TranscriptionSection: View {
  // The unset default comes from the store, not a literal here: the transcriber
  // reads the same slot per request, and two spellings of "unset means on" would let
  // the toggle and the request disagree about an untouched install.
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  var body: some View {
    Section {
      Toggle(isOn: $enhancedTranscripts) {
        Label("Enhanced transcripts", systemImage: "wand.and.stars")
      }
      .accessibilityIdentifier(UITestIdentifiers.enhancedTranscriptsToggle)
    } header: {
      Text("Transcription")
    } footer: {
      Text(
        "Polishes each dictation before pasting — removing filler words and fixing punctuation. "
          + "Turn off to paste your words exactly as spoken.")
    }
  }
}

/// The Custom Style section of the Settings window: free-text style
/// instructions appended to the cleanup instruction on every dictation request
/// (see `CleanupInstruction.sendable(appending:)` / `CustomStyleStore`), so the
/// enhanced-transcript polish also applies the user's formatting preferences.
/// Optional — empty means the request is exactly what ships today. Disabled
/// while enhanced transcripts are off, since the instruction it extends is not
/// sent at all then.
private struct CustomStyleSection: View {
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  /// `@AppStorage` is the only writer of this slot (the store exposes no
  /// setter); trimming lives on the read side (`CustomStyleStore.instructions`)
  /// for the reasons on `KeyTermsStepView.text`. The length cap is enforced
  /// here, though: the dictation API rejects the whole request over its
  /// instruction limit, so text past `characterLimit` must never be storable.
  @AppStorage(CustomStyleStore.defaultsKey) private var text = ""

  var body: some View {
    Section {
      TextField(
        text: $text,
        prompt: Text("e.g. add fitting emojis sparingly, or always write in lowercase"),
        axis: .vertical
      ) {
        Text("Custom Style")
      }
      .labelsHidden()
      .lineLimit(2...6)
      .font(.body)
      .disableAutocorrection(true)
      .accessibilityIdentifier(UITestIdentifiers.customStyleField)
      .onChange(of: text) {
        if text.utf8.count > CustomStyleStore.characterLimit {
          text = text.prefix(maxUTF8Bytes: CustomStyleStore.characterLimit)
        }
      }
      .disabled(!enhancedTranscripts)
    } header: {
      Text("Custom Style")
    } footer: {
      HStack(alignment: .top) {
        Text(
          enhancedTranscripts
            ? "Style preferences applied when polishing each dictation — casing, tone, emoji use."
            : "Style preferences need enhanced transcripts turned on.")
        if enhancedTranscripts {
          Spacer()
          // The API caps the combined instruction, so the room left is finite —
          // show it rather than truncating silently at the limit. Counted in
          // UTF-8 bytes, the unit the limit is enforced in.
          Text("\(text.utf8.count)/\(CustomStyleStore.characterLimit)")
            .monospacedDigit()
            .accessibilityLabel(
              "\(text.utf8.count) of \(CustomStyleStore.characterLimit) characters used")
        }
      }
    }
  }
}

/// The Updates section of the Settings window: the running version and a
/// "Check for Updates" button that runs the check and reports the result in a
/// modal (see `UpdateCheckModel`). The same check is reachable from the
/// "Check for Updates…" app-menu command and the menu-bar item; all three share
/// the one `UpdateCheckModel` owned by `AppDelegate`, so a check from any place
/// runs through the same controller.
private struct UpdateSection: View {
  let model: UpdateCheckModel

  var body: some View {
    Section {
      // "Blurt 0.1.31" — the label is the engine's (shared with the result
      // alerts, so the two can't name the version differently).
      SettingRow(title: model.versionLabel, systemImage: "arrow.triangle.2.circlepath") {
        HStack(spacing: 8) {
          // A user-initiated check that can stall on a slow connection needs
          // visible progress, or the button reads as dead until the result
          // alert lands. Show a spinner and disable the button while in flight
          // (the model already ignores a second check) — the native equivalent
          // of Sparkle's "Checking for updates…".
          if model.isChecking {
            ProgressView().controlSize(.small)
          }
          Button("Check for Updates") { model.checkForUpdates() }
            .disabled(model.isChecking)
            .accessibilityIdentifier(UITestIdentifiers.updateCheck)
        }
      }
    } header: {
      Text("Updates")
    }
  }
}
