import Foundation
import Testing
import UIKit

@testable import BlurtiOSCore

/// The host's bundle id, read without ever asking for a key nothing backs.
@Suite("HostApp")
@MainActor
struct HostAppTests {
  final class Holder: NSObject {
    @objc var _hostBundleID: String?  // swiftlint:disable:this identifier_name
    init(_ id: String?) { _hostBundleID = id }
  }

  @Test("a getter that answers is read; empty, '<null>' and a class with neither getter nor ivar read as nothing")
  func reading() {
    #expect(HostApp.read("_hostBundleID", from: Holder("com.apple.MobileSMS")) == "com.apple.MobileSMS")
    #expect(HostApp.read("_hostBundleID", from: Holder("<null>")) == nil)
    #expect(HostApp.read("_hostBundleID", from: Holder(" ")) == nil)
    #expect(HostApp.read("_hostBundleID", from: Holder(nil)) == nil)
    #expect(HostApp.read("hostBundleID", from: Holder("x")) == nil, "a key the holder does not have")
    #expect(HostApp.read("_hostBundleID", from: NSObject()) == nil)
  }

  @Test("a bare input view controller has no host, and says who was asked")
  func bareController() {
    let controller = UIInputViewController(nibName: nil, bundle: nil)
    #expect(HostApp.bundleID(of: controller) == nil)
    #expect(HostApp.holderNames(of: controller).first?.contains("UIInputViewController") == true)
    #expect(HostApp.keys == ["_hostBundleID", "hostBundleID"])
  }

  @Test("the hop carries the host the keyboard read")
  func hopCarriesHost() {
    let suite = ScratchSuite()
    defer { suite.tearDown() }
    let rig = KeyboardRig()
    let (hops, window) = rig.capturingHops()
    defer { window.isHidden = true }
    // No session: the tap hops rather than presses.
    KeyboardRig.listening(false)
    rig.model.readListeningState()
    rig.model.hostBundleID = "com.apple.MobileSMS"
    rig.model.tapMic()
    #expect(hops.opened.count == 1)
    #expect(hops.opened.first.map(BlurtShared.isStart) == true)
    #expect(hops.opened.first.flatMap(BlurtShared.hopHost) == "com.apple.MobileSMS")
  }
}
