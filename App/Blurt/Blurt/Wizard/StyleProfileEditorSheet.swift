import BlurtEngine
import SwiftUI

/// The style-editing task itself, presented as a sheet from the settings row.
///
/// A sheet for the reasons spelled out on `APIKeyEditorSheet`, whose shape this
/// follows: a headline that names the task, full-width fields under their own
/// labels, and that button layout — the destructive action at the leading edge,
/// clear of the Cancel / default-action pair at the trailing edge, with Return
/// and Escape scoped to the sheet. Unlike that one there is nothing to validate
/// against a server, so Save is a plain write; the caps are enforced as you type
/// so text is never silently lost at the boundary.
struct StyleProfileEditorSheet: View {
  /// The profile being edited — a freshly minted one on the "Add Style…" path.
  let profile: StyleProfile
  /// Whether `profile` is already in the stored list. Drives the Delete button:
  /// a profile that was never saved has nothing to remove, and offering Delete
  /// beside Cancel would be two words for the same outcome.
  let isExisting: Bool

  @Environment(\.dismiss)
  private var dismiss

  @State private var name: String
  @State private var instructions: String
  @FocusState private var nameFocused: Bool

  /// Both fields must say something. A nameless profile would render a blank
  /// segment in the main window's switcher, and one with no instructions would
  /// be a segment that changes nothing about the dictation it selects.
  private var canSave: Bool {
    StyleProfile.canSave(name: name, instructions: instructions)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(isExisting ? "Edit Style" : "Add Style")
          .font(.headline)
        Text("Choose a name and describe the tone and formatting you want.")
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
        // Capped because the name labels a segment of the main window's
        // switcher; counted in characters, which is what that width bounds.
        .onChange(of: name) {
          let clamped = StyleProfileStore.clampedName(name)
          if clamped != name { name = clamped }
        }
    }
  }

  /// The multi-line instruction field, with its limit usage beneath it.
  private var instructionsField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Instructions")
        .font(.subheadline.weight(.semibold))
      // A vertical-axis TextField grows with its content up to `lineLimit`, so
      // there's no faked placeholder over a TextEditor.
      TextField(
        text: $instructions,
        prompt: Text("Use a casual tone, write in lowercase, and add emojis sparingly."),
        axis: .vertical
      ) {
        Text("Instructions")
      }
      .labelsHidden()
      .lineLimit(3...6)
      .font(.body)
      .disableAutocorrection(true)
      .accessibilityIdentifier(UITestIdentifiers.styleProfileInstructions)
      .onChange(of: instructions) {
        // Held to the per-profile limit the engine trims to as well, so what is
        // stored is what is sent.
        let clamped = StyleProfileStore.clampedInstructions(instructions)
        if clamped != instructions { instructions = clamped }
      }
      // The room is finite (`StyleProfileStore.characterLimit`) — show it rather
      // than truncating silently at the limit. Counted in UTF-8 bytes, the unit
      // the limit is enforced in.
      Text("\(instructionUsage)% of limit used")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(
          "\(instructionUsage) percent of instruction limit used"
        )
    }
  }

  private var instructionUsage: Int {
    instructions.utf8.count * 100 / StyleProfileStore.characterLimit
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

  init(profile: StyleProfile, isExisting: Bool) {
    self.profile = profile
    self.isExisting = isExisting
    _name = State(initialValue: profile.name)
    _instructions = State(initialValue: profile.instructions)
  }

  /// Writes the edit through the store, which owns the encoding, the caps and
  /// the merge against the stored list (`StyleProfileStore.save(_:)`).
  private func save() {
    guard canSave else {
      return
    }
    var edited = profile
    edited.name = name
    edited.instructions = instructions
    StyleProfileStore().save(edited)
    dismiss()
  }

  /// No confirmation alert: a style is a couple of sentences the user typed, the
  /// button is `.destructive` and out of the way of Save, and nothing else
  /// depends on it — deleting the active one just falls back to the first
  /// remaining profile (see `StyleProfileStore.active`).
  private func delete() {
    StyleProfileStore().remove(id: profile.id)
    dismiss()
  }
}
