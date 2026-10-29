import BlurtEngine
import SwiftUI

/// The Key Styles row: a status and an "Edit…" button, like the API key row,
/// whose sheet gives each trigger key its own style (or Off, for keys other
/// than the bound one). The first row of the Advanced pane's Experimental
/// section rather than beside the dictation key on General — it's a
/// power-user extra, and a section of its own made Advanced too tall for a
/// small display. Settings-only, so it is not a wizard step.
struct KeyStylesRow: View {
  var coordinator: AppCoordinator

  @BoundTriggerKey private var bound

  // Observed so the summary follows a change, and decoded through the stores
  // that own both encodings.
  @AppStorage(TriggerKeyStyleStore.defaultsKey) private var keyStylesRaw = ""
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""

  @State private var isPresentingKeyStyles = false

  /// One "right ⌥: Casual" entry per trigger key, named as the sheet names it,
  /// and whether that key is moved off its default (Off, or the main window's
  /// style for the bound key). All of them are the Edit… button's spoken
  /// summary; the changed ones are the row's status.
  private static func keyStyleEntries(
    bound: TriggerKey, styles: [TriggerKey: String], profiles: [StyleProfile]
  ) -> [(text: String, isChanged: Bool)] {
    TriggerKey.allCases.map { key in
      let choice = TriggerKeyStyleStore.choice(for: key, bound: bound, styles: styles, profiles: profiles)
      return (
        text: "\(key.label): \(KeyStylesSheet.name(of: choice, profiles: profiles))",
        isChanged: choice != TriggerKeyStyleStore.defaultChoice(for: key, bound: bound)
      )
    }
  }

  var body: some View {
    let entries = Self.keyStyleEntries(
      bound: bound, styles: TriggerKeyStyleStore.styles(decoding: keyStylesRaw),
      profiles: StyleProfileStore().profiles(decoding: profilesRaw))
    let changed = entries.filter(\.isChanged).map(\.text)
    SettingRow(title: "Key Styles", systemImage: "textformat") {
      HStack(spacing: 8) {
        // The keys set up beyond the default, or the main window's style.
        Text(changed.isEmpty ? KeyStylesSheet.mainWindowName : changed.joined(separator: ", "))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Button("Edit…") { isPresentingKeyStyles = true }
          .accessibilityValue(entries.map(\.text).joined(separator: ", "))
          .accessibilityIdentifier(UITestIdentifiers.keyStylesButton)
      }
    }
    .sheet(isPresented: $isPresentingKeyStyles) {
      KeyStylesSheet(bound: bound) { coordinator.dictationBindingChanged() }
    }
  }
}

/// Which style each trigger key dictates with, as a sheet from the Key Styles
/// row: one pop-up per key offering Off (except for the bound key, which
/// always dictates), the main window's style, Default, or a profile. Follows
/// `StyleProfileEditorSheet`'s shape — headline, explanation, content, and the
/// default action at the trailing edge — with only Done, since each choice is
/// written as it is made. While enhanced transcripts are off the styles are
/// disabled, as on the Styles pane; turning a key on or off still works.
private struct KeyStylesSheet: View {
  let bound: TriggerKey
  /// A key was turned on or off, so the tap must rebind (see `setStyle`).
  let onEnabledKeysChanged: () -> Void

  @Environment(\.dismiss) private var dismiss
  @AppStorage(TriggerKeyStyleStore.defaultsKey) private var keyStylesRaw = ""
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  static let offName = "Off"
  static let mainWindowName = "Same as main window"

  /// A choice's display name: Off, the main window's style, Default, or a
  /// profile — `choice` is one `TriggerKeyStyleStore.choice` has normalized.
  static func name(of choice: String, profiles: [StyleProfile]) -> String {
    switch choice {
    case TriggerKeyStyleStore.offChoice: offName
    case TriggerKeyStyleStore.currentStyleID: mainWindowName
    default: StyleProfileStore.active(in: profiles, id: choice)?.name ?? StyleProfileStore.defaultStyleName
    }
  }

  var body: some View {
    let profiles = StyleProfileStore().profiles(decoding: profilesRaw)
    let styles = TriggerKeyStyleStore.styles(decoding: keyStylesRaw)
    VStack(alignment: .leading, spacing: 16) {
      header
      Form {
        Section {
          ForEach(TriggerKey.allCases, id: \.self) { key in
            PickerSettingRow(
              title: key.label, systemImage: "keyboard",
              accessibilityID: UITestIdentifiers.keyStylePicker(key.keyCode),
              selection: choice(for: key, styles: styles, profiles: profiles)
            ) {
              if key != bound { Text(Self.offName).tag(TriggerKeyStyleStore.offChoice) }
              Text(Self.mainWindowName).tag(TriggerKeyStyleStore.currentStyleID)
              Group {
                Text(StyleProfileStore.defaultStyleName).tag(StyleProfileStore.defaultStyleID)
                ForEach(profiles) { profile in
                  Text(profile.name).tag(profile.id.uuidString)
                }
              }
              .disabled(!enhancedTranscripts)
            }
          }
        } footer: {
          if !enhancedTranscripts {
            Text(StylesInertNotice.settingsText)
          }
        }
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .glassButtonStyleCompat(prominent: true)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier(UITestIdentifiers.keyStylesDone)
      }
      // Escape closes it too. The other sheets get that from their Cancel button;
      // every choice here is already saved, so the same shortcut rides a hidden one.
      .background {
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .hidden()
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Key Styles")
        .font(.headline)
      Text("Each key can dictate with its own style, without changing the style selected in the main window.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// One key's pop-up: `offChoice` is Off, otherwise a style id (see `TriggerKeyStyleStore`).
  private func choice(
    for key: TriggerKey, styles: [TriggerKey: String], profiles: [StyleProfile]
  ) -> Binding<String> {
    Binding(
      get: { TriggerKeyStyleStore.choice(for: key, bound: bound, styles: styles, profiles: profiles) },
      set: { newValue in
        // Through the store, which owns the encoding (see `HotkeyStepView.selection`).
        // Only a key turned on or off rebinds the tap; a style is read at the next press.
        if TriggerKeyStyleStore().setStyle(newValue, for: key) { onEnabledKeysChanged() }
      })
  }
}
