#if os(macOS)
  import AppKit
  import ApplicationServices
  import CoreGraphics

  /// The production `VoiceCommandPerforming`: each step through the system
  /// API that does that one thing — `NSWorkspace` for apps and links, a
  /// synthesized key chord for a shortcut (`VoiceCommandKeys`), a system-defined event
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
    /// The beat between steps (`VoiceCommandPerforming.settle`): ⌘K's palette
    /// has to be open before its search is typed.
    public var settle: Duration { .milliseconds(300) }

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
          (name: $0.localizedName, pid: $0.processIdentifier, id: $0.bundleIdentifier, bundle: $0.bundleURL)
        }
      }
      guard let front else { return ScreenContext(appName: nil) }
      return await Self.readScreen(
        appName: front.name, pid: front.pid,
        isChromium: front.id.map(ScreenSnapshot.chromiumBrowsers.contains) ?? false,
        isElectron: FocusCapture.isElectronBundle(front.bundle), into: snapshot)
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

    public func perform(_ step: VoiceCommandStep) async throws -> String? {
      switch step {
      case .openApp, .quitApp, .hideApp: return try await performAppStep(step)
      case .openURL(let url):
        guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
          throw VoiceCommandError.couldNotPerform("open \(url.absoluteString)")
        }
        return nil
      case .shortcut(let chord):
        let code = await Self.keyCode(for: chord)
        // Posted as the paste's ⌘V is (`KeyInjector.post`): the annotated
        // session tap, after the trigger's own, so it never reads as a combo.
        guard KeyInjector.post(Self.events(for: chord, keyCode: code)) else {
          throw VoiceCommandError.couldNotPerform("press that shortcut")
        }
        // The key it landed on, on this layout: what a wrong-key report needs.
        return "key code \(code)"
      case .media(let key):
        guard await Self.post(key) else { throw VoiceCommandError.couldNotPerform("press that key") }
        return nil
      case .type:
        // Pasted through the session's injector, never here
        // (`DictationSession.typeText`), so a paste can't skip its clipboard
        // save and restore.
        throw VoiceCommandError.couldNotPerform("type outside a paste")
      case .pressButton, .chooseMenuItem, .pressElement, .focusElement, .setValue, .increment, .decrement,
        .showMenu, .select, .scroll, .window:
        return try await performScreenStep(step)
      }
    }

    private func performAppStep(_ step: VoiceCommandStep) async throws -> String? {
      switch step {
      case .openApp(let name): return try await Self.open(name)
      case .quitApp(let name): try await Self.running(name).terminate()
      case .hideApp(let name): try await Self.running(name).hide()
      default: break
      }
      return nil
    }

    private func performScreenStep(_ step: VoiceCommandStep) async throws -> String? {
      switch step {
      case .pressButton(let name): return try await Self.pressButton(name)
      case .chooseMenuItem(let path): try await Self.chooseMenuItem(path)
      case .pressElement(let id): return try await Self.act(on: id, in: snapshot, focus: false)
      case .focusElement(let id): return try await Self.act(on: id, in: snapshot, focus: true)
      case .setValue, .increment, .decrement, .showMenu, .select: return try await Self.adjust(step, in: snapshot)
      case .scroll(let direction, let element):
        return try await Self.scroll(direction, element: element, in: snapshot)
      case .window(let operation): return try await Self.arrangeWindow(operation)
      default: break
      }
      return nil
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
    private static func open(_ name: String) async throws -> String {
      // Blurt itself: activated by its own `NSApp`, not raised through
      // Accessibility — an AX call to its own process from its own main thread
      // waits on that thread, and timed out every time ("couldn't bring Blurt
      // to the front", 2026-11-03).
      if let me = try? running(name), me == NSRunningApplication.current {
        NSApp.unhide(nil)
        NSApp.activate()
        return "Blurt itself, by NSApp"
      }
      let app: NSRunningApplication
      let how: String
      if let running = try? running(name) {
        running.unhide()
        running.activate()
        app = running
        how = "already running"
      } else {
        // Only now list the folders, off the main actor: a slow home volume
        // must not stall the key tap and the pill, and a running app needs none.
        let installed = await Task.detached { installedApp(name) }.value
        guard let url = installed else { throw VoiceCommandError.appNotFound(name) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
          app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
          how = "launched from \(url.deletingLastPathComponent().path(percentEncoded: false))"
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
      return raised ? how : how + "; frontmost but its window wasn't on top"
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
