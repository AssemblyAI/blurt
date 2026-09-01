import AppKit
import BlurtEngine
import SwiftUI

/// The style switcher: a System Settings–style labeled row — leading
/// "Output Style" label, trailing row of buttons — in the same warm card as
/// the Recent list below it, so the window's two in-content surfaces match.
/// The first button, **Default**, is the base styling (no profile instructions
/// appended) and the rest are the user's profiles; the active one is drawn
/// prominent (accent fill), the others bordered, so each style is a distinct
/// button rather than a segment. A trailing "+" opens
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
      // Fixed so the chips, not the row's own label, absorb any shortfall: a
      // truncated "Output Sty…" would be a worse loss than a shortened style
      // name, which the tooltip and Settings both still spell out.
      Text("Output Style")
        .fixedSize()
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        // Writes go through the store — never the raw slot — so the store
        // keeps owning how a choice is encoded (a profile's id, or the
        // store's "default" sentinel; see `HotkeyStepView.selection` for the
        // precedent).
        styleButton(StyleProfileStore.defaultStyleName, isActive: activeID == nil) {
          StyleProfileStore().activateDefault()
        }
        ForEach(profiles) { profile in
          styleButton(profile.name, isActive: activeID == profile.id) {
            StyleProfileStore().activate(profile)
          }
        }
        // Room for another profile? Offer the door to where they're made.
        // Hidden at the cap rather than disabled: a permanently-grey control
        // reads as broken, and the style buttons already fill the row then.
        if profiles.count < StyleProfileStore.profileLimit {
          Button(action: addStyle) {
            // Sized to a text label's height so this matches the style buttons
            // beside it. A bordered button sizes its chrome to its *content*
            // and ignores an outer `.frame(height:)`, and an SF Symbol is
            // shorter than a line of text — which rendered the "+" 3.5 pt
            // shorter than "Default". The design has them at one height.
            Image(systemName: "plus")
              .frame(height: Self.labelHeight)
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
    // 9, so the card lands on the design's 42 pt around a 24 pt control row.
    .padding(.vertical, 9)
    // Full width, like the Recent card below: both stretch to the one content
    // width `ReadyView`'s horizontal padding leaves, so the two cards' edges
    // align by construction rather than by matching numbers.
    .frame(maxWidth: .infinity)
    // The Recent card's container, so the two surfaces read as one family:
    // the design's warm card fill with its hairline, rather than the system
    // `.quinary` material this used to take.
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(BlurtBrand.cardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .strokeBorder(BlurtBrand.cardBorder, lineWidth: 1)
    )
  }

  /// The height of a text button's label, read from the font rather than
  /// written as a literal, so the icon button can match the text buttons.
  private static let labelHeight =
    NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height

  /// One style's button. Every one is the same prominent system button; only
  /// the tint differs, so sizing, hover/press chrome and the accessibility
  /// fallbacks all still come from the system style rather than a hand-drawn
  /// fill.
  ///
  /// The active style is **white** and the rest are **green**, which is the
  /// design's scheme and reads as state-vs-action rather than as inverted
  /// prominence: green is what the row uses for things you can click *to do
  /// something* — switch to that style, or "+" to add one — while the style
  /// already in effect isn't an action, so it sits out in white.
  ///
  /// A prominent button draws its label white to sit on the accent, which is
  /// invisible once the fill is white, so the active one names the ink
  /// explicitly. `.isSelected` carries the state for VoiceOver, so nothing
  /// depends on seeing the difference.
  private func styleButton(
    _ name: String, isActive: Bool, activate: @escaping () -> Void
  ) -> some View {
    Button(action: activate) {
      // One line, tail-truncated. Style names are user-authored and unbounded,
      // and the row is the fixed width of the card: without this a long name
      // pushed the "+" off the edge and kept going past the window (a name like
      // "sdfsdfsdfsdfsdf" blew the whole row out). Truncating makes the chips
      // the thing that gives, which is recoverable — the full name is on hover
      // and in Settings — where a broken layout isn't.
      Text(name)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(isActive ? AnyShapeStyle(BlurtBrand.ink) : AnyShapeStyle(.white))
    }
    .help(name)
    .glassButtonStyleCompat(prominent: true)
    .tint(isActive ? Color.white : BlurtBrand.accent)
    .accessibilityAddTraits(isActive ? .isSelected : [])
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
