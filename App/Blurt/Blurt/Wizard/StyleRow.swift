import BlurtEngine
import SwiftUI

/// The style switcher, as a row of the ready screen's grouped form: "Style"
/// leading and a pop-up trailing. **Default** is the base styling (no profile
/// instructions appended) and the rest of the menu is the user's profiles; a
/// divider then separates the one item that isn't a style at all, **Edit
/// Styles…**, which opens Settings deep-linked to the Styles pane where
/// profiles are created and edited (see `SettingsWindowRoot`). This row owns
/// only which style is in effect; `StylesInertNotice` below flags when no
/// style can apply.
///
/// A pop-up rather than a segmented control, because style names are
/// user-authored: a segmented `Picker` reports its full-label width as its
/// *minimum* and, at five segments of 24-character names, pushed past the
/// window's edge. A pop-up shows one item at a time, and inside the form row
/// it hugs its title and truncates rather than growing the row (see
/// `PickerSettingRow`, whose pop-ups work the same way).
///
/// The choice is **sticky**: a selection holds until the user makes another,
/// so a switch is not something to redo before every dictation.
struct StyleRow: View {
  /// Already decoded and resolved by `ReadyView`, which observes the slots —
  /// this view is pure render-and-write.
  let profiles: [StyleProfile]
  /// The active profile's id, or `nil` for Default — with no profiles defined
  /// the store resolves to the same base styling, so `nil` always shows
  /// Default as the selection.
  let activeID: StyleProfile.ID?
  /// The "Edit Styles…" item's action — opens Settings deep-linked to the
  /// Styles pane, where styles are edited. Handed down from
  /// `MainWindowRoot`, which sets `AppDelegate.settingsOpensOnStyles` before
  /// calling the `openSettings` environment action.
  var editStyles: () -> Void

  /// What a menu item resolves to. `edit` is a *command* parked in the same
  /// menu rather than a style, which is why the selection is a computed
  /// `Binding` (below) instead of stored state: choosing it runs an action and
  /// writes nothing, so the pop-up snaps straight back to the active style.
  private enum Choice: Hashable {
    case defaultStyle
    case profile(StyleProfile.ID)
    case edit
  }

  var body: some View {
    SettingRow(title: "Style", systemImage: "textformat") {
      // The picker keeps its own (hidden) title so VoiceOver reads a
      // meaningful name for the pop-up rather than an empty string.
      Picker("Style", selection: choice) {
        // Writes go through the store — never the raw slot — so the store
        // keeps owning how a choice is encoded (a profile's id, or the
        // store's "default" sentinel; see `HotkeyStepView.selection` for the
        // precedent).
        Text(StyleProfileStore.defaultStyleName).tag(Choice.defaultStyle)
        ForEach(profiles) { profile in
          Text(profile.name).tag(Choice.profile(profile.id))
        }
        // Below the line is the door to where styles are *made*, not another
        // thing to be in effect — the divider is what says so, and it is why
        // this item can share a menu with the selection without reading as
        // one of them. Always offered, including at `profileLimit`: editing
        // and deleting stay useful once adding stops, and Settings enforces
        // the cap on its own Add button.
        Divider()
        Text("Edit Styles…").tag(Choice.edit)
      }
      // Explicit, not inherited: the pop-up is the whole point (see the type's
      // note on why segmented can't work here).
      .pickerStyle(.menu)
      .labelsHidden()
      .accessibilityIdentifier(UITestIdentifiers.styleProfilePickerFromMain)
    }
    .background(shortcuts)
  }

  /// The pop-up's selection: derived from `activeID` on the way out and
  /// dispatched to the store on the way in, so the store stays the single
  /// owner of what's in effect and this view holds no state that could drift
  /// from it. `.edit` is the exception that makes a computed binding the right
  /// shape — it runs its action and writes nothing, so the next `get` returns
  /// the style that was already selected.
  private var choice: Binding<Choice> {
    Binding(
      get: { activeID.map(Choice.profile) ?? .defaultStyle },
      set: { chosen in
        switch chosen {
        case .defaultStyle:
          StyleProfileStore().activateDefault()
        case .profile(let id):
          // Resolved against the list this view was handed rather than
          // re-read from the store: the tag came from that same list, so a
          // profile deleted underneath us simply finds nothing and no-ops.
          if let profile = profiles.first(where: { $0.id == id }) {
            StyleProfileStore().activate(profile)
          }
        case .edit:
          editStyles()
        }
      })
  }

  /// Keyboard shortcuts for the styles: ⌘1 selects Default, ⌘2…⌘5 the profiles
  /// in menu order. Hidden buttons rather than a `Commands` menu block, because
  /// the scoping is the point: a menu command fires while *any* of the app's
  /// windows is key (Settings included), whereas a button's shortcut is
  /// resolved through the window that hosts it — so these fire exactly while
  /// the main window is key, and not at all while it shows the wizard (this
  /// view doesn't exist then). `.hidden()` keeps the buttons out of sight,
  /// layout (they're parked in `background`) and accessibility while leaving
  /// their shortcuts registered; the writes go through the same store calls as
  /// the pop-up. Every style they reach is also in the pop-up, so nothing here
  /// is *only* reachable by shortcut — but the pop-up now takes a click to
  /// open, which is what makes them worth keeping.
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

/// The Style row's section footer, shown only while enhanced transcripts are
/// off: then every choice gives the same raw transcript, and a pop-up that
/// changes nothing needs saying so. Otherwise the footer is empty — the
/// selected style's name is the row's whole readout, its instructions live in
/// Settings.
struct StylesInertNotice: View {
  /// Observed so the notice follows the toggle in the Settings window live.
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  var body: some View {
    if !enhancedTranscripts {
      Text("Enhanced transcripts are off in Settings, so styles don't apply.")
    }
  }
}
