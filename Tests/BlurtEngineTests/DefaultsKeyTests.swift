import Testing

@testable import BlurtEngine

/// `DefaultsKey`'s raw values are the on-disk contract with every installed copy of
/// Blurt: a renamed raw value doesn't fail, it silently abandons the user's setting
/// and reads back the unset default. These pin the properties that keep the set
/// legible; which store owns which case is pinned in `PersistedSettingsTests`.
@Suite("DefaultsKey")
struct DefaultsKeyTests {
  @Test("raw values are unique")
  func rawValuesAreUnique() {
    // Two cases sharing a raw value would make two settings fight over one slot,
    // and `PersistedSettings.allDefaultsKeys` would carry the duplicate.
    let raws = DefaultsKey.allCases.map(\.rawValue)
    #expect(Set(raws).count == raws.count)
  }

  @Test("every user setting is Blurt-prefixed")
  func rawValuesAreNamespaced() {
    // The app shares its defaults domain with anything else writing there, so user
    // settings carry the prefix. It also separates them from the non-setting keys
    // deliberately kept out of the reset sweep — see the assertion below.
    for key in DefaultsKey.allCases {
      #expect(key.rawValue.hasPrefix("Blurt"), "\(key) should be Blurt-prefixed")
    }
    // The TCC migration marker records what already happened rather than something
    // the user chose, so it is neither a case here nor swept by `resetAll` —
    // clearing it would make the next launch re-run the `tccutil` reset. Its
    // unprefixed name is the visible half of that distinction.
    #expect(!SigningIdentityMigration.lastSigningTeamDefaultsKey.hasPrefix("Blurt"))
  }
}
