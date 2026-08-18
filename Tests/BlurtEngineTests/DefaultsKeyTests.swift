import Testing

@testable import BlurtEngine

/// A `DefaultsKey`'s composed `key` is the on-disk contract with every installed
/// copy of the host app: change either half — the case's raw value or the
/// identity's prefix — and it doesn't fail, it silently abandons the user's
/// setting and reads back the unset default. These pin the properties that keep
/// the set legible; which store owns which case is pinned in
/// `PersistedSettingsTests`.
@Suite("DefaultsKey")
struct DefaultsKeyTests {
  @Test("raw values are unique")
  func rawValuesAreUnique() {
    // Two cases sharing a raw value would make two settings fight over one slot,
    // and `PersistedSettings.allDefaultsKeys` would carry the duplicate. Checked
    // on the raw values rather than the composed keys because the prefix is
    // common to all of them: it can't separate two cases that collide.
    let raws = DefaultsKey.allCases.map(\.rawValue)
    #expect(Set(raws).count == raws.count)
  }

  @Test("every user setting is written under the host prefix")
  func keysAreNamespaced() {
    // The app shares its defaults domain with anything else writing there, so user
    // settings carry the prefix — and under Blurt's identity that reproduces the
    // exact keys already on disk (`BlurtSoundPack`, …). It also separates them
    // from the non-setting keys deliberately kept out of the reset sweep — see the
    // assertion below.
    for key in DefaultsKey.allCases {
      #expect(key.key(in: .blurt) == "Blurt" + key.rawValue, "\(key) should be Blurt-prefixed")
    }
    // The TCC migration marker records what already happened rather than something
    // the user chose, so it is neither a case here nor swept by `resetAll` —
    // clearing it would make the next launch re-run the `tccutil` reset. Its
    // unprefixed name is the visible half of that distinction.
    #expect(!SigningIdentityMigration.lastSigningIdentityDefaultsKey.hasPrefix("Blurt"))
  }

  @Test("a host's prefix replaces Blurt's rather than being appended to it")
  func keysFollowTheConfiguredIdentity() {
    // The point of the prefix being host-supplied: a second app embedding the
    // engine writes `AcmeVoiceSoundPack`, not into Blurt's slot. The raw value is
    // the unprefixed half, so nothing here says "Blurt".
    let acme = HostIdentity(
      productName: "Acme Voice", subsystem: "com.acme.voice", keychainService: "acme-voice",
      defaultsPrefix: "AcmeVoice", logDirectoryName: "Acme Voice",
      releaseURL: HostIdentity.blurt.releaseURL)
    #expect(DefaultsKey.soundPack.key(in: acme) == "AcmeVoiceSoundPack")
    #expect(DefaultsKey.soundPack.key(in: .blurt) == "BlurtSoundPack")
  }
}
