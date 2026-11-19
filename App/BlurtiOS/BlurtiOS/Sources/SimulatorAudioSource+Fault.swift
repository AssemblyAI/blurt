#if targetEnvironment(simulator) && DEBUG
  import Foundation

  extension SimulatorAudioSource {
    /// `BLURT_SIM_FAULT`: one way the phone's microphone fails, reproduced in
    /// the simulator with the same failures and events (README, "Testing in
    /// the simulator"). The timed ones count from the window opening.
    nonisolated enum Fault: Equatable, Sendable {
      /// Every start — the window opening, a hold, a parked press — throws
      /// `configureFailed(errorCode)`.
      case refuseStart
      /// Every chunk is digital silence, so an utterance trips the watchdog.
      case silentFrames
      /// The microphone is taken after `seconds` (`interrupted`: no frames,
      /// presses refused) and given back `seconds` later (`interruptionEnded`).
      case interruptAfter(seconds: Double)
      /// The session dies after `seconds` (`runtimeError(errorCode)`) and
      /// stays dead until the window closes.
      case runtimeErrorAfter(seconds: Double)
      /// The route changes after `seconds` (`routeChanged`); nothing else does.
      case routeChangeAfter(seconds: Double)
      /// The window opens and holds; a parked press's start throws
      /// `backgroundStartRefused(backgroundRefusalCode)`.
      case refuseBackgroundStart

      static let environmentKey = "BLURT_SIM_FAULT"
      static let fromEnvironment = ProcessInfo.processInfo.environment[environmentKey].flatMap(parse)
      /// The simulator's own capture error: FigCaptureSessionSimulator's.
      static let errorCode = -12782
      /// `AVAudioSession.ErrorCode.cannotStartRecording` (`!rec`), what iOS
      /// answers a recording started from the background with.
      static let backgroundRefusalCode = 561_015_905
      static let interruptionReason = "audioDeviceInUseByAnotherClient"
      static let routeChangeReason = "newDeviceAvailable"
      static let routeInput = "BluetoothHFP"

      /// `refuseStart`, `silentFrames`, `refuseBackgroundStart`, or
      /// `interruptAfter:<s>` / `runtimeErrorAfter:<s>` / `routeChangeAfter:<s>`
      /// with a non-negative number of seconds; anything else is no fault.
      static func parse(_ value: String) -> Fault? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let seconds = parts.count == 2 ? Double(parts[1]).flatMap { $0 >= 0 ? $0 : nil } : nil
        return switch (parts.first, seconds) {
        case ("refuseStart", nil): .refuseStart
        case ("silentFrames", nil): .silentFrames
        case ("refuseBackgroundStart", nil): .refuseBackgroundStart
        case ("interruptAfter", let seconds?): .interruptAfter(seconds: seconds)
        case ("runtimeErrorAfter", let seconds?): .runtimeErrorAfter(seconds: seconds)
        case ("routeChangeAfter", let seconds?): .routeChangeAfter(seconds: seconds)
        default: nil
        }
      }

      /// When the timed fault fires, if this is one.
      var delay: Double? {
        switch self {
        case .interruptAfter(let seconds), .runtimeErrorAfter(let seconds), .routeChangeAfter(let seconds): seconds
        case .refuseStart, .silentFrames, .refuseBackgroundStart: nil
        }
      }
    }
  }
#endif
