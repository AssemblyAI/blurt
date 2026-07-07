import AppKit
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
      header
      Form {
        // API key first — the reason setup leads with it: a user arriving from
        // the signup page has the key on their clipboard, ready to paste in.
        APIKeyStepView(apiKey: coordinator.apiKey)
        PermissionsStepView(controller: controller)
      }
      .formStyle(.grouped)
      // The window hugs its content (`.fixedSize` below), so the form never needs
      // to scroll — disabling it drops the otherwise-visible scrollbar.
      .scrollDisabled(true)
    }
    // The window uses `.windowResizability(.contentSize)`, so this view's size is
    // the window's size. Pin the width (Apple's common settings-pane width) but
    // let height be content-driven — `.fixedSize` collapses the grouped Form to
    // its ideal height so the window hugs its content like a native settings pane
    // instead of padding out to a hard-coded box.
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 8) {
      OnboardingBrandMark()

      VStack(alignment: .leading, spacing: 4) {
        Text("Set up Blurt")
          .font(.title2)
          .fontWeight(.semibold)
        Text("Add your API key, then allow Microphone and Accessibility access.")
          .font(.body)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    // The window's titlebar is hidden (`.windowStyle(.hiddenTitleBar)` on the
    // main scene), so content extends up behind the traffic-light controls.
    // This leading-aligned header
    // sits exactly under them — inset the top so "Set Up Blurt" clears the
    // controls rather than colliding with them. (ReadyView is centered, so it
    // doesn't need this.)
    .padding(.top, 28)
    .padding(.bottom, 4)
  }
}

private struct OnboardingBrandMark: View {
  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: 30, height: 30)
      .accessibilityHidden(true)
  }
}
