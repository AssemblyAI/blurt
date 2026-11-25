#if os(macOS)
  public import Foundation

  /// What the Record button captures from: the microphone and system audio
  /// together (`SystemAudioRecorder`) in the app, an offline double under UI
  /// testing, where the test host has neither grant. Exactly the calls a
  /// recording makes, in the shapes `SystemAudioRecorder` already answers them.
  public protocol RecordingCapture: AnyObject {
    /// Starts capturing into the audio file at `url`, handing `onPCM` each
    /// slice of 16 kHz mono S16LE as it is mixed.
    func start(to url: URL, onPCM: @escaping @Sendable (Data) -> Void) throws
    /// Stops capturing, writing and handing on audio until `resume`.
    func pause()
    /// Carries on after `pause`.
    func resume() throws
    /// Stops for good and closes the file.
    func stop()
  }
#endif
