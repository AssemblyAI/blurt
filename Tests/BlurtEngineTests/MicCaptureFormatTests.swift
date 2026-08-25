import Foundation
import Testing

@testable import BlurtEngine

/// Pure-logic tests for `MicCapture`'s level-metering math and the capture
/// errors' user-facing wording. The recorder capture lifecycle itself needs a
/// real device and is exercised by the env-gated `MicCaptureLevelsTests` and
/// `AudioInputDevicesTests`.
@Suite("MicCapture metering & errors")
struct MicCaptureFormatTests {
  // MARK: - dBFS → linear level

  @Test func fullScalePowerMapsToOne() {
    #expect(MicCapture.linearLevel(fromPowerDB: 0) == 1)
  }

  @Test(
    "silence at or below the meter floor maps to zero",
    arguments: [MicCapture.meterFloorDB, -80, -.infinity, .nan] as [Float])
  func silenceMapsToZero(_ powerDB: Float) {
    #expect(MicCapture.linearLevel(fromPowerDB: powerDB) == 0)
  }

  @Test func aboveFullScaleClampsToOne() {
    // dBFS can momentarily read above 0 on clipping input; the meter must pin
    // at full bars, not overshoot past the 0…1 range the overlay expects.
    #expect(MicCapture.linearLevel(fromPowerDB: 3) == 1)
  }

  @Test func midScaleMapsLinearlyInDecibels() {
    // Linear across [-50 dB, 0 dB]: halfway (-25 dB) ≈ 0.5, and louder reads higher.
    #expect(abs(MicCapture.linearLevel(fromPowerDB: -25) - 0.5) < 0.01)
    #expect(MicCapture.linearLevel(fromPowerDB: -11) > MicCapture.linearLevel(fromPowerDB: -22))
  }

  // MARK: - Error wording

  @Test func noInputDeviceHasHumanReadableMessage() {
    // This message reaches the overlay via BlurtError.audioCaptureFailed's
    // interpolation of the underlying error, so it must read like a sentence,
    // not the default "(… error 0.)" gibberish a bare enum produces.
    #expect(MicCaptureError.noInputDevice.errorDescription == "No microphone is available.")
  }

  @Test func inputNeverDeliveredHasHumanReadableMessage() {
    // The liveness gate's fail-closed outcome — same route to the pill as
    // noInputDevice above, and the same sentence requirement. Together the two
    // also keep MicCaptureError.swift's errorDescription fully covered.
    #expect(MicCaptureError.inputNeverDelivered.errorDescription == "The microphone didn't start.")
  }
}
