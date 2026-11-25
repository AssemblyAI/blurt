#if os(macOS)
  import CoreAudio
  import Foundation

  /// Which apps are using a microphone (and which are playing audio) right
  /// now, read from Core Audio's process objects
  /// (`kAudioHardwarePropertyProcessObjectList`, then each one's
  /// `kAudioProcessPropertyIsRunningInput`/`…Output` and bundle id). HAL reads
  /// only — the policy that turns the answer into
  /// start and stop is `MeetingAutoRecord`, which is tested; this needs real
  /// hardware, and is excluded from the coverage gate with the other HAL files.
  public enum MeetingMicProbe {
    /// The bundle ids of every process with live microphone input, and of
    /// every process with live audio output.
    public static func bundleIDsUsingAudio() -> (mic: Set<String>, playing: Set<String>) {
      var mic = Set<String>()
      var playing = Set<String>()
      for process in systemProcessObjects() {
        let input = isRunning(kAudioProcessPropertyIsRunningInput, process)
        let output = isRunning(kAudioProcessPropertyIsRunningOutput, process)
        guard input || output, let bundleID = bundleID(of: process) else { continue }
        if input { mic.insert(bundleID) }
        if output { playing.insert(bundleID) }
      }
      return (mic, playing)
    }

    /// The meeting on, if any: a conferencing app holds the mic, or a browser
    /// holds it while playing audio.
    public static func meetingInProgress() -> MeetingAutoRecord.Meeting? {
      let audio = bundleIDsUsingAudio()
      return MeetingAutoRecord.meeting(in: audio.mic, playing: audio.playing)
    }

    /// Every process object, or none if the list can't be read.
    private static func systemProcessObjects() -> [AudioObjectID] {
      var address = AudioRoute.globalAddress(kAudioHardwarePropertyProcessObjectList)
      let system = AudioRoute.systemObject
      var dataSize: UInt32 = 0
      guard unsafe AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
        return []
      }
      var objects = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
      guard unsafe AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &objects) == noErr else {
        return []
      }
      return objects
    }

    private static func isRunning(_ selector: AudioObjectPropertySelector, _ process: AudioObjectID) -> Bool {
      var running: UInt32 = 0
      return AudioRoute.read(selector, of: process, into: &running) == noErr && running != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
      var bundleID: Unmanaged<CFString>?
      let status = unsafe AudioRoute.read(kAudioProcessPropertyBundleID, of: process, into: &bundleID)
      guard status == noErr, let string = unsafe bundleID?.takeRetainedValue() as String?, !string.isEmpty else {
        return nil
      }
      return string
    }
  }
#endif
