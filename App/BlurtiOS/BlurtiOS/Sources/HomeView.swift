import AVFoundation
import BlurtEngine
import SwiftUI
import UIKit

/// The app's one screen, in the shape of the Mac's ready screen: the wordmark,
/// the orb as the hero with the listening state under it, the style chips,
/// and the recent dictations as cards. Setup sits on top while anything is
/// missing; everything adjustable lives behind the gear.
struct HomeView: View {
  var coordinator: DictationCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen
  @State private var showsKeyEntry = false
  @State private var showsSettings = false
  /// When the last dictation's words landed — the hero's drop.
  @State private var landedAt: Date?
  @AppStorage(StyleProfileStore.defaultsKey) private var profilesRaw = ""
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var activeRaw = ""
  private let styles = StyleProfileStore()

  private var isSetUp: Bool { coordinator.apiKey.hasAPIKey && microphoneGranted && keyboardSeen }
  private var profiles: [StyleProfile] { styles.profiles(decoding: profilesRaw) }
  private var activeStyle: StyleProfile? { StyleProfileStore.active(in: profiles, id: activeRaw) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          if !isSetUp { setupCard }
          hero
          styleChips
          recent
          poweredBy
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) { Wordmark() }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showsSettings = true
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
      .sheet(isPresented: $showsKeyEntry) { KeyEntryView(apiKey: coordinator.apiKey) }
      .sheet(isPresented: $showsSettings) { SettingsView(coordinator: coordinator) }
      .sheet(item: Binding(get: { coordinator.pendingTermPack }, set: { coordinator.pendingTermPack = $0 })) {
        ImportTermsView(pack: $0)
      }
      .alert(
        "Couldn't read that list",
        isPresented: Binding(get: { coordinator.termPackUnreadable }, set: { coordinator.termPackUnreadable = $0 })
      ) {
        Button("OK") {}
      } message: {
        Text("It isn't a Blurt key-term list, or it's too big.")
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshStatus() }
      }
      .onChange(of: coordinator.phase) { _, phase in
        switch phase.overlayState {
        case .pasted, .noTarget: landedAt = Date()
        default: break
        }
      }
    }
    .tint(BlurtBrand.accent)
  }

  private func refreshStatus() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }

  // MARK: - The orb and the listening state

  private static let orbSize = DesignTokens.Metrics.orbHome
  /// The wave at hero size: wide and slim, inside the card at any phone width.
  private static let waveReach = DesignTokens.Metrics.waveHomeWidth
  private static let waveHeight = DesignTokens.Metrics.waveHomeHeight
  private var isRecording: Bool { coordinator.phase == .recording }
  private var orbWorking: Bool { coordinator.window.isOpen || coordinator.phase.isCapturing }

  private var hero: some View {
    VStack(spacing: 18) {
      // The keyboard's mic key at hero size: the orb, dissipating into the
      // thin wave while recording and condensing back after, as the key does.
      ZStack {
        if isRecording {
          WaveformMeter(
            level: coordinator.level, animated: !reduceMotion, color: BlurtBrand.accent,
            barWidth: WaveformMeter.slimBar, barSpacing: WaveformMeter.slimGap
          )
          .frame(width: Self.waveReach, height: Self.waveHeight)
          .transition(.opacity)
        } else {
          PrismOrb(mood: heroMood, landedAt: landedAt, animated: !reduceMotion)
            .frame(width: Self.orbSize, height: Self.orbSize)
            .clipShape(Circle())
            .overlay { HeroRing(animated: orbWorking && !reduceMotion) }
            .saturation(coordinator.window.isOpen ? 1 : DesignTokens.Metrics.opacityHomeDimSaturation)
            .transition(reduceMotion ? .opacity : .dissipate(size: Self.orbSize))
        }
      }
      // The wave's width throughout, so nothing shifts while the two cross.
      .frame(width: Self.waveReach, height: Self.orbSize)
      .animation(.easeInOut(duration: MicKey.waveFade), value: isRecording)
      .animation(.easeInOut(duration: MicKey.stateFade), value: coordinator.window.isOpen)
      .padding(.top, 6)
      VStack(spacing: 4) {
        Text(heroTitle).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
        Text(heroSubtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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

  private var heroMood: PrismOrb.Mood {
    guard coordinator.window.isOpen else { return .off }
    switch coordinator.phase.overlayState {
    case .idle, .error, .pasted, .noTarget: return .idle
    case .connecting: return .listening(level: 0)
    case .recording: return .listening(level: coordinator.level)
    case .processing: return .working
    }
  }

  private var heroTitle: String {
    switch coordinator.phase.overlayState {
    case .connecting: return "Connecting…"
    case .recording: return "Listening…"
    case .processing: return "Transcribing…"
    case .pasted: return "Pasted"
    case .noTarget: return "Copied"
    case .error(let message): return message
    case .idle: return coordinator.window.isOpen ? "Ready to dictate" : "Not listening"
    }
  }

  private var heroSubtitle: String {
    guard coordinator.window.isOpen else {
      return "Open the mic so the Blurt keyboard can dictate anywhere you type."
    }
    if let until = coordinator.window.until, until != .distantFuture {
      return "Until \(until.formatted(date: .omitted, time: .shortened)) · tap the mic on the Blurt keyboard."
    }
    return "Until you stop it · tap the mic on the Blurt keyboard."
  }

  // MARK: - Styles

  private var styleChips: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Style").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          StyleChip(name: StyleProfileStore.defaultStyleName, selected: activeStyle == nil) { styles.activateDefault() }
          ForEach(profiles) { profile in
            StyleChip(name: profile.name, selected: activeStyle?.id == profile.id) { styles.activate(profile) }
          }
          NavigationLink {
            StylesView()
          } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
              .font(.subheadline.weight(.medium))
              .padding(.horizontal, 14)
              .padding(.vertical, 8)
              .background(Capsule().strokeBorder(BlurtBrand.cardBorder, lineWidth: 1))
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private var recent: some View { RecentSection(coordinator: coordinator) }

  private var poweredBy: some View {
    HStack(spacing: 3) {
      Text("Powered by").foregroundStyle(.secondary)
      Text("AssemblyAI").fontWeight(.medium)
    }
    .font(.caption)
    .padding(.top, 4)
  }

  // MARK: - Setup

  private var setupCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Set up Blurt").font(.headline)
      SetupRow(done: coordinator.apiKey.hasAPIKey, title: "Sign in with AssemblyAI") {
        VStack(alignment: .leading, spacing: 6) {
          Text("Coming soon — sign-in needs the AssemblyAI login service.")
            .font(.footnote).foregroundStyle(.secondary)
          #if DEBUG
            Button("Use an API key instead") { showsKeyEntry = true }
          #endif
        }
      }
      SetupRow(done: microphoneGranted, title: "Allow the microphone") {
        if AVAudioApplication.shared.recordPermission == .denied {
          // iOS asks once; after a refusal only Settings can change it.
          Button("Allow in Settings") { openAppSettings() }
        } else {
          Button("Allow") {
            Task {
              _ = await AVAudioApplication.requestRecordPermission()
              refreshStatus()
            }
          }
        }
      }
      SetupRow(done: keyboardSeen, title: "Add the Blurt keyboard") {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Settings → Keyboards: turn on Blurt and Allow Full Access. "
              + "Full Access is what lets the keyboard send your words to Blurt."
          )
          .font(.footnote).foregroundStyle(.secondary)
          Button("Open Settings") { openAppSettings() }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

/// One style, as a chip: filled with the accent while active.
private struct StyleChip: View {
  let name: String
  let selected: Bool
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      Text(name)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(Capsule().fill(selected ? BlurtBrand.accent : BlurtBrand.cardFill))
        .overlay(Capsule().strokeBorder(selected ? Color.clear : BlurtBrand.cardBorder, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// One line of the setup checklist: a check or a circle, the step, and its
/// control while it is still to do.
private struct SetupRow<Action: View>: View {
  let done: Bool
  let title: String
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? BlurtBrand.accent : Color.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
        if !done { action() }
      }
    }
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
                time: timeline.date.timeIntervalSinceReferenceDate, period: BrandOrb.period)))
      }
    } else {
      Circle().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: DesignTokens.Metrics.ringActive)
    }
  }
}

/// The recent dictations as cards, with a copy button each.
private struct RecentSection: View {
  var coordinator: DictationCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recent").font(.headline)
      if coordinator.recent.displayed.isEmpty {
        Text("Your recent blurts will appear here.")
          .font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .card()
      }
      ForEach(coordinator.recent.displayed) { entry in
        VStack(alignment: .leading, spacing: 8) {
          Text(entry.text).font(.body).lineLimit(3)
          HStack(spacing: 8) {
            if let style = entry.style {
              Text(style)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(BlurtBrand.accent.opacity(0.15)))
            }
            Text(entry.relativeLabel(now: Date())).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
              UIPasteboard.general.string = entry.text
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
          }
        }
        .padding(16)
        .card()
      }
    }
  }
}
