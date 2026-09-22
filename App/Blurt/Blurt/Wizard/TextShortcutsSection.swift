import BlurtEngine
import SwiftUI

/// The Text Shortcuts pane of the Settings window: spoken phrases the app
/// replaces with saved text before pasting — say "personal email", get the
/// address (see `TextShortcutExpander`). Its own pane rather than a General
/// section because the list grows without a cap worth designing to, so this one
/// pane scrolls while the others hug their content.
///
/// Rows follow the Styles section's shape: each is a read-out plus an "Edit…"
/// way in, and all editing happens in the sheet below.
struct TextShortcutsSection: View {
  /// Bound to observe, not to write — the store owns the JSON encoding, as with
  /// `StyleProfilesSection`.
  @AppStorage(TextShortcutStore.defaultsKey) private var rawShortcuts = ""

  /// The shortcut the sheet is editing, or nil while it's closed.
  @State private var editing: TextShortcut?

  private var shortcuts: [TextShortcut] { TextShortcutStore().shortcuts(decoding: rawShortcuts) }

  var body: some View {
    Form {
      Section {
        ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(shortcut.trigger)
              Text(shortcut.expansion)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button("Edit…") { editing = shortcut }
              .accessibilityIdentifier(UITestIdentifiers.textShortcutEdit(index))
          }
        }
        Button("Add Shortcut…") { editing = TextShortcut(trigger: "", expansion: "") }
          .disabled(shortcuts.count >= TextShortcutStore.shortcutLimit)
          .accessibilityIdentifier(UITestIdentifiers.textShortcutAdd)
      } header: {
        Text("Text Shortcuts")
      } footer: {
        Text(
          "Say a phrase while dictating and it's replaced with your saved text — "
            + "for example, “personal email” becomes your address.")
      }
    }
    .formStyle(.grouped)
    .frame(height: 440)
    .sheet(item: $editing) { shortcut in
      TextShortcutEditorSheet(shortcut: shortcut, isExisting: shortcuts.contains(shortcut))
    }
  }
}

/// Adds or edits one shortcut. Same shape as `StyleProfileEditorSheet`: a
/// headline, labeled full-width fields, Delete at the leading edge clear of the
/// Cancel / Save pair.
private struct TextShortcutEditorSheet: View {
  let shortcut: TextShortcut
  let isExisting: Bool

  @Environment(\.dismiss) private var dismiss

  @State private var trigger: String
  @State private var expansion: String
  @FocusState private var triggerFocused: Bool

  init(shortcut: TextShortcut, isExisting: Bool) {
    self.shortcut = shortcut
    self.isExisting = isExisting
    _trigger = State(initialValue: shortcut.trigger)
    _expansion = State(initialValue: shortcut.expansion)
  }

  /// A trigger that is already another shortcut's (case-insensitively) would be
  /// dropped by the store's dedupe, so it's refused here instead of vanishing.
  private var duplicatesAnother: Bool {
    guard let key = trigger.trimmedNonEmpty()?.lowercased() else { return false }
    return TextShortcutStore().shortcuts.contains {
      $0.id != shortcut.id && $0.trigger.lowercased() == key
    }
  }

  private var canSave: Bool {
    trigger.trimmedNonEmpty() != nil && expansion.trimmedNonEmpty() != nil && !duplicatesAnother
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
