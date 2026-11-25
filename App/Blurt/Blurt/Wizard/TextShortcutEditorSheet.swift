import BlurtEngine
import SwiftUI

/// Adds or edits one shortcut. Same shape as `StyleProfileEditorSheet`: a
/// headline, labeled full-width fields, Delete at the leading edge clear of the
/// Cancel / Save pair.
struct TextShortcutEditorSheet: View {
  let shortcut: TextShortcut
  let isExisting: Bool
  /// Every *other* shortcut's `matchKey`, taken once when the sheet opens
  /// rather than re-decoded from the store on every keystroke.
  private let otherKeys: Set<String>

  @Environment(\.dismiss)
  private var dismiss

  @State private var trigger: String
  @State private var expansion: String
  @FocusState private var triggerFocused: Bool

  /// A phrase the matcher can't tell from another shortcut's — "personal
  /// email" vs "Personal-Email" — would be dropped by the store's dedupe, so
  /// it's refused here instead of vanishing (`TextShortcut.isTaken`).
  private var duplicatesAnother: Bool { TextShortcut.isTaken(trigger, by: otherKeys) }

  private var canSave: Bool { TextShortcut.canSave(trigger: trigger, expansion: expansion, otherKeys: otherKeys) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Text Shortcut")
          .font(.headline)
        Text("When you say the phrase, Blurt pastes the replacement instead.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      phraseField

      replacementField

      HStack(spacing: 12) {
        if isExisting {
          Button("Delete", role: .destructive, action: delete)
            .accessibilityIdentifier(UITestIdentifiers.textShortcutDelete)
        }
        Spacer(minLength: 12)
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier(UITestIdentifiers.textShortcutCancel)
        Button("Save", action: save)
          .glassButtonStyleCompat(prominent: true)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
          .accessibilityIdentifier(UITestIdentifiers.textShortcutSave)
      }
    }
    .padding(20)
    .frame(width: 420)
    .defaultFocus($triggerFocused, true)
  }

  /// The spoken phrase, capped at the store's limit, with the duplicate warning.
  private var phraseField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Phrase")
        .font(.subheadline.weight(.semibold))
      TextField("", text: $trigger, prompt: Text("Personal email"))
        .lineLimit(1)
        .disableAutocorrection(true)
        .focused($triggerFocused)
        .accessibilityLabel("Phrase")
        .accessibilityIdentifier(UITestIdentifiers.textShortcutTrigger)
        .onChange(of: trigger) {
          let clamped = TextShortcutStore.clampedTrigger(trigger)
          if clamped != trigger { trigger = clamped }
        }
      if duplicatesAnother {
        Text("Another shortcut already uses this phrase.")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  /// What the phrase pastes, capped at the store's limit.
  private var replacementField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Replacement")
        .font(.subheadline.weight(.semibold))
      TextField(
        text: $expansion, prompt: Text("me@example.com"), axis: .vertical
      ) {
        Text("Replacement")
      }
      .labelsHidden()
      .lineLimit(1...6)
      .disableAutocorrection(true)
      .accessibilityIdentifier(UITestIdentifiers.textShortcutExpansion)
      .onChange(of: expansion) {
        let clamped = TextShortcutStore.clampedExpansion(expansion)
        if clamped != expansion { expansion = clamped }
      }
    }
  }

  init(shortcut: TextShortcut, among shortcuts: [TextShortcut]) {
    self.shortcut = shortcut
    isExisting = shortcuts.contains { $0.id == shortcut.id }
    otherKeys = Set(
      shortcuts.filter { $0.id != shortcut.id }.map { TextShortcut.matchKey(for: $0.trigger) }
    )
    _trigger = State(initialValue: shortcut.trigger)
    _expansion = State(initialValue: shortcut.expansion)
  }

  /// Merged against the stored list, not the observed copy, by the store
  /// (`TextShortcutStore.save(_:)`).
  private func save() {
    guard canSave else {
      return
    }
    var edited = shortcut
    edited.trigger = trigger
    edited.expansion = expansion
    TextShortcutStore().save(edited)
    dismiss()
  }

  private func delete() {
    TextShortcutStore().remove(id: shortcut.id)
    dismiss()
  }
}
