import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// Name plus instructions, with the same caps the Mac's editor enforces: 24
/// characters of name, and instructions trimmed to the bytes the API's
/// instruction cap leaves once the base cleanup text has taken its share. A
/// new style can start from a preset, which fills both fields to edit.
struct StyleEditor: View {
  let profile: StyleProfile?
  let store: StyleProfileStore
  @Environment(\.dismiss)
  private var dismiss
  @State private var name: String
  @State private var instructions: String

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        if profile == nil {
          presetsSection
        }
        Section {
          TextField("e.g. Casual", text: $name)
            .onChange(of: name) { _, value in
              if value.count > StyleProfileStore.nameLimit { name = String(value.prefix(StyleProfileStore.nameLimit)) }
            }
        } header: {
          Eyebrow("Name")
        }
        instructionsSection
        if profile != nil {
          Section {
            Button("Delete style", role: .destructive) {
              store.profiles = store.profiles.filter { $0.id != profile?.id }
              dismiss()
            }
          }
        }
      }
      .brandForm()
      .navigationTitle(profile == nil ? "New style" : "Edit style")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
      }
    }
  }

  /// A new style can start from a preset, which fills both fields to edit.
  private var presetsSection: some View {
    Section {
      // The three share the row in equal widths, so none runs off it.
      HStack(spacing: DesignTokens.Metrics.appChipGap) {
        ForEach(StylePreset.allCases) { preset in
          PresetChip(preset: preset, isChosen: instructions == preset.instructions) {
            name = preset.name
            instructions = preset.instructions
          }
        }
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
    } header: {
      Eyebrow("Start from")
    }
  }

  /// The instructions, trimmed to the bytes the instruction cap leaves.
  private var instructionsSection: some View {
    Section {
      TextField(
        "e.g. add fitting emojis sparingly, or always write in lowercase", text: $instructions, axis: .vertical
      )
      .lineLimit(3...8)  // literal-ok: the editor's rows
      .onChange(of: instructions) { _, value in
        let trimmed = value.prefix(maxUTF8Bytes: StyleProfileStore.characterLimit)
        if trimmed != value { instructions = trimmed }
      }
    } header: {
      Eyebrow("Instructions")
    } footer: {
      Text("Added on top of the built-in cleanup. \(instructions.utf8.count)/\(StyleProfileStore.characterLimit)")
    }
  }

  init(profile: StyleProfile?, store: StyleProfileStore) {
    self.profile = profile
    self.store = store
    _name = State(initialValue: profile?.name ?? "")
    _instructions = State(initialValue: profile?.instructions ?? "")
  }

  private func save() {
    var list = store.profiles
    if let profile, let index = list.firstIndex(where: { $0.id == profile.id }) {
      list[index].name = name
      list[index].instructions = instructions
      store.profiles = list
    } else {
      let created = StyleProfile(name: name, instructions: instructions)
      list.append(created)
      store.profiles = list
      store.activate(created)
    }
    dismiss()
  }
}
