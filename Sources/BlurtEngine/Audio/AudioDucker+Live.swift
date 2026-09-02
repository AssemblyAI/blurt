import CoreAudio

// The real HAL boundary behind `AudioDucker` — read and set the default output
// device's virtual main volume. Seams-style (`DictationSession.Seams`): `var`
// properties carrying the production defaults, so tests substitute both
// (`AudioDuckerTests` substitutes everything — nothing under `swift test` may
// touch a real device path). Excluded from the coverage gate for the reason
// check.sh records: these closures need a real, volume-settable output device,
// which a headless CI runner doesn't have.
extension AudioDucker {
  struct Client: Sendable {
    /// The default output device's virtual main volume in 0...1 — the
    /// device-wide scalar the volume keys move — or nil when there is no
    /// default output device, it has no main volume, or the volume isn't
    /// settable (some HDMI and AirPlay outputs). Settability is checked on the
    /// read so nil means "don't duck": a volume we could read but never put
    /// back must not be lowered in the first place.
    var outputVolume: @Sendable () -> Float? = {
      guard let device = AudioRoute.defaultOutputDeviceID(),
        AudioDucker.isVolumeSettable(on: device)
      else { return nil }
      var address = AudioDucker.volumeAddress()
      var volume = Float32(0)
      var size = UInt32(MemoryLayout<Float32>.size)
      let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
      guard status == noErr else { return nil }
      return volume
    }

    /// Sets the default output device's virtual main volume, clamped to 0...1.
    /// A failure — the device vanished between the read and this write — is a
    /// silent no-op: the dictation itself is unaffected either way, and the
    /// restore's touched-volume comparison already treats "not where we left
    /// it" as leave-it-alone.
    var setOutputVolume: @Sendable (Float) -> Void = { volume in
      guard let device = AudioRoute.defaultOutputDeviceID() else { return }
      var address = AudioDucker.volumeAddress()
      var value = Float32(min(max(volume, 0), 1))
      _ = AudioObjectSetPropertyData(
        device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// The default output device's CoreAudio UID — the stable identity the
    /// restore checks so it only ever moves the device the duck lowered (an
    /// `AudioDeviceID` is transient across launches and device replugs; the
    /// UID is not, which is why `MicDeviceStore` pins microphones by UID too).
    /// Nil when there is no default output device or the read fails; a duck
    /// recorded without an identity falls back to the volume comparison alone.
    var defaultOutputDeviceUID: @Sendable () -> String? = {
      guard let device = AudioRoute.defaultOutputDeviceID() else { return nil }
      var address = AudioRoute.globalAddress(kAudioDevicePropertyDeviceUID)
      var uid: CFString?
      var size = UInt32(MemoryLayout<CFString?>.size)
      // The HAL hands back a +1-retained CFString; landing it in a managed
      // `CFString?` slot lets Swift balance that retain at scope exit.
      let status = withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
      }
      guard status == noErr, let uid else { return nil }
      return uid as String
    }

    /// The real client — what the public initializer uses.
    static let production = Client()
  }

  /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` — 'vmvc' — spelled
  /// as its four-char code because the named constant lives in AudioToolbox's
  /// AudioHardwareService.h, not in CoreAudio, and the engine's framework set
  /// stays where it is (the same reason `AudioRoute` spells `kAudioObjectUnknown`
  /// as a literal: don't depend on how a constant imports). The selector itself
  /// is served by the plain `AudioObject*PropertyData` calls below — only the
  /// old `AudioHardwareService*` entry points around it were deprecated.
  private static let virtualMainVolumeSelector = AudioObjectPropertySelector(0x766D_7663)

  /// The virtual main volume on the output scope: the one device-wide scalar
  /// macOS's own volume keys and menu-bar slider move, which the HAL maps onto
  /// per-channel controls where the hardware has those. Returned fresh per
  /// call, like `AudioRoute.globalAddress`, because every caller passes it
  /// `inout` to CoreAudio.
  private static func volumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: virtualMainVolumeSelector,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
  }

  /// Whether the device carries the virtual main volume *and* lets us set it.
  /// Both halves matter: a device can lack the property entirely, or expose it
  /// read-only — digital outputs whose level the receiver owns — and ducking
  /// either would owe a restore we can never deliver.
  private static func isVolumeSettable(on device: AudioDeviceID) -> Bool {
    var address = volumeAddress()
    guard AudioObjectHasProperty(device, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
    return settable.boolValue
  }
}
