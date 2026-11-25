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
  @AppStorage(StyleProfileStore.defaultsKey)
  private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey)
  private var activeRaw = ""
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
          name: StyleProfileStore.defaultStyleName,
          detail: "Filler out, punctuation fixed, your words kept.",
          isActive: active == nil,
          edit: nil
        ) { store.activateDefault() }
        ForEach(profiles) { profile in
          StyleRow(
            name: profile.name,
            detail: profile.instructions,
            isActive: active?.id == profile.id,
            edit: { editing = profile },
            activate: { store.activate(profile) }
          )
        }
      } header: {
        Eyebrow("Your styles")
      } footer: {
        Text("Tap a style to use it, or the pencil to change it.")
      }
      presetsSection(profiles: profiles, isFull: isFull)
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

  /// The presets, each one tap from joining the styles; refused once the list is full.
  private func presetsSection(profiles: [StyleProfile], isFull: Bool) -> some View {
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
          : "Adds it to your styles and switches to it. Edit it any time."
      )
    }
  }

  /// One tap: the preset joins the user's styles (unless it already did) and
  /// becomes the active one.
  private func add(_ preset: StylePreset) {
    guard let result = preset.adding(to: store.profiles) else {
      return
    }
    store.profiles = result.profiles
    store.activate(result.style)
  }
}
