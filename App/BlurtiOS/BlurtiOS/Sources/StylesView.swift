import BlurtEngine
import SwiftUI

/// Output styles: Default (the engine's base cleanup) plus up to four named
/// profiles whose instructions ride the cleanup rewrite. The store owns the
/// JSON and the active-style rule (`StyleProfileStore`); this view binds to the
/// raw defaults slots only to redraw when they change, and writes through the
/// store, the same discipline as the Mac's style row.
struct StylesView: View {
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var activeRaw = ""
  @State private var editing: StyleProfile?
  @State private var adding = false
  private let store = StyleProfileStore()

  private var profiles: [StyleProfile] { store.profiles(decoding: profilesRaw) }
  private var active: StyleProfile? { StyleProfileStore.active(in: profiles, id: activeRaw) }

  var body: some View {
    List {
      Section {
        StyleRow(
          name: StyleProfileStore.defaultStyleName, detail: "Filler out, punctuation fixed, your words kept.",
          isActive: active == nil
        ) { store.activateDefault() }
        ForEach(profiles) { profile in
          StyleRow(name: profile.name, detail: profile.instructions, isActive: active?.id == profile.id) {
            store.activate(profile)
          }
          .swipeActions {
            Button("Edit") { editing = profile }.tint(BlurtBrand.green)
          }
        }
      } footer: {
        Text("Tap a style to use it. Swipe a style to edit it. Up to \(StyleProfileStore.profileLimit).")
      }
      Section {
        Button("Add style") { adding = true }
          .disabled(profiles.count >= StyleProfileStore.profileLimit)
      }
    }
    .navigationTitle("Output styles")
    .sheet(isPresented: $adding) { StyleEditor(profile: nil, store: store) }
    .sheet(item: $editing) { StyleEditor(profile: $0, store: store) }
  }
}

private struct StyleRow: View {
  let name: String
  let detail: String
  let isActive: Bool
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(name).foregroundStyle(.primary)
          Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer()
        if isActive { Image(systemName: "checkmark").foregroundStyle(BlurtBrand.green) }
      }
    }
  }
}

/// Name plus instructions, with the same caps the Mac's editor enforces: 24
/// characters of name, and instructions trimmed to the bytes the API's
/// instruction cap leaves once the base cleanup text has taken its share.
private struct StyleEditor: View {
  let profile: StyleProfile?
  let store: StyleProfileStore
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var instructions: String

  init(profile: StyleProfile?, store: StyleProfileStore) {
    self.profile = profile
    self.store = store
    _name = State(initialValue: profile?.name ?? "")
    _instructions = State(initialValue: profile?.instructions ?? "")
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
      && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Name") {
          TextField("e.g. Casual", text: $name)
            .onChange(of: name) { _, value in
              if value.count > StyleProfileStore.nameLimit { name = String(value.prefix(StyleProfileStore.nameLimit)) }
            }
        }
        Section {
          TextField(
            "e.g. add fitting emojis sparingly, or always write in lowercase", text: $instructions, axis: .vertical
          )
          .lineLimit(3...8)
          .onChange(of: instructions) { _, value in
            let trimmed = value.prefix(maxUTF8Bytes: StyleProfileStore.characterLimit)
            if trimmed != value { instructions = trimmed }
          }
        } header: {
          Text("Instructions")
        } footer: {
          Text("\(instructions.utf8.count)/\(StyleProfileStore.characterLimit)")
        }
        if profile != nil {
          Section {
            Button("Delete style", role: .destructive) {
              store.profiles = store.profiles.filter { $0.id != profile?.id }
              dismiss()
            }
          }
        }
      }
      .navigationTitle(profile == nil ? "New style" : "Edit style")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
      }
    }
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
