import AppKit
import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. A menu picker lets
/// the user choose which lone modifier triggers dictation — or "Custom…", which
/// opens a press-to-capture sheet that binds a keyboard chord (⌃⌥D) or an extra
/// mouse button instead. Changes are persisted and pushed to the event tap
/// immediately.
struct HotkeyStepView: View {
  var coordinator: AppCoordinator

  // `0` is "no binding persisted", not a default binding: the unset default belongs
  // to `TriggerBinding.fromPersisted` (below), which maps any unknown code to right
  // ⌘. Restating `TriggerKey.rightCommand.rawValue` here would give the empty slot
  // two answers, and this one would win for an unset key — so a change to the
  // engine's default would leave this picker showing the old binding while the
  // ready screen and menu bar showed the new one. Matches `@BoundTriggerBinding`.
  @AppStorage(TriggerKeyStore.defaultsKey) private var triggerCode = 0

  @State private var isCapturing = false

  /// What the picker's menu rows are. A custom binding shows as its own row
  /// (`bound`, e.g. "⌃⌥D" or "Mouse 4") so the picker always names what's bound,
  /// while "Custom…" stays a separate, always-present row whose selection only
  /// opens the capture sheet — re-selecting an already-selected row fires
  /// nothing in a `Picker`, so folding the two into one row would make
  /// "rebind my custom trigger to a different one" unreachable.
  private enum Choice: Hashable {
    case modifier(TriggerKey)
    /// The currently bound custom (chord or mouse-button) binding — present only
    /// while one is bound.
    case bound
    /// The "Custom…" row: selecting it opens the capture sheet. Never reads as
    /// selected, because `selection`'s getter never returns it.
    case capture
  }

  private var binding: TriggerBinding { TriggerBinding.fromPersisted(triggerCode) }

  /// The label for the `bound` row, present only while a custom (non-modifier)
  /// binding is active — the modifiers already have rows of their own.
  private var boundCustomLabel: String? {
    if case .modifier = binding { return nil }
    return binding.label
  }

  private var selection: Binding<Choice> {
    Binding(
      get: {
        switch TriggerBinding.fromPersisted(triggerCode) {
        case .modifier(let key): return .modifier(key)
        case .chord, .mouseButton: return .bound
        }
      },
      set: { choice in
        switch choice {
        case .modifier(let key):
          // Write through the store, not the raw `@AppStorage` slot: the store owns
          // how a `TriggerBinding` is encoded, and `@AppStorage` is here to *observe*
          // the key so this view re-renders (it picks up the store's external write).
          // Assigning `triggerCode` directly left `TriggerKeyStore`'s setter with
          // no production caller, so a change to the encoding — versioning the key,
          // storing the case name, a migration — would keep `swift test` green while
          // the picker silently kept writing the old form.
          TriggerKeyStore().triggerBinding = .modifier(key)
          coordinator.dictationBindingChanged()
        case .capture:
          // Nothing is persisted yet — the sheet writes the binding on a
          // successful capture, and cancelling leaves the current one in place
          // (the getter re-derives the selection from the persisted slot, so
          // the picker snaps back on its own).
          isCapturing = true
        case .bound:
          break  // Re-selecting what's already bound changes nothing.
        }
      })
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Dictation key", systemImage: "keyboard",
        accessibilityID: UITestIdentifiers.hotkeyPicker, selection: selection
      ) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(Choice.modifier(key))
        }
        if let boundCustomLabel {
          Text(boundCustomLabel).tag(Choice.bound)
        }
        Text("Custom…").tag(Choice.capture)
      }
    } header: {
      Text("Shortcut")
    } footer: {
      // The pass-through caution belongs to the *binding*, so its wording lives
      // in the engine (`TriggerBinding.passThroughNote`) beside the tap's
      // listen-only contract rather than being restated per view — and it sits
      // in the footer, not the capture sheet, because it stays true for as long
      // as the binding is bound.
      VStack(alignment: .leading, spacing: 4) {
        Text("Tap to start and tap again to stop, or hold the key and release to dictate.")
        if let note = binding.passThroughNote {
          Text(note)
        }
      }
    }
    .sheet(isPresented: $isCapturing) {
      CustomTriggerCaptureView { captured in
        TriggerKeyStore().triggerBinding = captured
        coordinator.dictationBindingChanged()
      }
    }
  }
}

/// The press-to-capture sheet behind the picker's "Custom…" row: it records the
/// next **keyboard chord** (modifiers plus a key, e.g. ⌃⌥D) or **extra mouse
/// button** click and binds it as the dictation trigger. Esc closes without
/// changing the binding.
///
/// What it accepts is `TriggerBinding`'s policy, not this view's
/// (`chordBinding(forKeyCode:modifiers:)` / `mouseButtonBinding(forButton:)`),
/// and each refusal maps to one sentence here. A **bare** key is refused because
/// the dictation tap is listen-only and swallows nothing, so a bound letter
/// would type into the focused app on every dictation; a handful of
/// system-reserved chords (⌘Q, ⌘⇥, ⌘Space…) are refused because they'd fire
/// their system action underneath the dictation. Left/right clicks structurally
/// never arrive (they aren't `.otherMouseDown`, and they're how the user clicks
/// at all).
///
/// Capture uses `NSEvent` monitors, not the dictation `CGEventTap`: local
/// monitors for `keyDown` and `flagsChanged` (returning nil so a captured or
/// refused press doesn't also type, beep, or fire its own shortcut in this
/// window) plus local and global `otherMouseDown` monitors, since mouse buttons
/// don't focus-follow. The global monitor needs the Accessibility grant, which
/// the app required before Settings was reachable.
///
/// Note what a local monitor cannot do: while this sheet is key, a chord that
/// macOS itself owns (⌘⇥, ⌘Space) is consumed by the system before any app
/// monitor sees it — which is the same reason those chords are refused rather
/// than merely discouraged.
private struct CustomTriggerCaptureView: View {
  /// Called with the captured binding after the sheet dismisses itself.
  var onCapture: (TriggerBinding) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var refusal: String?
  /// The modifiers held right now, so the sheet shows the chord forming (⌃⌥…)
  /// before the key lands — the live feedback that makes a chord recorder
  /// legible rather than a blind prompt.
  @State private var heldModifiers: TriggerBinding.ChordModifiers = []
  @State private var monitors: [Any] = []

  var body: some View {
    VStack(spacing: 12) {
      Text("Set a custom dictation trigger")
        .font(.headline)
      Text("Hold modifiers and press a key (⌃⌥D), or press an extra mouse button…")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      // The forming chord, or a placeholder of the same height so the sheet
      // doesn't jump when the first modifier goes down.
      Text(heldModifiers.isEmpty ? " " : heldModifiers.glyphs)
        .font(.system(size: 28, weight: .regular))
        .monospaced()
      if let refusal {
        Text(refusal)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      Text("Blurt never intercepts the trigger, so an app that already uses it still gets it.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
      Button("Cancel") { dismiss() }
    }
    .padding(24)
    .frame(width: 360)
    .onAppear(perform: startListening)
    .onDisappear(perform: stopListening)
  }

  private func startListening() {
    let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleKeyDown(event)
      return nil  // consume: a captured/refused press must not also type or beep
    }
    let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      heldModifiers = Self.modifiers(from: event.modifierFlags)
      return nil
    }
    let localClick = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
      handleClick(event)
      return nil
    }
    let globalClick = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { event in
      handleClick(event)
    }
    monitors = [localKey, localFlags, localClick, globalClick].compactMap { $0 }
  }

  private func stopListening() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
  }

  private func handleKeyDown(_ event: NSEvent) {
    let escapeKeyCode = 53
    let keyCode = Int(event.keyCode)
    let modifiers = Self.modifiers(from: event.modifierFlags)
    // Esc always cancels, with or without modifiers: it is the sheet's dismiss
    // gesture, and ⌘⌥Esc is Force Quit — neither is a trigger worth binding.
    if keyCode == escapeKeyCode {
      log(event, kind: "keyDown", outcome: "cancelled")
      dismiss()
      return
    }
    switch TriggerBinding.chordBinding(forKeyCode: keyCode, modifiers: modifiers) {
    case .success(let captured):
      log(event, kind: "keyDown", outcome: "captured", binding: captured.label)
      dismiss()
      onCapture(captured)
    case .failure(let reason):
      log(event, kind: "keyDown", outcome: Self.outcome(for: reason))
      refusal = Self.message(for: reason)
    }
  }

  private func handleClick(_ event: NSEvent) {
    // Left/right clicks never arrive (they're not `.otherMouseDown`), so this
    // refusal covers only button numbers past what a binding can express.
    guard let captured = TriggerBinding.mouseButtonBinding(forButton: event.buttonNumber) else {
      log(event, kind: "otherMouseDown", outcome: "refused-button")
      refusal = "That button can't be the trigger. Press a mouse button other than left or right click."
      return
    }
    log(event, kind: "otherMouseDown", outcome: "captured", binding: captured.label)
    dismiss()
    onCapture(captured)
  }

  /// The engine's refusal reasons as the sentences this sheet shows. Kept beside
  /// the outcome tokens below so the copy and the diagnostics token for a reason
  /// are chosen in one place.
  private static func message(for reason: TriggerBinding.ChordRefusal) -> String {
    switch reason {
    case .bareKey:
      return
        "Hold at least one modifier (⌃, ⌥, ⇧ or ⌘). A key on its own would type into whatever "
        + "app is focused every time you dictate."
    case .modifierOnly:
      return "Add a regular key to the modifiers — or pick right ⌘ / right ⌥ from the menu instead."
    case .reserved:
      return "That shortcut belongs to macOS, so it would act while you dictate. Try another."
    }
  }

  /// The stable diagnostics token for a refusal (see `DictationLog.CapturedInput`).
  private static func outcome(for reason: TriggerBinding.ChordRefusal) -> String {
    switch reason {
    case .bareKey: return "refused-bare-key"
    case .modifierOnly: return "refused-modifier-only"
    case .reserved: return "refused-reserved-chord"
    }
  }

  /// `NSEvent.ModifierFlags` → the engine's side-agnostic chord set, mirroring
  /// `DictationEventDecoder.modifiers(from:)` for the `CGEvent` side. Caps Lock
  /// and `fn` are deliberately not chord modifiers.
  private static func modifiers(
    from flags: NSEvent.ModifierFlags
  ) -> TriggerBinding.ChordModifiers {
    var modifiers: TriggerBinding.ChordModifiers = []
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    return modifiers
  }

  /// Developer-mode diagnostics: every event the recorder sees — accepted or
  /// refused — lands in `capture-events.jsonl` with its raw facts (button
  /// number, keycode, flags, autorepeat), so a misbehaving multi-button mouse or
  /// a chord the system ate can be diagnosed from what actually arrived. Gated
  /// inside `appendCaptureEvent` on the same developer-mode switch as the other
  /// logs; with the switch off this writes nothing.
  private func log(_ event: NSEvent, kind: String, outcome: String, binding: String? = nil) {
    let isKeyEvent = kind == "keyDown"
    let input = DictationLog.CapturedInput(
      kind: kind,
      button: isKeyEvent ? nil : event.buttonNumber,
      keyCode: isKeyEvent ? Int(event.keyCode) : nil,
      flags: UInt64(event.modifierFlags.rawValue),
      // `isARepeat` raises on non-key events, so it's only read for key ones.
      isRepeat: isKeyEvent && event.isARepeat)
    DictationLog.appendCaptureEvent(input, outcome: outcome, binding: binding)
  }
}
