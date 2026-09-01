import BlurtEngine
import SwiftUI

/// The style switcher: a System Settings–style labeled row — leading
/// "Output Style" label, trailing row of buttons — in the same rounded
/// `.quinary` card as the Recent list below it, so the window's two in-content
/// surfaces match. The first button, **Default**, is the base styling (no
/// profile instructions appended) and the rest are the user's profiles; the
/// active one is drawn prominent (accent fill), the others bordered, so each
/// style is a distinct button rather than a segment. A trailing "+" opens
/// Settings deep-linked to the Advanced pane, where profiles are created and
/// edited (see `SettingsWindowRoot`'s Styles section) — this row owns only
/// which one is in effect. It sits
/// between the shortcut readout and the Recent list because which style is in
/// effect is the one dictation setting worth changing mid-flow. The choice is
/// **sticky**: a selection holds until the user makes another, so a switch is
/// not something to redo before every dictation.
struct StyleRow: View {
  /// Already decoded and resolved by `ReadyView`, which observes the slots —
  /// this view is pure render-and-write.
  let profiles: [StyleProfile]
  /// The active profile's id, or `nil` for Default — with no profiles defined
  /// the store resolves to the same base styling, so `nil` always draws the
  /// Default button selected.
  let activeID: StyleProfile.ID?
  /// The "+" button's action — opens Settings deep-linked to the Advanced
  /// pane, where styles are edited. Handed down from `MainWindowRoot`, which
  /// sets `AppDelegate.settingsOpensOnAdvanced` before calling the
  /// `openSettings` environment action.
  var addStyle: () -> Void

  var body: some View {
    // The row shape is `SettingRow`'s (leading label, trailing control, center
    // alignment) but built inline — `SettingRow` would wrap the title in an
    // icon-bearing `Label`. Each style button carries its own name, so the
    // row label is ordinary static text (no picker to lend it to).
    HStack {
      Text("Output Style")
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        // A segmented control, not a row of buttons. This is the macOS control
        // for picking one of a few mutually-exclusive options, and it's what
        // the design draws: the selected segment is a white raised chip on a
        // grey track, which a row of buttons could only fake by hand-filling
        // the active one. It's also tighter — segments share one track instead
        // of each carrying a bordered button's own padding.
        //
        // Writes go through the store — never the raw slot — so the store keeps
        // owning how a choice is encoded (a profile's id, or the store's
        // "default" sentinel; see `HotkeyStepView.selection` for the precedent).
        Picker("Output Style", selection: styleSelection) {
          Text(StyleProfileStore.defaultStyleName).tag(StyleProfile.ID?.none)
          ForEach(profiles) { profile in
            Text(profile.name).tag(StyleProfile.ID?.some(profile.id))
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        // Room for another profile? Offer the door to where they're made.
        // Hidden at the cap rather than disabled: a permanently-grey control
        // reads as broken, and the style buttons already fill the row then.
        if profiles.count < StyleProfileStore.profileLimit {
          Button(action: addStyle) {
            Image(systemName: "plus")
          }
          // Filled green, as the design draws it — the row's one *action*,
          // distinct from the style buttons beside it, which are a selection.
          .glassButtonStyleCompat(prominent: true)
          .accessibilityLabel("Add Style")
          .accessibilityIdentifier(UITestIdentifiers.styleProfileAddFromMain)
        }
      }
      .background(shortcuts)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // Full width, like the Recent card below: both stretch to the one content
    // width `ReadyView`'s horizontal padding leaves, so the two cards' edges
    // align by construction rather than by matching numbers.
    .frame(maxWidth: .infinity)
    // The Recent card's container, so the two surfaces read as one family.
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(.quinary)
    )
  }

  /// The segmented control's selection, bridging `nil`-means-Default to the
  /// store. Read-only from `activeID` (already resolved by `ReadyView`); every
  /// write goes through `StyleProfileStore`, which owns whether a choice is
  /// encoded as a profile id or the "default" sentinel — the view never touches
  /// the raw defaults slot.
  private var styleSelection: Binding<StyleProfile.ID?> {
    Binding(
      get: { activeID },
      set: { id in
        let store = StyleProfileStore()
        guard let id, let profile = profiles.first(where: { $0.id == id }) else {
          store.activateDefault()
          return
        }
        store.activate(profile)
      })
  }

  /// Keyboard shortcuts for the style buttons: ⌘1 selects Default, ⌘2…⌘5 the
  /// profiles in row order. Hidden buttons rather than a `Commands` menu block,
  /// because the scoping is the point: a menu command fires while *any* of the
  /// app's windows is key (Settings included), whereas a button's shortcut is
  /// resolved through the window that hosts it — so these fire exactly while
  /// the main window is key, and not at all while it shows the wizard (this
  /// view doesn't exist then). `.hidden()` keeps the buttons out
  /// of sight, layout (they're parked in `background`) and accessibility while
  /// leaving their shortcuts registered; the writes go through the same store
  /// calls as the visible buttons. A "Style" submenu naming the shortcuts —
  /// menu-bar discoverability — is a possible follow-up; the buttons
  /// themselves are always visible, so nothing here is *only* reachable by
  /// shortcut.
  private var shortcuts: some View {
    Group {
      Button(StyleProfileStore.defaultStyleName) { StyleProfileStore().activateDefault() }
        .keyboardShortcut("1", modifiers: .command)
      // The store caps the list at `profileLimit` (4), so the digits end at ⌘5.
      ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
        Button(profile.name) { StyleProfileStore().activate(profile) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: .command)
      }
    }
    .hidden()
  }
}
