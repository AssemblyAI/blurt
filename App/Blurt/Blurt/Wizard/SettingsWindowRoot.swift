import SwiftUI

/// Root view of the `Settings` scene. A `TabView` at the root of a `Settings`
/// scene renders as the standard macOS preferences window — a segmented toolbar
/// of panes (General / Keys / Sounds / Read Aloud / Styles / Vocabulary / Advanced), each sized to its own content. This is the
/// HIG-native answer to a settings screen that outgrows one pane: keeping every
/// pane short means the window never has to grow past a small display (a single
/// stacked `Form` did, stranding the bottom section off-screen). Each pane
/// reuses the same section views the wizard's setup step uses, so the two stay
/// in sync.
struct SettingsWindowRoot: View {
  var appDelegate: AppDelegate

  var body: some View {
    if let coordinator = appDelegate.coordinator {
      // Leave selection to the system: macOS Settings windows conventionally
      // restore the most recently viewed pane. UI tests navigate to General in
      // their helper instead of changing production behavior for determinism.
      TabView {
        GeneralSettingsTab(coordinator: coordinator)
          .tabItem { Label(UITestIdentifiers.generalSettingsTab, systemImage: "gearshape") }
        KeysSettingsTab(coordinator: coordinator)
          .tabItem { Label(UITestIdentifiers.keysSettingsTab, systemImage: "keyboard") }
        SoundsSettingsTab(coordinator: coordinator)
          .tabItem { Label(UITestIdentifiers.soundsSettingsTab, systemImage: "bell") }
        ReadAloudSettingsTab(coordinator: coordinator)
          .tabItem { Label(UITestIdentifiers.readAloudSettingsTab, systemImage: "speaker.wave.2") }
        StylesSettingsTab()
          .tabItem { Label(UITestIdentifiers.stylesSettingsTab, systemImage: "textformat") }
        VocabularySettingsTab()
          .tabItem {
            Label(UITestIdentifiers.vocabularySettingsTab, systemImage: "character.book.closed")
          }
        AdvancedSettingsTab(coordinator: coordinator, updaterModel: appDelegate.updaterModel)
          .tabItem { Label(UITestIdentifiers.advancedSettingsTab, systemImage: "gearshape.2") }
      }
      .frame(width: MainWindow.contentWidth)
    } else {
      Color.clear.frame(width: MainWindow.contentWidth, height: 240)
    }
  }
}
