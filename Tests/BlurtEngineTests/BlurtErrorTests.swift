import Foundation
import Testing

@testable import BlurtEngine

@Suite("BlurtError")
struct BlurtErrorTests {
  @Test("each non-wrapping case has a non-empty errorDescription")
  func descriptionsExist() {
    let cases: [BlurtError] = [
      .microphonePermissionDenied,
      .accessibilityPermissionMissing,
      .apiKeyMissing,
      .targetAppLost,
      .noEditableTarget,
    ]
    for c in cases {
      #expect(!(c.errorDescription ?? "").isEmpty)
    }
  }

  @Test("wrapping cases include the underlying error description")
  func wrappingCasesIncludeUnderlying() {
    let underlying = NSError(
      domain: "Test", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "boom-marker-42"
      ])
    let wrapped: [BlurtError] = [
      .sttFailed(underlying: underlying),
      .audioCaptureFailed(underlying: underlying),
    ]
    for w in wrapped {
      #expect(w.errorDescription?.contains("boom-marker-42") == true)
    }
  }

  @Test("equal singleton cases compare equal")
  func equalSingletons() {
    #expect(BlurtError.apiKeyMissing == .apiKeyMissing)
    #expect(BlurtError.targetAppLost == .targetAppLost)
    #expect(BlurtError.microphonePermissionDenied == .microphonePermissionDenied)
    #expect(BlurtError.accessibilityPermissionMissing == .accessibilityPermissionMissing)
    #expect(BlurtError.noEditableTarget == .noEditableTarget)
  }

  @Test("different singleton cases compare unequal")
  func unequalSingletons() {
    #expect(BlurtError.apiKeyMissing != .targetAppLost)
    #expect(BlurtError.microphonePermissionDenied != .accessibilityPermissionMissing)
    // The two quiet copy-fallback errors are distinct cases, not aliases.
    #expect(BlurtError.noEditableTarget != .targetAppLost)
  }

  @Test("wrapping cases compare by underlying NSError domain and code, not description")
  func wrappedEquality() {
    let a = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "same"])
    let differentIdentity = NSError(domain: "Y", code: 99, userInfo: [NSLocalizedDescriptionKey: "same"])
    let sameIdentityOtherMessage = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "different"])
    // Same human-facing message but a different domain/code → not equal: equality
    // tracks the error's stable identity, not its (localizable) description.
    #expect(BlurtError.sttFailed(underlying: a) != .sttFailed(underlying: differentIdentity))
    // Same domain/code but a different message → equal: the description is not
    // load-bearing, so rewording it can't change equality.
    #expect(BlurtError.sttFailed(underlying: a) == .sttFailed(underlying: sameIdentityOtherMessage))
  }

  @Test("wrapping cases of different kinds never compare equal")
  func crossKindInequality() {
    let e = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "same"])
    #expect(BlurtError.sttFailed(underlying: e) != .audioCaptureFailed(underlying: e))
  }
}
