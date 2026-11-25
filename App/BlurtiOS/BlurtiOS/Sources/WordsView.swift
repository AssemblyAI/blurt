import BlurtDesign
import SwiftUI

/// The Words tab: key terms the speech model should spell exactly, and text
/// shortcuts that turn a spoken phrase into longer text. Both apply to every
/// dictation, from the app and from the keyboard, as on Blurt for Mac.
struct WordsView: View {
  var coordinator: DictationCoordinator
  let showSettings: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
        HStack {
          Text("Words")
            .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
            .foregroundStyle(BlurtBrand.text)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          SettingsButton(action: showSettings)
        }
        .frame(height: DesignTokens.Metrics.appHeaderHeight)
        KeyTermsCard(contactNames: coordinator.lexiconNameCount)
        TextShortcutsCard()
      }
      .padding(.horizontal, DesignTokens.Metrics.appPagePad)
      .padding(.bottom, DesignTokens.Metrics.appSectionGap)
    }
    .scrollDismissesKeyboard(.interactively)
    .page()
  }
}
