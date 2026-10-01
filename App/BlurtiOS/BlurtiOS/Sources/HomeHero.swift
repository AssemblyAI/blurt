import SwiftUI

/// The hero: the status as an eyebrow, a serif headline and a line of body
/// text, the voice element at hero size, and the one green button that opens
/// the mic (or the hairline one that closes it).
struct HomeHero: View {
  var coordinator: DictationCoordinator
  let status: HomeStatus
  /// When the last dictation's words landed — the hero's glint.
  let landedAt: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  private var state: VoiceState {
    VoiceState(overlay: coordinator.phase.overlayState, windowOpen: coordinator.window.isOpen, level: coordinator.level)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appHeroGap) {
      Eyebrow("Status")
      Text(status.title)
        .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
        .foregroundStyle(BlurtBrand.text)
      Text(status.subtitle)
        .font(BlurtType.body(DesignTokens.Typography.sizeBody))
        .foregroundStyle(BlurtBrand.muted)
      VoiceElementView(
        inputs: VoiceElementInputs(
          state: state, landedAt: landedAt, animated: !reduceMotion,
          palette: colorScheme == .dark ? .brandDark : .brandLight, slot: .home)
      )
      .frame(width: VoiceSlot.home.box.width, height: VoiceSlot.home.box.height)
      .frame(maxWidth: .infinity)
      if coordinator.window.isOpen {
        Button("Stop listening") {
          Task { await coordinator.stopListening() }
        }
        .buttonStyle(BrandButtonStyle(role: .secondary))
      } else {
        Button("Start listening") {
          Task { await coordinator.startListening() }
        }
        .buttonStyle(BrandButtonStyle(role: .primary))
        .disabled(!coordinator.apiKey.hasAPIKey)
      }
      Button(coordinator.phase.isCapturing ? "Stop and transcribe" : "Dictate here, to the clipboard") {
        coordinator.toggleDictation()
      }
      .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
      .foregroundStyle(BlurtBrand.muted)
      .frame(maxWidth: .infinity)
      .disabled(!coordinator.window.isOpen)
      if let error = coordinator.window.lastError {
        note(error)
      }
      if coordinator.microphoneDenied {
        note("Blurt needs the microphone. Allow it in Settings.")
      }
      if coordinator.needsKey {
        note("Add your API key first (Settings → Account).")
      }
    }
    .padding(DesignTokens.Metrics.appHeroPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card(radius: DesignTokens.Metrics.radiusHero)
  }

  private func note(_ text: String) -> some View {
    Text(text).font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.errorOrange)
  }
}
