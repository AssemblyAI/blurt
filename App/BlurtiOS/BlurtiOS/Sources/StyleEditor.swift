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
  @Environment(\.dynamicTypeSize)
  private var dynamicTypeSize
  @State private var name: String
  @State private var instructions: String

  private var canSave: Bool { StyleProfile.canSave(name: name, instructions: instructions) }

  var body: some View {
    NavigationStack {
      Form {
        if profile == nil {
          presetsSection
        }
        Section {
          TextField("e.g. Casual", text: $name)
            .onChange(of: name) { _, value in
              let clamped = StyleProfileStore.clampedName(value)
              if clamped != value { name = clamped }
            }
        } header: {
          Eyebrow("Name")
        }
        instructionsSection
        if profile != nil {
          Section {
            Button("Delete style", role: .destructive) {
              if let profile { store.remove(id: profile.id) }
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
      // The three share the row in equal widths, so none runs off it;
      // at an accessibility text size, where a third of the row holds
      // a few letters, each takes the whole row.
      let chips =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: DesignTokens.Metrics.appChipGap))
        : AnyLayout(HStackLayout(spacing: DesignTokens.Metrics.appChipGap))
      chips {
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
        let clamped = StyleProfileStore.clampedInstructions(value)
        if clamped != value { instructions = clamped }
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
    if var edited = profile {
      edited.name = name
      edited.instructions = instructions
      store.save(edited)
    } else {
      let created = StyleProfile(name: name, instructions: instructions)
      store.save(created)
      store.activate(created)
    }
    dismiss()
  }
}
