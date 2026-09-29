import BlurtEngine
import SwiftUI

/// The hero: the keyboard's mic control at hero size — the orb, dissipating
/// into the thin wave while recording and condensing back after, as the
/// key does — with the listening state in words under it and the one button
/// that opens or closes the mic.
struct HomeHero: View {
  var coordinator: DictationCoordinator
  let status: HomeStatus
  /// When the last dictation's words landed — the hero's drop.
  let landedAt: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let orbSize = DesignTokens.Metrics.orbHome
  /// The wave at hero size: wide and slim, inside the card at any phone width.
  private static let waveReach = DesignTokens.Metrics.waveHomeWidth
  private static let waveHeight = DesignTokens.Metrics.waveHomeHeight

  private var state: VoiceState {
    VoiceState(overlay: coordinator.phase.overlayState, windowOpen: coordinator.window.isOpen, level: coordinator.level)
  }
  private var isRecording: Bool { coordinator.phase == .recording }
  private var orbWorking: Bool { coordinator.window.isOpen || coordinator.phase.isCapturing }

  var body: some View {
    VStack(spacing: 18) {
      ZStack {
        if isRecording {
          WaveformMeter(
            level: coordinator.level, animated: !reduceMotion, color: BlurtBrand.accent,
            barWidth: WaveformMeter.slimBar, barSpacing: WaveformMeter.slimGap
          )
          .frame(width: Self.waveReach, height: Self.waveHeight)
          .transition(.opacity)
        } else {
          PrismOrb(mood: MicControl.mood(state), landedAt: landedAt, animated: !reduceMotion)
            .frame(width: Self.orbSize, height: Self.orbSize)
            .clipShape(Circle())
            .overlay { HeroRing(animated: orbWorking && !reduceMotion) }
            .saturation(coordinator.window.isOpen ? 1 : DesignTokens.Metrics.opacityHomeDimSaturation)
            .transition(reduceMotion ? .opacity : .dissipate(size: Self.orbSize))
        }
      }
      // The wave's width throughout, so nothing shifts while the two cross.
      .frame(width: Self.waveReach, height: Self.orbSize)
      .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: isRecording)
      .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: coordinator.window.isOpen)
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

/// The hero orb's ring: the brand orb's sweep, on its own so the prism can
/// be the fill.
private struct HeroRing: View {
  let animated: Bool

  var body: some View {
    if animated {
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
        Circle()
          .strokeBorder(BlurtBrand.orbRingGradient, lineWidth: DesignTokens.Metrics.ringActive)
          .rotationEffect(
            .degrees(
              MeterBarGeometry.rotationDegrees(
                time: timeline.date.timeIntervalSinceReferenceDate, period: KeyboardMotion.ringPeriod)))
      }
    } else {
      Circle().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: DesignTokens.Metrics.ringActive)
    }
  }
}
