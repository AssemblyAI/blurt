import SwiftUI

/// The first-run setup screen. A single page showing everything setup needs at
/// once, top to bottom:
///   1. API Key — paste the AssemblyAI key (copied from the signup page).
///   2. Permissions — Microphone, Accessibility.
/// The dictation shortcut and key terms are intentionally *not* part of
/// onboarding (the shortcut already has a sensible default, and key terms are
/// optional) — both live in the Settings window instead. The main window shows
/// this whenever the app isn't fully configured; once it is, the window swaps to
/// `ReadyView`. There's no Back/Continue/progress chrome — each section reflects
/// its own completion live, and the window swaps to `ReadyView` the instant the
/// last piece lands. The update/version footer is deliberately absent here (it
/// lives on the ready screen and Settings) — onboarding isn't the place to check
/// for updates.
struct WizardView: View {
  var controller: WizardController
  var coordinator: AppCoordinator

  var body: some View {
    VStack(spacing: 0) {
      MainWindowBranding()
        .padding(.top, 16)
      header
      Form {
        // API key first — the reason setup leads with it: a user arriving from
        // the signup page has the key on their clipboard, ready to paste in.
        APIKeyStepView(apiKey: coordinator.apiKey, account: coordinator.account)
        PermissionsStepView(controller: controller)
      }
      .formStyle(.grouped)
      // The window hugs its content (`.fixedSize` below), so the form never needs
      // to scroll — disabling it drops the otherwise-visible scrollbar.
      .scrollDisabled(true)
    }
    // The window uses `.windowResizability(.contentSize)`, so this view's size is
    // the window's size. Pin the shared width (see `MainWindow.contentWidth` — the
    // ready screen this swaps with must match) but let height be content-driven:
    // `.fixedSize` collapses the grouped Form to its ideal height.
    .frame(width: MainWindow.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Set up Blurt")
        .font(.title2)
        .fontWeight(.bold)
      Text(
        coordinator.account.isAvailable
          ? "Sign in, then allow microphone and Accessibility access."
          : "Add your API key, then allow microphone and Accessibility access."
      )
      .font(.body)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    // The standard titlebar provides the traffic-light clearance, so the top
    // inset is just breathing room between the bar and the header.
    .padding(.top, 20)
    .padding(.bottom, 4)
  }
}
