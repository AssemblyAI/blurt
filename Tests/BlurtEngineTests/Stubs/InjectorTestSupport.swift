#if os(macOS)
  import AppKit
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// Shared fixtures for the `KeyInjector.insert` suites (the main insert suite
  /// and the fallback/cancel suite live in separate files to stay within the
  /// lint file-length budget, but drive the injector the same way).
  ///
  /// The boxes beside this file (`AsyncGate`, `StringListBox`, `ValueBox`) are
  /// classes over `Mutex` (not actors) because they're poked from synchronous
  /// `@Sendable` seams like `postPaste`; the `Mutex` makes each `Sendable`
  /// conformance compiler-checked instead of `@unchecked`-asserted.

  /// Some live application to stand in as the captured paste target.
  func liveTargetApp() throws -> NSRunningApplication {
    try #require(
      NSWorkspace.shared.runningApplications.first { app in
        app.processIdentifier > 0 && !app.isTerminated
      })
  }

  /// That application as the `CapturedFocus` `KeyInjector.setTarget` takes, so the
  /// insert suites pin a target the way `DictationSession` does.
  func liveTargetFocus() throws -> CapturedFocus {
    let app = try liveTargetApp()
    return CapturedFocus(pid: app.processIdentifier, processName: app.localizedName)
  }

  /// A `KeyInjector` wired to an in-memory clipboard, with `postPaste` recording
  /// each pasted string (captured after `setString`, before the deferred
  /// restore) into the returned box — for the end-to-end case that pins `insert`
  /// threading its resolution through to the paste. (The continuity rules
  /// themselves are cases of `resolveInsert` and need no injector at all.)
  /// `secondsSinceUserInput` stands in for the HID idle counters; the default
  /// reports no keyboard or mouse input ever.
  func makeRecordingInjector(
    secondsSinceUserInput: @escaping @Sendable () -> TimeInterval = { .infinity }
  ) -> (injector: KeyInjector, pasted: StringListBox) {
    let clip = FakeClipboard(string: nil)
    let pasted = StringListBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: { _ in
        pasted.append(clip.string)
        return true
      },
      // Stub the activation. Omitting this defaulted to `KeyInjector.activate`, a
      // REAL `NSRunningApplication.activate()` — so this test yanked the
      // developer's foreground app, and failed spuriously whenever
      // `liveTargetApp()`'s unordered pick landed on a background-only process
      // whose activate() returns false (the injector then throws `.targetAppLost`
      // for reasons unrelated to separator logic). It needs a stable non-nil app
      // identity, not activation.
      activateTarget: { _ in true },
      secondsSinceUserInput: secondsSinceUserInput,
      clipboard: clip
    )
    return (injector, pasted)
  }

#endif
