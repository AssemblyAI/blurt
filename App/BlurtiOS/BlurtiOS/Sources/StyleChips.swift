import BlurtDesign
import BlurtEngine
import SwiftUI

/// The output styles as chips under their eyebrow: Default and each profile,
/// the active one filled with the accent, rectangular like everything on the
/// brand; Edit opens the styles editor.
struct StyleChips: View {
  @AppStorage(StyleProfileStore.defaultsKey)
  private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey)
  private var activeRaw = ""
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
              .bodyFont(DesignTokens.Typography.sizeCaption, bold: true)
              .foregroundStyle(BlurtBrand.muted)
              .padding(.horizontal, DesignTokens.Metrics.appChipPadX)
              .padding(.vertical, DesignTokens.Metrics.appChipPadY)
              .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
                  .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder)
              )
          }
        }
      }
    }
  }
}
