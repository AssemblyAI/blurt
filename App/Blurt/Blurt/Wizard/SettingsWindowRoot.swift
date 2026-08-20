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

/// The occasional stuff: the enhanced-transcripts switch, the style profiles,
/// checking for an update, and the developer-mode log toggle.
/// Kept out of General so the common pane stays short.
private struct AdvancedSettingsTab: View {
  let updateModel: UpdateCheckModel

  var body: some View {
    SettingsPane {
      TranscriptionSection()
      StyleProfilesSection()
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

/// The Styles section of the Settings window: up to
/// `StyleProfileStore.profileLimit` named sets of style instructions, the active
/// one of which is appended to the cleanup instruction on every dictation
/// request (see `CleanupInstruction.sendable(appending:)` / `StyleProfileStore`),
/// so the enhanced-transcript polish also applies the user's formatting
/// preferences. Optional — with none defined the request is exactly what ships
/// today. Disabled while enhanced transcripts are off, since the instruction
/// they extend is not sent at all then.
///
/// Each row is a name and a way in: all editing happens in the sheet below, for
/// the reasons on `APIKeyStepView`'s. Which style is *active* is deliberately
/// not set here — the main window's buttons own that (see `ReadyView`), so
/// switching is one click instead of a trip through Settings, and a picker here
/// would be a second control writing the same slot.
private struct StyleProfilesSection: View {
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  /// Bound to observe, not to write: the store owns the JSON encoding, so it
  /// decodes this slot and the sheet writes through it, while `@AppStorage` is
  /// what re-renders these rows when a write lands.
  @AppStorage(StyleProfileStore.defaultsKey) private var rawProfiles = ""

  /// The profile the sheet is editing, or nil while it's closed. Carries the
  /// value rather than an index, so a list that changes underneath can't leave
  /// the sheet pointed at a different profile.
  @State private var editing: StyleProfile?

  private var profiles: [StyleProfile] { StyleProfileStore().profiles(decoding: rawProfiles) }

  var body: some View {
    Section {
      // Enumerated for the accessibility identifier only — identity is the
      // profile's own stable id, so a rename doesn't rebuild the row.
      ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
        SettingRow(title: profile.name, systemImage: "textformat") {
          Button("Edit…") { editing = profile }
            .accessibilityIdentifier(UITestIdentifiers.styleProfileEdit(index))
        }
      }
      // Ellipsis for the same reason as the API-key row's "Connect…": the
      // action needs more input before it completes.
      Button("Add Style…") { editing = StyleProfile(name: "", instructions: "") }
        .disabled(profiles.count >= StyleProfileStore.profileLimit)
        .accessibilityIdentifier(UITestIdentifiers.styleProfileAdd)
    } header: {
      Text("Styles")
    } footer: {
      // The caveat *replaces* the help sentence rather than joining it: with the
      // rewrite switched off there is nothing for a style to apply to, so
      // describing the limit is the less useful half.
      Text(
        enhancedTranscripts
          ? "Up to \(StyleProfileStore.profileLimit) styles."
          : "Style preferences need enhanced transcripts turned on.")
    }
    .disabled(!enhancedTranscripts)
    .sheet(item: $editing) { profile in
      StyleProfileEditorSheet(profile: profile, isExisting: profiles.contains(profile))
    }
  }
}

/// The style-editing task itself, presented as a sheet from the settings row.
///
/// A sheet for the reasons spelled out on `APIKeyEditorSheet`, whose shape this
/// follows: a headline that names the task, full-width fields under their own
/// labels, and that button layout — the destructive action at the leading edge,
/// clear of the Cancel / default-action pair at the trailing edge, with Return
/// and Escape scoped to the sheet. Unlike that one there is nothing to validate
/// against a server, so Save is a plain write; the caps are enforced as you type
/// so text is never silently lost at the boundary.
private struct StyleProfileEditorSheet: View {
  /// The profile being edited — a freshly minted one on the "Add Style…" path.
  let profile: StyleProfile
  /// Whether `profile` is already in the stored list. Drives the Delete button:
  /// a profile that was never saved has nothing to remove, and offering Delete
  /// beside Cancel would be two words for the same outcome.
  let isExisting: Bool

  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var instructions: String
  @FocusState private var nameFocused: Bool

  init(profile: StyleProfile, isExisting: Bool) {
    self.profile = profile
    self.isExisting = isExisting
    _name = State(initialValue: profile.name)
    _instructions = State(initialValue: profile.instructions)
  }

  /// Both fields must say something. A nameless profile would render a blank
  /// button in the main window, and one with no instructions would be a button
  /// that changes nothing about the dictation it is selected for.
  private var canSave: Bool {
    name.trimmedNonEmpty() != nil && instructions.trimmedNonEmpty() != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Custom Style")
          .font(.headline)
        Text("Applied while polishing each dictation — casing, tone, emoji use.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      nameField
      instructionsField
      buttonRow
    }
    .padding(20)
    .frame(width: 420)
    // Naming the style is the first thing to do, and on the Add path the only
    // empty field — so open with the caret already in it.
    .defaultFocus($nameFocused, true)
  }

  /// A real, visible label rather than a placeholder: the prompt disappears the
  /// moment text lands, and this field sits beside a second one, so "which box
  /// is which" has to survive being filled in.
  private var nameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Name")
        .font(.subheadline.weight(.semibold))
      TextField("", text: $name, prompt: Text("e.g. Casual"))
        .lineLimit(1)
        .disableAutocorrection(true)
        .focused($nameFocused)
        .accessibilityLabel("Style name")
        .accessibilityIdentifier(UITestIdentifiers.styleProfileName)
        // Capped because the main window's buttons are a fixed width; counted in
        // characters, which is what that width is a bound on.
        .onChange(of: name) {
          if name.count > StyleProfileStore.nameLimit {
            name = String(name.prefix(StyleProfileStore.nameLimit))
          }
        }
    }
  }

  /// The multi-line instruction field, with the byte counter directly beneath
  /// the field it measures.
  private var instructionsField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Instructions")
        .font(.subheadline.weight(.semibold))
      // A vertical-axis TextField grows with its content up to `lineLimit`, so
      // there's no faked placeholder over a TextEditor.
      TextField(
        text: $instructions,
        prompt: Text("e.g. add fitting emojis sparingly, or always write in lowercase"),
        axis: .vertical
      ) {
        Text("Instructions")
      }
      .labelsHidden()
      .lineLimit(2...6)
      .font(.body)
      .disableAutocorrection(true)
      .accessibilityIdentifier(UITestIdentifiers.styleProfileInstructions)
      .onChange(of: instructions) {
        // The dictation API rejects the whole request over its instruction
        // limit, so text past the cap must never be storable.
        if instructions.utf8.count > StyleProfileStore.characterLimit {
          instructions = instructions.prefix(maxUTF8Bytes: StyleProfileStore.characterLimit)
        }
      }
      // The API caps the instruction, so the room left is finite — show it
      // rather than truncating silently at the limit. Counted in UTF-8 bytes,
      // the unit the limit is enforced in.
      Text("\(instructions.utf8.count)/\(StyleProfileStore.characterLimit)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(
          "\(instructions.utf8.count) of \(StyleProfileStore.characterLimit) characters used")
    }
  }

  private var buttonRow: some View {
    HStack(spacing: 12) {
      if isExisting {
        Button("Delete", role: .destructive, action: delete)
          .accessibilityIdentifier(UITestIdentifiers.styleProfileDelete)
      }
      Spacer(minLength: 12)
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(UITestIdentifiers.styleProfileCancel)
      Button("Save", action: save)
        .glassButtonStyleCompat(prominent: true)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
        .accessibilityIdentifier(UITestIdentifiers.styleProfileSave)
    }
  }

  /// Writes the edit through the store, which owns the encoding and the caps.
  /// Merged against the *stored* list rather than the observed copy, so a change
  /// made in another settings window while this sheet was open isn't clobbered.
  private func save() {
    guard canSave else { return }
    var edited = profile
    edited.name = name
    edited.instructions = instructions
    let store = StyleProfileStore()
    var updated = store.profiles
    if let index = updated.firstIndex(where: { $0.id == edited.id }) {
      updated[index] = edited
    } else {
      updated.append(edited)
    }
    store.profiles = updated
    dismiss()
  }

  /// No confirmation alert: a style is a couple of sentences the user typed, the
  /// button is `.destructive` and out of the way of Save, and nothing else
  /// depends on it — deleting the active one just falls back to the first
  /// remaining profile (see `StyleProfileStore.active`).
  private func delete() {
    let store = StyleProfileStore()
    store.profiles = store.profiles.filter { $0.id != profile.id }
    dismiss()
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
