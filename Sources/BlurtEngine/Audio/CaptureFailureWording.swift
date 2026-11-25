public import Foundation

/// An error a microphone throws whose `errorDescription` is already a sentence
/// written for the user — "A call or another app has the microphone." — so
/// `BlurtError.audioCaptureFailed` says it as it is rather than burying it
/// under "Audio capture failed: …". The engine's own `MicCaptureError`
/// conforms; a host with its own capture source (the iPhone's listening
/// window) conforms its errors too, and the pill, the keyboard and any other
/// reader of the phase get its words without unwrapping the failure
/// themselves. An error that doesn't conform keeps the prefix as context.
public protocol CaptureFailureWording: LocalizedError {}
