import SwiftUI

/// The brand's tab bar, in place of the system one: each tab's icon over its
/// mono uppercase label, the selected tab in the accent and the rest muted, a
/// hairline above. The tabs are the caller's; this only draws and selects.
package struct BrandTabBar<Tab: Hashable & Identifiable>: View {
  let tabs: [Tab]
  @Binding var selection: Tab
  let label: (Tab) -> String
  /// An SF Symbol; the selected tab draws its `.fill` variant.
  let symbol: (Tab) -> String

  package init(
    _ tabs: [Tab], selection: Binding<Tab>, label: @escaping (Tab) -> String, symbol: @escaping (Tab) -> String
  ) {
    self.tabs = tabs
    _selection = selection
    self.label = label
    self.symbol = symbol
  }

  package var body: some View {
    HStack(spacing: 0) {
      ForEach(tabs) { tab in
        let isSelected = tab == selection
        Button {
          selection = tab
        } label: {
          VStack(spacing: DesignTokens.Metrics.appTabGap) {
            Image(systemName: isSelected ? symbol(tab) + ".fill" : symbol(tab))
              .font(.system(size: DesignTokens.Typography.sizeTabIcon, weight: DesignTokens.Typography.weightGlyph))
            Text(label(tab).uppercased())
              .font(BlurtType.mono(DesignTokens.Typography.sizeTabLabel, weight: .medium))
              .tracking(DesignTokens.Typography.trackingEyebrow)
          }
          .foregroundStyle(isSelected ? BlurtBrand.accent : BlurtBrand.muted)
          .frame(maxWidth: .infinity, minHeight: DesignTokens.Metrics.appTabHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(tab))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      }
    }
    .padding(.top, DesignTokens.Metrics.appLineGap)
    .background(BlurtBrand.page)
    .overlay(alignment: .top) {
      Rectangle().fill(BlurtBrand.cardBorder).frame(height: DesignTokens.Metrics.cardBorder)
    }
    .animation(.easeInOut(duration: DesignTokens.Motion.colour), value: selection)
  }
}
