import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// The session card: "Session on" or "Session
/// off" with the switch that turns it on and off, one line about it, and
/// "Try it here", a box to try the Blurt keyboard in without leaving the app
/// (`TryItBox`). The phases of a dictation stay on the keyboard, where the user
/// is typing; only a failure is said here.
struct HomeHero: View {
  var coordinator: DictationCoordinator
  let status: HomeStatus

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appHeroGap) {
      if coordinator.startedFromKeyboard, status.isOn {
        ReturnHint()
      }
      // The session and its line read as one thing, so they sit close.
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
        HStack {
          Eyebrow(status.label, color: status.isOn ? BlurtBrand.accent : BlurtBrand.muted)
          Spacer()
          if coordinator.microphoneDenied {
            Button("Open Settings") { SystemSettings.open() }
              .buttonStyle(BrandButtonStyle())
              .fixedSize()
          } else {
            Toggle("Session", isOn: session)
              .labelsHidden()
              .tint(BlurtBrand.accent)
              .disabled(!coordinator.apiKey.hasAPIKey)
          }
        }
        Text(status.message)
          .font(BlurtType.body(DesignTokens.Typography.sizeBody))
          .foregroundStyle(BlurtBrand.text)
          .fixedSize(horizontal: false, vertical: true)
      }
      TryItBox()
      if let error = status.error ?? coordinator.window.lastError {
        note(error)
      }
      if coordinator.needsKey {
        note("Add your API key first (Settings → Account).")
      }
      if coordinator.needsFullAccess {
        note("The Blurt keyboard needs Full Access to dictate: Settings › Apps › Blurt › Keyboards.")
      }
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card(radius: DesignTokens.Metrics.radiusHero)
  }

  /// The switch is the session, which is the listening window as its record
  /// says it (opening, open or paused): on opens it (with its key, consent
  /// and microphone gates), off closes it and keeps it closed until the user
  /// asks again (`SessionAutoStart`).
  private var session: Binding<Bool> {
    Binding(
      get: { status.isOn },
      set: { on in
        if on {
          Task { await coordinator.turnSessionOn() }
        } else {
          coordinator.turnSessionOff()
        }
      })
  }

  private func note(_ text: String) -> some View {
    Text(text).font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.errorOrange)
  }
}

/// After the keyboard brought Blurt forward to start a session: points at
/// iOS's own back link, "◀ Notes" or whichever app it was, in place of the
/// clock at the top left — the one way back to the app the user was typing in
/// (an app can't return there itself).
private struct ReturnHint: View {
  var body: some View {
    Label("To keep typing, tap “◀” with the app's name in the top-left corner.", systemImage: "arrow.up.left")
      .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
      .foregroundStyle(BlurtBrand.ctaText)
      .padding(DesignTokens.Metrics.appChipPadX)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BlurtBrand.cta, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput))
  }
}
