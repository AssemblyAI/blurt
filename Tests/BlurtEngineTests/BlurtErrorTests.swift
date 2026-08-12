import Foundation
import Testing

@testable import BlurtEngine

@Suite("BlurtError")
struct BlurtErrorTests {
  @Test("each non-wrapping case has a non-empty errorDescription")
  func descriptionsExist() {
    let cases: [BlurtError] = [
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
    #expect(BlurtError.accessibilityPermissionMissing == .accessibilityPermissionMissing)
    #expect(BlurtError.noEditableTarget == .noEditableTarget)
  }

  @Test("different singleton cases compare unequal")
  func unequalSingletons() {
    #expect(BlurtError.apiKeyMissing != .targetAppLost)
    #expect(BlurtError.accessibilityPermissionMissing != .apiKeyMissing)
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

  /// `diagnosticName` is the field the error log is aggregated on, so a duplicate
  /// or empty label would silently merge two distinct failures into one bucket.
  @Test("diagnosticName is unique and non-empty across every case")
  func diagnosticNamesAreDistinct() {
    let e = NSError(domain: "X", code: 1)
    let all: [BlurtError] = [
      .accessibilityPermissionMissing,
      .apiKeyMissing,
      .sttFailed(underlying: e),
      .targetAppLost,
      .audioCaptureFailed(underlying: e),
      .noEditableTarget,
    ]
    let names = all.map(\.diagnosticName)
    #expect(names.allSatisfy { !$0.isEmpty })
    #expect(Set(names).count == all.count)
  }

  /// The label must survive rewording of the human-facing copy — that's the whole
  /// reason it's a separate property rather than a slice of `errorDescription`.
  @Test("diagnosticName is a stable case label, not derived from the description")
  func diagnosticNamesAreCaseLabels() {
    let underlying = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    #expect(BlurtError.apiKeyMissing.diagnosticName == "apiKeyMissing")
    #expect(BlurtError.sttFailed(underlying: underlying).diagnosticName == "sttFailed")
    // Two `.sttFailed`s with different underlying errors share one bucket.
    #expect(
      BlurtError.sttFailed(underlying: NSError(domain: "Other", code: 9)).diagnosticName
        == BlurtError.sttFailed(underlying: underlying).diagnosticName)
  }

  /// The classification the inject `catch` reads to choose the quiet "copied"
  /// notice over the red flash. Pinned per case: getting one wrong is invisible in
  /// review — it only shows up as a fault the user shouldn't have seen, or a real
  /// failure silently swallowed as a degradation.
  @Test("only the two copy-fallback errors are quiet degradations")
  func quietDegradationsAreTheCopyFallbacks() {
    let e = NSError(domain: "X", code: 1)
    #expect(BlurtError.noEditableTarget.isQuietDegradation)
    #expect(BlurtError.targetAppLost.isQuietDegradation)
    #expect(!BlurtError.accessibilityPermissionMissing.isQuietDegradation)
    #expect(!BlurtError.apiKeyMissing.isQuietDegradation)
    #expect(!BlurtError.sttFailed(underlying: e).isQuietDegradation)
    #expect(!BlurtError.audioCaptureFailed(underlying: e).isQuietDegradation)
  }
}
