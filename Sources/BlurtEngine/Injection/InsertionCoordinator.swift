import AppKit
import Foundation

public actor InsertionCoordinator {
  private let injector: KeyInjector

  public init(injector: KeyInjector = KeyInjector(pasteSettleDuration: .milliseconds(450))) {
    self.injector = injector
  }

  public func insert(
    recordID: UUID, exactText: String, capturedTarget: NSRunningApplication?,
    priorText: String? = nil, windowTitle: String? = nil
  ) async throws {
    await injector.setTargetApp(capturedTarget)
    try await injector.insert(
      recordID: recordID, text: exactText, after: priorText,
      windowTitle: windowTitle)
  }
}
