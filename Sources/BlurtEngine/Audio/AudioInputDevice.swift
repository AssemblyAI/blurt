@preconcurrency @unsafe import AVFoundation

/// One selectable input device: its persistent UID (what `MicDeviceStore` pins)
/// and its user-facing name (what the Settings picker shows).
public struct AudioInputDevice: Identifiable, Sendable {
  public let uid: String
  public let name: String
  public var id: String { uid }
}
