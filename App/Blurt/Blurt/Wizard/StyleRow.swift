import AppKit
import BlurtEngine
import SwiftUI

/// The style switcher: a centered row of buttons in the same warm card as the
/// Recent list below it, so the window's two in-content surfaces match. It
/// carries no label of its own — the caption `ReadyView` draws above the card
/// names it, so a leading "Output Style" inside the card only said it twice.
/// The first button, **Default**, is the base styling (no profile instructions
/// appended) and the rest are the user's profiles; the active one is drawn
/// prominent (green accent fill), the others plain bordered (grey), so each
/// style is a distinct button rather than a segment.
///
/// Buttons rather than a segmented `Picker` for a load-bearing reason, not a
/// stylistic one: style names are user-authored, and a segmented control
/// reports its full-label width as its *minimum*, so it cannot be truncated or
/// compressed. At the reachable worst case — five segments at the 24-character
/// `nameLimit` — it drives itself straight through the caption above it and
/// both card edges, and out of the 480 pt window. Separate buttons can each
/// tail-truncate instead, so the chips give and the layout holds.
///
/// A trailing "+" opens
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
    // Centered chips with no leading label of its own: the caption `ReadyView`
    // draws above this card ("How Blurt cleans up your raw transcript") already
    // names the row, so an "Output Style" label inside it said the same thing
    // twice and spent ~85 pt of the card doing it — width the chips now use to
    // truncate later. The two `Spacer`s are `minLength: 0` so they collapse
    // before the chips give: extra room centers the group, and once there is
    // none the names start truncating instead.
    HStack {
      Spacer(minLength: 0)
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
          // Filled green, as the design draws it. Note that green now marks
          // the selected style too, so the fill alone no longer tells this
          // apart from the chips — what does is that it is the row's only
          // glyph rather than a name, and it sits past the last of them.
          .glassButtonStyleCompat(prominent: true)
          .accessibilityLabel("Add Style")
          .accessibilityIdentifier(UITestIdentifiers.styleProfileAddFromMain)
        }
      }
      .background(shortcuts)
      Spacer(minLength: 0)
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

  /// One style's button. The active one is the prominent (accent-filled)
  /// system button and the rest are the plain bordered one — Liquid Glass
  /// variants on macOS 26+ (see `glassButtonStyleCompat`) — so **green marks
  /// the selection and grey the alternatives**, and selection chrome, sizing
  /// and accessibility all come from the system styles rather than a
  /// hand-drawn fill.
  ///
  /// Neither the fill nor the label color is named here. A prominent button
  /// takes the app's asset-catalog accent (`BlurtBrand.accent`'s note explains
  /// why that reaches further than `.tint(_:)`) and draws its label white to
  /// sit on it; a bordered button draws grey chrome with a label-colored
  /// title. That's the whole scheme, so there is no pair of hand-picked
  /// colors here to get the wrong way round — which is what happened when
  /// every button was prominent and only the tint varied.
  ///
  /// `.isSelected` carries the state for VoiceOver, so nothing depends on
  /// seeing the difference.
  private func styleButton(
    _ name: String, isActive: Bool, activate: @escaping () -> Void
  ) -> some View {
    Button(action: activate) {
      // One line, tail-truncated. Style names are user-authored (up to
      // `nameLimit`, 24) and the row is the fixed width of the card: without
      // this a long name pushed the "+" off the edge and kept going past the
      // window (a name like "sdfsdfsdfsdfsdf" blew the whole row out).
      // Truncating makes the chips the thing that gives, which is recoverable
      // — the full name is on hover and in Settings — where a broken layout
      // isn't. It is also why this row is buttons and not a segmented
      // `Picker`: a segmented control reports its full-label width as its
      // *minimum*, so it can't be truncated or compressed at all, and at five
      // segments of long names it shoves the caption above the card and the
      // card's own edges out of the window.
      Text(name)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .help(name)
    .glassButtonStyleCompat(prominent: isActive)
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
