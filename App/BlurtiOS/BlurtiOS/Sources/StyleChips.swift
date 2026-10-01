import BlurtEngine
import SwiftUI

/// The output styles as chips under their eyebrow: Default and each profile,
/// the active one filled with the accent, rectangular like everything on the
/// brand; Edit opens the styles editor.
struct StyleChips: View {
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var activeRaw = ""
  private let styles = StyleProfileStore()

  private var profiles: [StyleProfile] { styles.profiles(decoding: profilesRaw) }
  private var activeStyle: StyleProfile? { StyleProfileStore.active(in: profiles, id: activeRaw) }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Style")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: DesignTokens.Metrics.appChipGap) {
          StyleChip(name: StyleProfileStore.defaultStyleName, selected: activeStyle == nil) { styles.activateDefault() }
          ForEach(profiles) { profile in
            StyleChip(name: profile.name, selected: activeStyle?.id == profile.id) { styles.activate(profile) }
          }
          NavigationLink {
            StylesView()
          } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
              .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
              .foregroundStyle(BlurtBrand.muted)
              .padding(.horizontal, DesignTokens.Metrics.appChipPadX)
              .padding(.vertical, DesignTokens.Metrics.appChipPadY)
              .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
                  .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
          }
        }
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
        .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
        .padding(.horizontal, DesignTokens.Metrics.appChipPadX)
        .padding(.vertical, DesignTokens.Metrics.appChipPadY)
        .foregroundStyle(selected ? BlurtBrand.ctaText : BlurtBrand.text)
        .background(
          selected ? BlurtBrand.cta : BlurtBrand.cardFill,
          in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
            .strokeBorder(selected ? Color.clear : BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
