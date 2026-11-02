#if os(macOS)
  import CoreAudio

  /// The CoreAudio reads that are left: which device is the default *output*, and
  /// the property addressing `AudioRouteMonitor` shares with it.
  ///
  /// The input side used to live here too — which device is the default input, and
  /// what transport it is on — and both have moved to `AVCaptureDevice`
  /// (`AudioInputDevices`), which answers them off the same object the recorder
  /// opens. That move waited on confirming `AVCaptureDevice.transportType` reports
  /// `blue` for AirPods, because a transport that failed to read as Bluetooth
  /// silently costs the 2.5 s liveness cap and the 220 ms tail linger — the
  /// missing-last-word bug both exist to fix. It does; the parallel HAL read went.
  ///
  /// Output has no such replacement: `AVCaptureDevice` describes *capture*
  /// devices, and what `AudioRouteMonitor` watches is the output route the cue
  /// players render into.
  ///
  /// Raw reads only — no policy. Needs real hardware to answer anything, so it is
  /// excluded from the coverage gate and must not be where a decision hides.
  ///
  /// Internal, not public: the app never asks these directly (it observes route
  /// *changes* through `AudioRouteMonitor`), and `.periphery.yml` runs with
  /// `retain_public: false`, so a `public` symbol only the engine reaches fails
  /// the unused-code scan.
  enum AudioRoute {
    /// The system's current default *output* device — what `AudioRouteMonitor`
    /// hangs its format listener on. Nil when there is none, or the read failed.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
      defaultDeviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - CoreAudio addressing

    /// The system-wide audio object, which owns the default-device properties.
    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    /// A global-scope address for `selector`. Returned fresh per call rather than
    /// stored, because every caller needs its own copy to pass `inout` to
    /// CoreAudio. Shared with `AudioRouteMonitor`, which addresses the same object
    /// graph and would otherwise restate this three-field literal.
    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
      AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - CoreAudio reads

    /// Reads `object`'s global property `selector` into `value`, sized to
    /// `Value` — the one spelling of a fixed-size HAL read, shared by the
    /// recorder and the meeting probe. The pointer goes through
    /// `withUnsafeMutablePointer`, which an unconstrained `Value` allows where
    /// a bare `&value` doesn't.
    static func read<Value>(
      _ selector: AudioObjectPropertySelector, of object: AudioObjectID, into value: inout Value
    ) -> OSStatus {
      var address = globalAddress(selector)
      var size = UInt32(MemoryLayout<Value>.size)
      return withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer($0))
      }
    }

    /// The device the system object reports for `selector` (a default-device
    /// property). Nil covers both a failed read and the "no such device" sentinel,
    /// which callers treat identically.
    private static func defaultDeviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
      var deviceID = AudioDeviceID(0)
      let status = read(selector, of: systemObject, into: &deviceID)
      // 0 is `kAudioObjectUnknown` — "there is no such device" — spelled as the
      // literal so this doesn't depend on how the constant imports.
      guard status == noErr, deviceID != 0 else { return nil }
      return deviceID
    }
  }
#endif
