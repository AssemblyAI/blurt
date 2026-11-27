import Foundation
import Testing

@testable import BlurtiOSCore

// The press's retry and deadline, stepped on a test clock — apart from the
// press and its answers, so neither file crowds the other.
extension KeyboardModelGateTests {
  @Test("the retry and the deadline fire on the clock by themselves")
  func pressTimers() async {
    let rig = KeyboardRig(store: store)
    let model = rig.model
    let clock = TestClock()
    model.clock = clock
    let start = Date()
    model.now = { start }
    model.tapMic()
    // Both ticks park on the clock: the retry's and the deadline's.
    #expect(await until { clock.sleepingFor.count == 2 })
    #expect(rig.commands.sent.map(\.kind) == [.press])
    // Each step lands just past its moment, the handshake's clock with it.
    let past = Duration.milliseconds(50)
    let retry = KeyboardModel.commandRetryDelay + past
    model.now = { start.addingTimeInterval(retry / .seconds(1)) }
    clock.advance(by: retry)
    #expect(await until { rig.commands.sent.count == 2 })
    #expect(rig.commands.sent.map(\.kind) == [.press, .press])
    #expect(!model.gate.isIdle, "a resend, not the deadline")
    let deadline = Duration.seconds(BlurtShared.pressDeadline) + past
    model.now = { start.addingTimeInterval(deadline / .seconds(1)) }
    clock.advance(by: deadline - retry)
    #expect(await until { model.gate.isIdle })
    #expect(model.handshake.unreadyReason == .unanswered)
    #expect(rig.commands.sent.count == 2)
  }
}
