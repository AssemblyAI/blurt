import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// Output styles: Default (the engine's base cleanup) plus the user's named
/// profiles (up to `StyleProfileStore.limit`, 100 on the phone) whose
/// instructions ride the cleanup rewrite. Three ways in, each
/// one tap: use a style (tap its row), edit one (its pencil), or add one, from
/// a preset (`StylePreset`) or from scratch.
/// The store owns the JSON and the active-style rule (`StyleProfileStore`);
/// this view binds to the raw defaults slots only to redraw when they change,
/// and writes through the store, the same discipline as the Mac's style row.
struct StylesView: View {
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var activeRaw = ""
  @State private var editing: StyleProfile?
  @State private var adding = false
  private let store = StyleProfileStore()

  var body: some View {
    // Decoded once per redraw: the list holds up to 100 profiles, and every
    // tap on a style rewrites the active slot and redraws.
    let profiles = store.profiles(decoding: profilesRaw)
    let active = StyleProfileStore.active(in: profiles, id: activeRaw)
    let isFull = profiles.count >= StyleProfileStore.limit
    List {
      Section {
        StyleRow(
          name: StyleProfileStore.defaultStyleName, detail: "Filler out, punctuation fixed, your words kept.",
          isActive: active == nil, edit: nil
        ) { store.activateDefault() }
        ForEach(profiles) { profile in
          StyleRow(
            name: profile.name, detail: profile.instructions, isActive: active?.id == profile.id,
            edit: { editing = profile }, activate: { store.activate(profile) })
        }
      } header: {
        Eyebrow("Your styles")
      } footer: {
        Text("Tap a style to use it, or the pencil to change it.")
      }
      Section {
        ForEach(StylePreset.allCases) { preset in
          PresetRow(preset: preset, isAdded: preset.added(in: profiles) != nil, isFull: isFull) {
            add(preset)
          }
        }
      } header: {
        Eyebrow("Start from a preset")
      } footer: {
        Text(
          isFull
            ? "You have \(StyleProfileStore.limit) styles, the most there can be. Delete one to add another."
            : "Adds it to your styles and switches to it. Edit it any time.")
      }
    }
    .brandForm()
    // Pinned under the list, always in reach, rather than a row the list's
    // card shape would clip.
    .safeAreaInset(edge: .bottom) {
      Button {
        adding = true
      } label: {
        Label("New style", systemImage: "plus")
      }
      .buttonStyle(BrandButtonStyle())
      .disabled(isFull)
      .padding(DesignTokens.Metrics.appPagePad)
      .background(BlurtBrand.page)
    }
    .navigationTitle("Output styles")
    .sheet(isPresented: $adding) { StyleEditor(profile: nil, store: store) }
    .sheet(item: $editing) { StyleEditor(profile: $0, store: store) }
  }

  /// One tap: the preset joins the user's styles (unless it already did) and
  /// becomes the active one.
  private func add(_ preset: StylePreset) {
    guard let result = preset.adding(to: store.profiles) else { return }
    store.profiles = result.profiles
    store.activate(result.style)
  }
}

/// A style: tap to use it; its pencil (a style of the user's own) edits it.
private struct StyleRow: View {
  let name: String
  let detail: String
  let isActive: Bool
  let edit: (() -> Void)?
  let activate: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.appStackGap) {
      Button(action: activate) {
        HStack {
          VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
            Text(name).foregroundStyle(BlurtBrand.text)
            Text(detail).font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.muted)
              .lineLimit(2)  // literal-ok: two lines of instructions
          }
          Spacer()
          if isActive { Image(systemName: "checkmark").foregroundStyle(BlurtBrand.accent) }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isActive ? .isSelected : [])
      if let edit {
        Button(action: edit) {
          Image(systemName: "pencil")
            .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
            .foregroundStyle(BlurtBrand.accent)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Edit \(name)")
      }
    }
  }
}

/// A preset: its icon, name and a line of what it does; tap to add it.
private struct PresetRow: View {
  let preset: StylePreset
  let isAdded: Bool
  let isFull: Bool
  let add: () -> Void

  var body: some View {
    Button(action: add) {
      HStack(spacing: DesignTokens.Metrics.appStackGap) {
        Image(systemName: preset.symbol)
          .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
          .foregroundStyle(BlurtBrand.accent)
          .frame(width: DesignTokens.Metrics.appIcon)
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          Text(preset.name).foregroundStyle(BlurtBrand.text)
          Text(preset.instructions).font(BlurtType.body(DesignTokens.Typography.sizeCaption))
            .foregroundStyle(BlurtBrand.muted)
            .lineLimit(1)  // literal-ok: a line of the preset's instructions
        }
        Spacer()
        if isAdded {
          Label("Added", systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(BlurtBrand.accent)
        } else {
          Eyebrow("Add", color: BlurtBrand.accent)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isAdded && isFull)
    .accessibilityLabel(isAdded ? "\(preset.name), added" : "Add \(preset.name)")
  }
}

/// Name plus instructions, with the same caps the Mac's editor enforces: 24
/// characters of name, and instructions trimmed to the bytes the API's
/// instruction cap leaves once the base cleanup text has taken its share. A
/// new style can start from a preset, which fills both fields to edit.
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
        if profile == nil {
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
        Section {
          TextField("e.g. Casual", text: $name)
            .onChange(of: name) { _, value in
              if value.count > StyleProfileStore.nameLimit { name = String(value.prefix(StyleProfileStore.nameLimit)) }
            }
        } header: {
          Eyebrow("Name")
        }
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

/// A preset as a chip in the editor: its icon and name, filled with the accent
/// while the fields hold its text.
private struct PresetChip: View {
  let preset: StylePreset
  let isChosen: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      HStack(spacing: DesignTokens.Metrics.appLineGap) {
        Image(systemName: preset.symbol)
        Text(preset.name).lineLimit(1)
      }
      .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
      .padding(.vertical, DesignTokens.Metrics.appChipPadY)
      .frame(maxWidth: .infinity)
      .foregroundStyle(isChosen ? BlurtBrand.ctaText : BlurtBrand.text)
      .background(
        isChosen ? BlurtBrand.cta : BlurtBrand.cardFill,
        in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
          .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }
}
