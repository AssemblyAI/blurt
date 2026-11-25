import BlurtEngine
import SwiftUI

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
  @AppStorage(TextShortcutStore.defaultsKey)
  private var rawShortcuts = ""

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
            Image(systemName: "plus").frame(width: 20, height: 20)
          }
          .disabled(shortcuts.count >= TextShortcutStore.shortcutLimit)
          .help("Add shortcut")
          .accessibilityLabel("Add shortcut")
          .accessibilityIdentifier(UITestIdentifiers.textShortcutAdd)
          Button {
            if let selection { remove(selection) }
          } label: {
            Image(systemName: "minus").frame(width: 20, height: 20)
          }
          .disabled(selection == nil)
          .help("Remove shortcut")
          .accessibilityLabel("Remove shortcut")
          .accessibilityIdentifier(UITestIdentifiers.textShortcutRemove)
        }
        .buttonStyle(.borderless)
      }
    } header: {
      Text("Text shortcuts")
    } footer: {
      Text(
        "Replace spoken phrases with saved text. For example, say “personal email” to insert your address."
      )
    }
    .sheet(item: $editing) { shortcut in
      TextShortcutEditorSheet(shortcut: shortcut, among: shortcuts)
    }
    // However a row goes — −, Delete, or the sheet's Delete — a selection naming
    // it would leave − enabled over nothing.
    .onChange(of: rawShortcuts) { _, raw in
      let remaining = TextShortcutStore().shortcuts(decoding: raw)
      if let selection, !remaining.contains(where: { $0.id == selection }) {
        self.selection = nil
      }
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
        VStack(spacing: 6) {
          Text("No text shortcuts yet")
            .font(.headline)
          Text("Click + to add a phrase and its replacement.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
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
    TextShortcutStore().remove(id: id)
  }
}
