#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

  /// The production `VoiceCommandPerforming`: each step through the system
  /// API that does that one thing — `NSWorkspace` for apps and links, a
  /// synthesized key chord for a shortcut (`+Keys`), a system-defined event
  /// for a media key, Accessibility for a button or a menu item
  /// (`+Accessibility`). Nothing here runs script, and nothing needs a
  /// permission beyond the Accessibility trust the paste already has.
  public struct SystemVoiceCommandPerformer: VoiceCommandPerforming {
    /// The elements the last `screenContext()` numbered, for the steps that
    /// name one.
    let snapshot = ElementSnapshot()
    /// The Chromium browser whose page tree Blurt turned on, to turn off.
    let enhancedInterface = EnhancedInterface()

    /// How long an opened app gets to come frontmost before the next step,
    /// which is aimed at it, goes ahead anyway.
    static let launchBudget: Duration = .seconds(5)
    /// The beat after each step, so the app has handled it before the next
    /// lands: ⌘K's palette has to be open before its search is typed.
    static let settle: Duration = .milliseconds(300)

    /// Where `openApp` looks for an app that isn't running, one level deep.
    static let applicationFolders: [URL] = {
      let folders = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
      ]
      return folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }()

    public init() {}

    public func screenContext() async -> ScreenContext {
      let front = await MainActor.run {
        NSWorkspace.shared.frontmostApplication.map {
          (name: $0.localizedName, pid: $0.processIdentifier, bundle: $0.bundleURL)
        }
      }
      guard let front else { return ScreenContext(appName: nil) }
      return await Self.readScreen(appName: front.name, pid: front.pid, bundleURL: front.bundle, into: snapshot)
    }

    public func commandStarting() async {
      let front = await MainActor.run {
        NSWorkspace.shared.frontmostApplication.map { (pid: $0.processIdentifier, id: $0.bundleIdentifier) }
      }
      guard let front else { return }
      Self.beginEnhancedInterface(pid: front.pid, bundleID: front.id, in: enhancedInterface)
    }

    public func commandEnded() async {
      Self.endEnhancedInterface(in: enhancedInterface)
    }

    public func perform(_ step: VoiceCommandStep) async throws {
      switch step {
      case .openApp, .quitApp, .hideApp: try await performAppStep(step)
      case .openURL(let url):
        guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
          throw VoiceCommandError.couldNotPerform("open \(url.absoluteString)")
        }
      case .shortcut(let chord):
        let code = await Self.keyCode(for: chord)
        guard Self.post(Self.events(for: chord, keyCode: code)) else {
          throw VoiceCommandError.couldNotPerform("press that shortcut")
        }
      case .media(let key):
        guard await Self.post(key) else { throw VoiceCommandError.couldNotPerform("press that key") }
      case .type:
        // Pasted through the session's injector, never here
        // (`DictationSession.typeText`), so a paste can't skip its clipboard
        // save and restore.
        throw VoiceCommandError.couldNotPerform("type outside a paste")
      case .pressButton, .chooseMenuItem, .pressElement, .focusElement, .setValue, .increment, .decrement,
        .showMenu, .select, .scroll, .window:
        try await performScreenStep(step)
      }
      try await Task.sleep(for: Self.settle)
    }

    private func performAppStep(_ step: VoiceCommandStep) async throws {
      switch step {
      // The folders are listed here, off the main actor: a slow home volume
      // must not stall the key tap and the pill.
      case .openApp(let name): try await Self.open(name, installed: Self.installedApp(name))
      case .quitApp(let name): try await Self.running(name).terminate()
      case .hideApp(let name): try await Self.running(name).hide()
      default: break
      }
    }

    private func performScreenStep(_ step: VoiceCommandStep) async throws {
      switch step {
      case .pressButton(let name): try await Self.pressButton(name)
      case .chooseMenuItem(let path): try await Self.chooseMenuItem(path)
      case .pressElement(let id): try await Self.act(on: id, in: snapshot, focus: false)
      case .focusElement(let id): try await Self.act(on: id, in: snapshot, focus: true)
      case .setValue, .increment, .decrement, .showMenu, .select: try await Self.adjust(step, in: snapshot)
      case .scroll(let direction, let element): try await Self.scroll(direction, element: element, in: snapshot)
      case .window(let operation): try await Self.arrangeWindow(operation)
      default: break
      }
    }

    // MARK: - Apps

    /// The running app `name` means, by its displayed name.
    @MainActor
    private static func running(_ name: String) throws -> NSRunningApplication {
      let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
      guard let match = NameMatch.best(for: name, among: apps.compactMap(\.localizedName)),
        let app = apps.first(where: { $0.localizedName == match })
      else { throw VoiceCommandError.appNotRunning(name) }
      return app
    }

    /// Brings the app forward, launching it first if it isn't running, and
    /// waits for it to be frontmost so the next step lands in it. Throws if it
    /// never comes forward: a shortcut or typing meant for it would otherwise
    /// land in whatever app is in front.
    @MainActor
    private static func open(_ name: String, installed: URL?) async throws {
      let app: NSRunningApplication
      if let running = try? running(name) {
        running.unhide()
        running.activate()
        app = running
      } else {
        guard let url = installed else { throw VoiceCommandError.appNotFound(name) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
          app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
          throw VoiceCommandError.couldNotPerform("open \(name)")
        }
      }
      // `activate()` and `activates` are only requests since macOS 14's
      // cooperative activation, honoured when the asking app is active itself,
      // and Blurt never is here: its pill doesn't take focus. So each look
      // that finds the app not yet verified in front asks again and also
      // raises it through Accessibility, which that rule doesn't gate (Peekaboo's
      // loop, MIT). A just-launched app answers once its AX side is up, hence
      // the retry rather than one call.
      let raised = await KeyInjector.poll(
        for: launchBudget, every: .milliseconds(100), clock: ContinuousClock(),
        until: {
          await MainActor.run {
            if isVerifiedFrontmost(app) { return true }
            app.activate()
            raise(app.processIdentifier)
            return false
          }
        })
      // Frontmost but never owning the top window — its window on another
      // Space, or a window server slow to reorder — is in front enough: the
      // keystrokes go to it. Only an app that never came forward fails.
      guard raised || isFrontmost(app.processIdentifier) else {
        throw VoiceCommandError.couldNotPerform("bring \(name) to the front")
      }
    }

    /// The installed app `name` means, by bundle name, in `applicationFolders`.
    private static func installedApp(_ name: String) -> URL? {
      let bundles = applicationFolders.flatMap { folder in
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
          .filter { $0.pathExtension == "app" }
      }
      let names = bundles.map { $0.deletingPathExtension().lastPathComponent }
      guard let match = NameMatch.best(for: name, among: names) else { return nil }
      return bundles.first { $0.deletingPathExtension().lastPathComponent == match }
    }

    /// A media key's press and release: the system-defined events
    /// (`NSEvent.EventSubtype` 8, the auxiliary-key subtype) a keyboard's top
    /// row sends, which the system routes to the volume and Now Playing.
    @MainActor
    private static func post(_ key: MediaKey) -> Bool {
      for keyDown in [true, false] {
        let state = keyDown ? 0xA : 0xB
        guard
          let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
            data1: (key.systemKeyType << 16) | (state << 8), data2: -1)?.cgEvent
        else { return false }
        event.post(tap: .cghidEventTap)
      }
      return true
    }
  }
#endif
