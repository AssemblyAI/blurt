import SwiftUI

/// The hero: the keyboard's voice element at hero size, with the listening
/// state in words under it and the one button that opens or closes the mic.
struct HomeHero: View {
  var coordinator: DictationCoordinator
  let status: HomeStatus
  /// When the last dictation's words landed — the hero's drop.
  let landedAt: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Environment(\.colorScheme) private var colorScheme

  private var state: VoiceState {
    VoiceState(overlay: coordinator.phase.overlayState, windowOpen: coordinator.window.isOpen, level: coordinator.level)
  }

  var body: some View {
    VStack(spacing: 18) {
      VoiceElementView(
        inputs: VoiceElementInputs(
          state: state, landedAt: landedAt, animated: !reduceMotion,
          palette: colorScheme == .dark ? .brandDark : .brandLight, slot: .home)
      )
      .frame(width: VoiceSlot.home.box.width, height: VoiceSlot.home.box.height)
      .padding(.top, 6)
      VStack(spacing: 4) {
        Text(status.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
        Text(status.subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      if coordinator.window.isOpen {
        Button(role: .destructive) {
          Task { await coordinator.stopListening() }
        } label: {
          Text("Stop listening").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      } else {
        Button {
          Task { await coordinator.startListening() }
        } label: {
          Text("Start listening").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!coordinator.apiKey.hasAPIKey)
      }
      Button(coordinator.phase.isCapturing ? "Stop and transcribe" : "Dictate here, to the clipboard") {
        coordinator.toggleDictation()
      }
      .font(.callout)
      .disabled(!coordinator.window.isOpen)
      if let error = coordinator.window.lastError {
        Text(error).font(.footnote).foregroundStyle(BlurtBrand.errorOrange).multilineTextAlignment(.center)
      }
      if coordinator.microphoneDenied {
        Text("Blurt needs the microphone. Allow it in Settings.")
          .font(.footnote).foregroundStyle(BlurtBrand.errorOrange)
      }
      if coordinator.needsKey {
        Text("Add your API key first (Settings → Account).")
          .font(.footnote).foregroundStyle(BlurtBrand.errorOrange)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .card()
  }
}
