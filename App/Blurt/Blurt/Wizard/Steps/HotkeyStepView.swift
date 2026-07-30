import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. Two menu pickers let
/// the user choose which lone modifier triggers each dictation mode — one for
/// the cleaned-up (LLM rewrite) transcript, one for the raw verbatim transcript.
/// Changes are persisted and pushed to the event tap immediately, and the two
/// keys are kept distinct: picking one key for a mode that the other already
/// holds swaps them (`DictationTriggerPair.assigning`).
struct HotkeyStepView: View {
  var coordinator: AppCoordinator

  // `0` is "no keycode persisted", not a default binding: the unset default
  // belongs to each store's decode-with-fallback (cleaned → right ⌘ via
  // `TriggerKey.fromPersisted`, raw → right ⌥ via `RawTriggerKeyStore`).
  // Restating those defaults here would give the empty slot two answers. The
  // `@AppStorage` slots are here to *observe* the keys so this view re-renders
  // when the store writes; the pickers write through the stores.
  @AppStorage(TriggerKeyStore.defaultsKey) private var cleanedKeyCode = 0
  @AppStorage(RawTriggerKeyStore.defaultsKey) private var rawKeyCode = 0

  /// The current pair, decoded from both slots through each store's own
  /// fallback so an unset key resolves to that store's default.
  private var pair: DictationTriggerPair {
    DictationTriggerPair(
      raw: TriggerKey(rawValue: rawKeyCode) ?? .rightOption,
      cleaned: TriggerKey.fromPersisted(cleanedKeyCode))
  }

  /// A binding for `mode`'s key that, on write, resolves the pair through
  /// `assigning` (swapping on a collision so the two stay distinct), persists
  /// **both** keys through their stores, then re-reads them into the tap.
  private func selection(for mode: DictationMode) -> Binding<TriggerKey> {
    Binding(
      get: { mode == .cleaned ? pair.cleaned : pair.raw },
      set: { newValue in
        let updated = pair.assigning(mode, to: newValue)
        // Write through the stores, not the raw `@AppStorage` slots: the stores
        // own how a `TriggerKey` is encoded (and are the setters' only
        // production callers). `@AppStorage` here just observes the external
        // write so this view re-renders. Write both, since `assigning` may have
        // swapped the other mode's key too.
        TriggerKeyStore().triggerKey = updated.cleaned
        RawTriggerKeyStore().triggerKey = updated.raw
        coordinator.dictationBindingChanged()
      })
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Cleaned-up dictation key", systemImage: "wand.and.stars",
        accessibilityID: UITestIdentifiers.hotkeyPicker, selection: selection(for: .cleaned)
      ) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(key)
        }
      }
      PickerSettingRow(
        title: "Raw dictation key", systemImage: "text.quote",
        accessibilityID: UITestIdentifiers.rawHotkeyPicker, selection: selection(for: .raw)
      ) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(key)
        }
      }
    } header: {
      Text("Shortcuts")
    } footer: {
      Text(
        "Two keys, each tap-to-toggle or hold-to-talk. The cleaned-up key pastes a polished "
          + "transcript (filler words removed, punctuation fixed); the raw key pastes your words "
          + "exactly as spoken. Choosing a key already used by the other mode swaps them.")
    }
  }
}
