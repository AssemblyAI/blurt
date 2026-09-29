import BlurtEngine
import SwiftUI

/// The Vocabulary pane of the Settings window: the words Blurt should know —
/// key terms that prime transcription spelling, and text shortcuts that replace
/// a spoken phrase with saved text. Both are lists of words the user curates,
/// so they share a pane rather than key terms trailing General's pickers.
struct VocabularySettingsTab: View {
  var body: some View {
    SettingsPane {
      KeyTermsStepView()
      TextShortcutsSection()
    }
  }
}

/// Spoken phrases the app replaces with saved text before pasting — say
/// "personal email", get the address (see `TextShortcutExpander`).
///
/// Shaped like System Settings › Keyboard › Text Replacements, the list users
/// already know for exactly this: a two-column table with + / − beneath it.
/// Double-click (or Return on) a row to edit it; editing happens in the sheet
/// below. The table scrolls inside a fixed height, so the pane stays the same
/// size however many shortcuts there are.
struct TextShortcutsSection: View {
  /// Bound to observe, not to write — the store owns the JSON encoding, as with
  /// `StyleProfilesSection`.
  @AppStorage(TextShortcutStore.defaultsKey) private var rawShortcuts = ""

  /// The shortcut the sheet is editing, or nil while it's closed.
  @State private var editing: TextShortcut?
  @State private var selection: TextShortcut.ID?

  var body: some View {
    let shortcuts = TextShortcutStore().shortcuts(decoding: rawShortcuts)
    Section {
      VStack(alignment: .leading, spacing: 6) {
        table(shortcuts)
        HStack(spacing: 2) {
          Button {
            editing = TextShortcut(trigger: "", expansion: "")
          } label: {
            Image(systemName: "plus").frame(width: 20, height: 18)
          }
          .disabled(shortcuts.count >= TextShortcutStore.shortcutLimit)
          .help("Add Shortcut")
          .accessibilityLabel("Add Shortcut")
          .accessibilityIdentifier(UITestIdentifiers.textShortcutAdd)
          Button {
            if let selection { remove(selection) }
          } label: {
            Image(systemName: "minus").frame(width: 20, height: 18)
          }
          .disabled(selection == nil)
          .help("Remove Shortcut")
          .accessibilityLabel("Remove Shortcut")
          .accessibilityIdentifier(UITestIdentifiers.textShortcutRemove)
        }
        .buttonStyle(.borderless)
      }
    } header: {
      Text("Text Shortcuts")
    } footer: {
      Text(
        "Say a phrase while dictating and it's replaced with your saved text — "
          + "for example, “personal email” becomes your address.")
    }
    .sheet(item: $editing) { shortcut in
      TextShortcutEditorSheet(shortcut: shortcut, among: shortcuts)
    }
  }

  private func table(_ shortcuts: [TextShortcut]) -> some View {
    Table(shortcuts, selection: $selection) {
      TableColumn("Phrase", value: \.trigger)
      TableColumn("Replacement") { shortcut in
        Text(shortcut.expansion)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .tableStyle(.bordered(alternatesRowBackgrounds: true))
    // `primaryAction` is the table's double-click / Return: the native way
    // into a row, in place of an "Edit…" button on every row.
    .contextMenu(forSelectionType: TextShortcut.ID.self) { ids in
      if let id = ids.first, let shortcut = shortcuts.first(where: { $0.id == id }) {
        Button("Edit…") { editing = shortcut }
        Button("Remove", role: .destructive) { remove(id) }
      }
    } primaryAction: { ids in
      if let id = ids.first { editing = shortcuts.first { $0.id == id } }
    }
    // Delete removes the selected row, as in Text Replacements.
    .onDeleteCommand { if let selection { remove(selection) } }
    .overlay {
      if shortcuts.isEmpty {
        Text("No Shortcuts")
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: 160)
    // `SettingsPane` disables scrolling through the environment, which reaches
    // this table too — without re-enabling it, rows past the fold (the store
    // allows 200) would be unreachable.
    .scrollDisabled(false)
    .accessibilityIdentifier(UITestIdentifiers.textShortcutTable)
  }

  /// No confirmation, like the sheet's Delete (see `StyleProfileEditorSheet
  /// .delete()`): a shortcut is a phrase and a line of text the user typed, and
  /// Text Replacements' − doesn't ask either.
  private func remove(_ id: TextShortcut.ID) {
    let store = TextShortcutStore()
    store.shortcuts = store.shortcuts.filter { $0.id != id }
    if selection == id { selection = nil }
  }
}

/// Adds or edits one shortcut. Same shape as `StyleProfileEditorSheet`: a
/// headline, labeled full-width fields, Delete at the leading edge clear of the
/// Cancel / Save pair.
private struct TextShortcutEditorSheet: View {
  let shortcut: TextShortcut
  let isExisting: Bool
  /// Every *other* shortcut's `matchKey`, taken once when the sheet opens
  /// rather than re-decoded from the store on every keystroke.
  private let otherKeys: Set<String>

  @Environment(\.dismiss) private var dismiss

  @State private var trigger: String
  @State private var expansion: String
  @FocusState private var triggerFocused: Bool

  init(shortcut: TextShortcut, among shortcuts: [TextShortcut]) {
    self.shortcut = shortcut
    isExisting = shortcuts.contains { $0.id == shortcut.id }
    otherKeys = Set(
      shortcuts.filter { $0.id != shortcut.id }.map { TextShortcutStore.matchKey(for: $0.trigger) })
    _trigger = State(initialValue: shortcut.trigger)
    _expansion = State(initialValue: shortcut.expansion)
  }

  /// The phrase as the matcher sees it (`TextShortcutStore.matchKey`) — empty
  /// when it has no letters or digits.
  private var triggerKey: String { TextShortcutStore.matchKey(for: trigger) }

  /// A phrase the matcher can't tell from another shortcut's — "personal
  /// email" vs "Personal-Email" — would be dropped by the store's dedupe, so
  /// it's refused here instead of vanishing.
  private var duplicatesAnother: Bool {
    !triggerKey.isEmpty && otherKeys.contains(triggerKey)
  }

  private var canSave: Bool {
    !triggerKey.isEmpty && expansion.trimmedNonEmpty() != nil && !duplicatesAnother
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Text Shortcut")
          .font(.headline)
        Text("When you say the phrase, Blurt pastes the replacement instead.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Phrase")
          .font(.subheadline.weight(.semibold))
        TextField("", text: $trigger, prompt: Text("e.g. personal email"))
          .lineLimit(1)
          .disableAutocorrection(true)
          .focused($triggerFocused)
          .accessibilityLabel("Phrase")
          .accessibilityIdentifier(UITestIdentifiers.textShortcutTrigger)
          .onChange(of: trigger) {
            if trigger.count > TextShortcutStore.triggerLimit {
              trigger = String(trigger.prefix(TextShortcutStore.triggerLimit))
            }
          }
        if duplicatesAnother {
          Text("Another shortcut already uses this phrase.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Replacement")
          .font(.subheadline.weight(.semibold))
        TextField(
          text: $expansion, prompt: Text("e.g. me@example.com"), axis: .vertical
        ) {
          Text("Replacement")
        }
        .labelsHidden()
        .lineLimit(1...6)
        .disableAutocorrection(true)
        .accessibilityIdentifier(UITestIdentifiers.textShortcutExpansion)
        .onChange(of: expansion) {
          if expansion.count > TextShortcutStore.expansionLimit {
            expansion = String(expansion.prefix(TextShortcutStore.expansionLimit))
          }
        }
      }

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

  /// Merged against the stored list, not the observed copy, for the reason on
  /// `StyleProfileEditorSheet.save()`.
  private func save() {
    guard canSave else { return }
    var edited = shortcut
    edited.trigger = trigger
    edited.expansion = expansion
    let store = TextShortcutStore()
    var updated = store.shortcuts
    if let index = updated.firstIndex(where: { $0.id == edited.id }) {
      updated[index] = edited
    } else {
      updated.append(edited)
    }
    store.shortcuts = updated
    dismiss()
  }

  private func delete() {
    let store = TextShortcutStore()
    store.shortcuts = store.shortcuts.filter { $0.id != shortcut.id }
    dismiss()
  }
}
