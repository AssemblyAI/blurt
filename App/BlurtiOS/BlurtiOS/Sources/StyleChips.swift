import BlurtEngine
import SwiftUI

/// The output styles as chips: Default and each profile, the active one
/// filled with the accent; Edit opens the styles editor.
struct StyleChips: View {
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var activeRaw = ""
  private let styles = StyleProfileStore()

  private var profiles: [StyleProfile] { styles.profiles(decoding: profilesRaw) }
  private var activeStyle: StyleProfile? { StyleProfileStore.active(in: profiles, id: activeRaw) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Style").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          StyleChip(name: StyleProfileStore.defaultStyleName, selected: activeStyle == nil) { styles.activateDefault() }
          ForEach(profiles) { profile in
            StyleChip(name: profile.name, selected: activeStyle?.id == profile.id) { styles.activate(profile) }
          }
          NavigationLink {
            StylesView()
          } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
              .font(.subheadline.weight(.medium))
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(Capsule().strokeBorder(BlurtBrand.cardBorder, lineWidth: 1))
          }
        }
        .padding(.vertical, 2)
      }
    }
  }
}

/// One style, as a chip: filled with the accent while active.
private struct StyleChip: View {
  let name: String
  let selected: Bool
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      Text(name)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(Capsule().fill(selected ? BlurtBrand.accent : BlurtBrand.cardFill))
        .overlay(Capsule().strokeBorder(selected ? Color.clear : BlurtBrand.cardBorder, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
