import BlurtAssemblyAI
import BlurtEngine
import BlurtiOSCore
import SwiftUI

@main
struct BlurtiOSApp: App {
  private static var isTestHost: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// `-BlurtNoKey`: a fresh install's view of the key, in memory, so the
  /// first-run screen can be screenshotted without touching the Keychain's;
  /// debug builds only.
  private static var isKeyless: Bool {
    #if DEBUG
      CommandLine.arguments.contains("-BlurtNoKey")
    #else
      false
    #endif
  }

  /// `-BlurtUITestKey`: a set-up install's view of the key, in memory, so the
  /// accessibility audits (`BlurtiOSUITests`) reach the tabs without a real key
  /// in the simulator's Keychain; debug builds only. Nothing is sent with it:
  /// the audits never open the listening window.
  private static var isUITestKeyed: Bool {
    #if DEBUG
      CommandLine.arguments.contains("-BlurtUITestKey")
    #else
      false
    #endif
  }

  @State private var coordinator: DictationCoordinator

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let probe = KeyboardProbeView.parse(CommandLine.arguments, store: coordinator.store) {
          // The keyboard over this field is only live if the app runs as it
          // does under the home screen: the coordinator up, listening on request.
          probe.task { await start() }
        } else if CommandLine.arguments.contains("-BlurtTypingTest") {
          // The easter egg as the root, for a screenshot without a tap.
          TypingTestView()
        } else if CommandLine.arguments.contains("-BlurtSettings") {
          // The settings sheet as the root, for a screenshot without a tap.
          SettingsView(coordinator: coordinator)
        } else if CommandLine.arguments.contains("-BlurtImportTerms") {
          // A shared key-term list as it opens, for the audits without a
          // round trip through Messages.
          ImportTermsView(
            pack: TermPack(name: "Design team", from: "Alex", terms: ["Blurt", "AssemblyAI", "Figma", "Kubernetes"]),
            store: coordinator.store
          )
        } else if CommandLine.arguments.contains("-BlurtKeepOpen") {
          // The app-switcher card as the root, for a screenshot or a recording
          // without a trip to the switcher; `-BlurtGalleryStill` holds it at
          // time zero.
          KeepOpenView(
            windowMinutes: coordinator.store.windowMinutes, still: CommandLine.arguments.contains("-BlurtGalleryStill")
          )
        } else {
          home
        }
      #else
        home
      #endif
    }
  }

  private var home: some View {
    RootView(coordinator: coordinator)
      .task {
        await start()
        #if DEBUG
          // The consent sheet over home, as turning a session on raises it, for
          // the audits without that tap: the first tap after a fresh install's
          // launch can land before the app takes touches, and the switch stays
          // off (PR #451's merge-queue recording).
          if CommandLine.arguments.contains("-BlurtAskConsent") { coordinator.needsConsent = true }
        #endif
      }
  }

  /// The composition root, and the first thing that runs: the engine's identity
  /// has to be set before any engine type is touched (`HostIdentity.configure`
  /// documents why), and the coordinator below touches the Keychain in its
  /// initializer. The identity is the iPhone app's own — its Keychain item is
  /// separate from the Mac app's by construction, since Keychains are per
  /// device, but naming it separately keeps the two builds' data apart the day
  /// they share an iCloud Keychain. The defaults prefix stays `Blurt` so the
  /// engine's stores read and write the same keys they do on the Mac. The log
  /// subsystem is the contract's (`BlurtShared.logSubsystem`): the keyboard
  /// logs under the same string, so one predicate reads both processes.
  init() {
    HostIdentity.configure(
      HostIdentity(
        productName: "Blurt",
        subsystem: BlurtShared.logSubsystem,
        keychainService: "blurt-ios",
        defaultsPrefix: "Blurt",
        logDirectoryName: "Blurt",
        // Styles live in a scrolling list here, not the Mac's five-button
        // switcher, so the phone allows far more than its four.
        styleProfileLimit: 100
      )
    )
    #if DEBUG
      // `BLURT_DEBUG_API_KEY` (through simctl as `SIMCTL_CHILD_BLURT_DEBUG_API_KEY`)
      // puts a key in a simulator's Keychain without typing it, so a fresh
      // simulator can open the listening window from a script; debug builds only.
      if let key = ProcessInfo.processInfo.environment["BLURT_DEBUG_API_KEY"], !key.isEmpty, !Self.isTestHost {
        _ = APIKeyStore.save(key)
      }
      // The developer log and the device trace survive the hop's relaunch.
      if !Self.isTestHost { LaunchFlags.persist() }
    #endif
    // The App Group, handed to everything that reads or writes it from here
    // (`SharedStore`). The unit tests are hosted by this app: they get a
    // coordinator that touches neither the Keychain nor the App Group (the
    // Mac's UITestSupport does the same for its harness) — a scratch suite of
    // its own, as every test builds — and `start()` below never runs.
    let store: SharedStore = Self.isTestHost ? .scratch("test-host") : .live
    let window = ListeningWindow(store: store)
    let initialCoordinator =
      Self.isTestHost || Self.isKeyless || Self.isUITestKeyed
      ? DictationCoordinator(
        window: window, defaults: .standard, apiKey: APIKeyModel(keyStore: Self.inMemoryKeyStore())
      )
      : DictationCoordinator(window: window, defaults: .standard)
    _coordinator = State(initialValue: initialCoordinator)
  }

  /// The in-memory store the test host, `-BlurtNoKey` and `-BlurtUITestKey`
  /// read, holding a placeholder key only under `-BlurtUITestKey`.
  private static func inMemoryKeyStore() -> InMemoryAPIKeyStore {
    let store = InMemoryAPIKeyStore()
    if isUITestKeyed { store.save("uitest-key") }
    return store
  }

  private func start() async {
    guard !Self.isTestHost else {
      return
    }
    coordinator.start()
    #if DEBUG
      // `-BlurtStartListening` opens the mic at launch, so the listening
      // state can be screenshotted without a tap (see scripts/ios-sim.sh).
      // Asking for it stands in for consent, which a screenshot or probe run
      // can't tap through; debug builds only.
      if CommandLine.arguments.contains("-BlurtStartListening") { await coordinator.grantConsent() }
    #endif
  }
}
