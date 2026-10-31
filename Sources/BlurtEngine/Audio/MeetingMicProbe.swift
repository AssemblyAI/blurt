#if os(macOS)
  import CoreAudio
  import Foundation

  /// Which apps are using a microphone right now, read from Core Audio's
  /// process objects (`kAudioHardwarePropertyProcessObjectList`, then each
  /// one's `kAudioProcessPropertyIsRunningInput` and bundle id). HAL reads only — the policy that turns the answer into
  /// start and stop is `MeetingAutoRecord`, which is tested; this needs real
  /// hardware, and is excluded from the coverage gate with the other HAL files.
  public enum MeetingMicProbe {
    /// The bundle ids of every process with live microphone input.
    public static func bundleIDsUsingMic() -> Set<String> {
      let processes = systemProcessObjects()
      var result = Set<String>()
      for process in processes where isRunningInput(process) {
        if let bundleID = bundleID(of: process) { result.insert(bundleID) }
      }
      return result
    }

    /// Whether a meeting is on: a conferencing app or a browser holds the mic.
    public static func meetingInProgress() -> Bool {
      MeetingAutoRecord.indicatesMeeting(bundleIDsUsingMic())
    }

    /// Every process object, or none if the list can't be read.
    private static func systemProcessObjects() -> [AudioObjectID] {
      var address = AudioRoute.globalAddress(kAudioHardwarePropertyProcessObjectList)
      let system = AudioRoute.systemObject
      var dataSize: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
        return []
      }
      var objects = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
      guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &objects) == noErr else { return [] }
      return objects
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
      var running: UInt32 = 0
      return AudioRoute.read(kAudioProcessPropertyIsRunningInput, of: process, into: &running) == noErr && running != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
      var bundleID: Unmanaged<CFString>?
      let status = AudioRoute.read(kAudioProcessPropertyBundleID, of: process, into: &bundleID)
      guard status == noErr, let string = bundleID?.takeRetainedValue() as String?, !string.isEmpty else {
        return nil
      }
      return string
    }
  }
#endif
