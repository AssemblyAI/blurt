import AppKit
import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. A menu picker lets
/// the user choose which lone modifier triggers dictation — or "Custom…", which
/// opens a press-to-capture sheet that binds an extra mouse button instead.
/// Changes are persisted and pushed to the event tap immediately.
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
  /// (`bound`, e.g. "Mouse 4") so the picker always names what's bound,
  /// while "Custom…" stays a separate, always-present row whose selection only
  /// opens the capture sheet — re-selecting an already-selected row fires
  /// nothing in a `Picker`, so folding the two into one row would make
  /// "rebind my custom button to a different one" unreachable.
  private enum Choice: Hashable {
    case modifier(TriggerKey)
    /// The currently bound custom (mouse-button) binding — present only while
    /// one is bound.
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
        case .mouseButton: return .bound
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
      Text("Tap to start and tap again to stop, or hold the key and release to dictate.")
    }
    .sheet(isPresented: $isCapturing) {
      CustomTriggerCaptureView { captured in
        TriggerKeyStore().triggerBinding = captured
        coordinator.dictationBindingChanged()
      }
    }
  }
}

/// The press-to-capture sheet behind the picker's "Custom…" row: it listens for
/// the next extra-mouse-button click and binds it as the dictation trigger.
/// Esc (or Cancel) closes without changing the binding.
///
/// What it accepts is `TriggerBinding`'s policy, not this view's: mouse buttons
/// past left/right (`mouseButtonBinding(forButton:)`). Left/right clicks
/// structurally never arrive (they aren't `.otherMouseDown`, and they're how
/// the user clicks at all), and keyboard keys are refused with an explanation
/// rather than silently ignored — the dictation tap is listen-only and swallows
/// nothing, so a bound keyboard key would type into the focused app on every
/// dictation. Modifiers, Caps Lock, and media keys never even reach the
/// refusal: they are `flagsChanged`/`systemDefined` events, not the `keyDown`
/// the Esc/refusal monitor watches.
///
/// Capture uses `NSEvent` monitors, not the dictation `CGEventTap`: a local
/// monitor for clicks inside the Settings window plus a global one so a click
/// landing outside the window still binds — mouse buttons don't focus-follow.
/// The global monitor needs the Accessibility grant, which the app required
/// before Settings was reachable. A local `keyDown` monitor handles Esc and
/// the keyboard refusal (returning nil so the press doesn't also beep or
/// trigger a shortcut).
private struct CustomTriggerCaptureView: View {
  /// Called with the captured binding after the sheet dismisses itself.
  var onCapture: (TriggerBinding) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var refusal: String?
  @State private var monitors: [Any] = []

  var body: some View {
    VStack(spacing: 12) {
      Text("Set a custom dictation button")
        .font(.headline)
      Text("Press a mouse button (Mouse 3 or higher)…")
        .foregroundStyle(.secondary)
      if let refusal {
        Text(refusal)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      Button("Cancel") { dismiss() }
    }
    .padding(24)
    .frame(width: 340)
    .onAppear(perform: startListening)
    .onDisappear(perform: stopListening)
  }

  private func startListening() {
    let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleKeyDown(event)
      return nil  // consume: a refused press must not also type or beep
    }
    let localClick = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
      handleClick(event)
      return nil
    }
    let globalClick = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { event in
      handleClick(event)
    }
    monitors = [localKey, localClick, globalClick].compactMap { $0 }
  }

  private func stopListening() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
  }

  private func handleKeyDown(_ event: NSEvent) {
    let escapeKeyCode = 53
    if Int(event.keyCode) == escapeKeyCode {
      log(event, kind: "keyDown", outcome: "cancelled")
      dismiss()
      return
    }
    // Keyboard keys aren't bindable: the dictation tap is listen-only, so a
    // bound key would type into the focused app on every dictation.
    log(event, kind: "keyDown", outcome: "refused-keyboard-key")
    refusal = "Keyboard keys can't be the custom trigger. Press an extra mouse button, or Esc to cancel."
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

  /// Developer-mode diagnostics: every event the recorder sees — accepted or
  /// refused — lands in `capture-events.jsonl` with its raw facts (button
  /// number, keycode, flags, autorepeat), so a misbehaving multi-button mouse
  /// can be diagnosed from what it actually sent. Gated inside
  /// `appendCaptureEvent` on the same developer-mode switch as the other logs;
  /// with the switch off this writes nothing.
  private func log(_ event: NSEvent, kind: String, outcome: String, binding: String? = nil) {
    let isKeyEvent = kind == "keyDown"
    DictationLog.appendCaptureEvent(
      kind: kind, outcome: outcome,
      button: isKeyEvent ? nil : event.buttonNumber,
      keyCode: isKeyEvent ? Int(event.keyCode) : nil,
      flags: UInt64(event.modifierFlags.rawValue),
      // `isARepeat` raises on non-key events, so it's only read for key ones.
      isRepeat: isKeyEvent && event.isARepeat,
      binding: binding)
  }
}
