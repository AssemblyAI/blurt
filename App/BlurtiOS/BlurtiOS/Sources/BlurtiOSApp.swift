import BlurtEngine
import SwiftUI

@main
struct BlurtiOSApp: App {
  @State private var coordinator: DictationCoordinator

  /// The composition root, and the first thing that runs: the engine's identity
  /// has to be set before any engine type is touched (`HostIdentity.configure`
  /// documents why), and the coordinator below touches the Keychain in its
  /// initializer. The identity is the iPhone app's own — its Keychain item is
  /// separate from the Mac app's by construction, since Keychains are per
  /// device, but naming it separately keeps the two builds' data apart the day
  /// they share an iCloud Keychain. The defaults prefix stays `Blurt` so the
  /// engine's stores read and write the same keys they do on the Mac.
  init() {
    HostIdentity.configure(
      HostIdentity(
        productName: "Blurt",
        subsystem: "dev.alex.blurt.ios",
        keychainService: "blurt-ios",
        defaultsPrefix: "Blurt",
        logDirectoryName: "Blurt",
        releaseURL: HostIdentity.blurt.releaseURL))
    _coordinator = State(initialValue: DictationCoordinator())
  }

  var body: some Scene {
    WindowGroup {
      HomeView(coordinator: coordinator)
        .onOpenURL { coordinator.handle($0) }
        .task { coordinator.start() }
    }
  }
}
