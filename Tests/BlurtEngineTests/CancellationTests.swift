import Foundation
import Testing

@testable import BlurtEngine

/// The two cancellation rules every catch site shares: what a cancellation
/// looks like, and when one is the current task's work being abandoned.
@Suite("Cancellation-shaped errors")
struct CancellationTests {
  @Test("Swift's cancellation and a torn-down URLSession request look like one; other failures don't")
  func shape() {
    #expect(CancellationError().isCancellationShaped)
    #expect(URLError(.cancelled).isCancellationShaped)
    #expect(!URLError(.timedOut).isCancellationShaped)
    #expect(!URLError(.networkConnectionLost).isCancellationShaped)
  }

  @Test("a cancellation-shaped error on a task nobody cancelled is not an abandonment")
  func droppedIsNotAbandonment() {
    #expect(!URLError(.cancelled).isAbandonment)
    #expect(!CancellationError().isAbandonment)
  }

  @Test("a cancellation-shaped error on a cancelled task is an abandonment; another failure still isn't")
  func cancelledIsAbandonment() async {
    let verdicts = Task {
      unsafe withUnsafeCurrentTask { unsafe $0?.cancel() }
      return [URLError(.cancelled).isAbandonment, CancellationError().isAbandonment, URLError(.timedOut).isAbandonment]
    }
    #expect(await verdicts.value == [true, true, false])
  }
}
