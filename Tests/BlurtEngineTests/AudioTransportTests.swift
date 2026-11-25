#if os(macOS)
  import CoreAudio
  import Foundation
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// The transport classification both the liveness cap and `MicCapture`'s tail
  /// linger hang off. Pure and pinned here because `AudioRoute`, which reads the
  /// raw value, needs real hardware and is excluded from the coverage gate — so
  /// this is the only place the decision can be tested.
  @Suite("AudioTransport")
  struct AudioTransportTests {
    @Test("both Bluetooth transport types count")
    func bluetoothTransports() {
      #expect(AudioTransport.isBluetooth(kAudioDeviceTransportTypeBluetooth))
      #expect(AudioTransport.isBluetooth(kAudioDeviceTransportTypeBluetoothLE))
    }

    @Test("the tail linger is Bluetooth-only")
    func tailLinger() {
      // The other transport-conditional policy, here rather than in `MicCapture`
      // so it is reachable by `swift test` at all — the capture actor needs real
      // hardware and is excluded from the coverage gate.
      #expect(
        AudioTransport.tailLinger(forTransportType: kAudioDeviceTransportTypeBluetooth)
          == AudioTransport.bluetoothTailLinger)
      // `.zero`, not a small duration: `stop()` skips the sleep entirely on a
      // wired input rather than awaiting a nominal one.
      #expect(AudioTransport.tailLinger(forTransportType: kAudioDeviceTransportTypeBuiltIn) == .zero)
      #expect(AudioTransport.tailLinger(forTransportType: nil) == .zero)
    }

    @Test("every wired and on-board transport counts as local")
    func localTransports() {
      // Each constant asserted individually: `isLocal` is a switch over all of
      // them, and a value that only matches the first pattern never executes the
      // rest — so this is also what keeps those lines covered.
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeBuiltIn))
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeUSB))
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypePCI))
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeFireWire))
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeThunderbolt))
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeDisplayPort))
      #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeHDMI))
    }

    @Test("Bluetooth, wrapped, unnamed and unreadable transports are not local")
    func nonLocalTransports() {
      // `isLocal` is deliberately not `!isBluetooth`: these all fall through to
      // `MicLiveness.unknownTransportTimeout`, because an aggregate or virtual
      // device reports its own transport while real AirPods switch underneath it.
      #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeAggregate))
      #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeVirtual))
      #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeUnknown))
      #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeBluetooth))
      #expect(!AudioTransport.isLocal(nil))
    }

    @Test("wired, built-in, and unreadable transports do not")
    func nonBluetoothTransports() {
      #expect(!AudioTransport.isBluetooth(kAudioDeviceTransportTypeBuiltIn))
      #expect(!AudioTransport.isBluetooth(kAudioDeviceTransportTypeUSB))
      #expect(!AudioTransport.isBluetooth(kAudioDeviceTransportTypeAggregate))
      // nil is the conservative answer for both consumers: the short wait cap and
      // no tail linger. Padding every wired capture with a delay would be a worse
      // regression than losing the tail on a device we couldn't classify.
      #expect(!AudioTransport.isBluetooth(nil))
    }
  }
#endif
