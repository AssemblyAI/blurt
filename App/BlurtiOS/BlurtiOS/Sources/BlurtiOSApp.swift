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
    // The unit tests are hosted by this app: they get a coordinator that
    // touches neither the Keychain nor the App Group (the Mac's UITestSupport
    // does the same for its harness), and `start()` below never runs.
    let coordinator =
      Self.isTestHost
      ? DictationCoordinator(apiKey: APIKeyModel(keyStore: InMemoryAPIKeyStore())) : DictationCoordinator()
    _coordinator = State(initialValue: coordinator)
  }

  private static var isTestHost: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        let rows = KeyboardGalleryView.rows(from: CommandLine.arguments)
        if rows.isEmpty {
          home
        } else {
          KeyboardGalleryView(rows: rows)
        }
      #else
        home
      #endif
    }
  }

  private var home: some View {
    HomeView(coordinator: coordinator)
      .onOpenURL { coordinator.handle($0) }
      .task {
        guard !Self.isTestHost else { return }
        coordinator.start()
        #if DEBUG
          // `-BlurtStartListening` opens the mic at launch, so the listening
          // state can be screenshotted without a tap (see scripts/ios-sim.sh).
          if CommandLine.arguments.contains("-BlurtStartListening") { await coordinator.startListening() }
        #endif
      }
  }
}
