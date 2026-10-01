import Foundation
import Testing

@testable import BlurtEngine

@Suite("GlobeKeyOverride")
struct GlobeKeyOverrideTests {
  private let system = freshDefaults()
  private let record = freshDefaults()
  private var override: GlobeKeyOverride { GlobeKeyOverride(system: system, record: record) }
  private var usage: Int? { system.object(forKey: GlobeKeyOverride.usageKey) as? Int }

  @Test("binding fn sets the 🌐 action to Do Nothing, and rebinding restores it")
  func overridesAndRestores() {
    system.set(2, forKey: GlobeKeyOverride.usageKey)  // Show Emoji & Symbols
    override.sync(boundKey: .function)
    #expect(usage == GlobeKeyOverride.doNothing)
    override.sync(boundKey: .rightCommand)
    #expect(usage == 2)
    #expect(record.object(forKey: GlobeKeyOverride.replacedUsageKey) == nil)
  }

  @Test("an unset system value is restored as unset, not pinned")
  func restoresUnset() {
    override.sync(boundKey: .function)
    #expect(usage == GlobeKeyOverride.doNothing)
    override.sync(boundKey: .rightOption)
    #expect(system.object(forKey: GlobeKeyOverride.usageKey) == nil)
  }

  @Test("re-syncing fn keeps the original value and re-asserts the override")
  func resyncKeepsOriginal() {
    system.set(3, forKey: GlobeKeyOverride.usageKey)  // Start Dictation
    override.sync(boundKey: .function)
    // Changed back in System Settings while fn stayed bound; the next launch's
    // sync must not record Blurt's own override as "the original".
    system.set(1, forKey: GlobeKeyOverride.usageKey)
    override.sync(boundKey: .function)
    #expect(usage == GlobeKeyOverride.doNothing)
    override.sync(boundKey: .rightCommand)
    #expect(usage == 3)
  }

  @Test("a non-fn binding never touches the system setting")
  func nonFunctionIsNoOp() {
    system.set(2, forKey: GlobeKeyOverride.usageKey)
    override.sync(boundKey: .rightCommand)
    #expect(usage == 2)
  }

  @Test("the replaced value survives a settings reset")
  func survivesReset() {
    // The relaunch after Reset is what restores the setting (the trigger resets to
    // right ⌘), so the record must not be in the swept roster.
    #expect(!DefaultsKey.allCases.map(\.key).contains(GlobeKeyOverride.replacedUsageKey))
    let own = freshDefaults()
    system.set(2, forKey: GlobeKeyOverride.usageKey)
    override.sync(boundKey: .function)
    PersistedSettings.resetAll(in: own)
    override.sync(boundKey: TriggerKeyStore(defaults: own).triggerKey)
    #expect(usage == 2)
  }

  @Test("two builds binding fn share one record, so neither restores the other's override")
  func buildsShareOneRecord() {
    // Blurt and Blurt Dev are separate hosts over the same system setting. The
    // second to bind fn must not record the first's Do Nothing as the original.
    system.set(2, forKey: GlobeKeyOverride.usageKey)
    override.sync(boundKey: .function)  // one build
    override.sync(boundKey: .function)  // the other
    override.sync(boundKey: .rightCommand)
    #expect(usage == 2)
    override.sync(boundKey: .rightOption)  // the other rebinds too: nothing left to undo
    #expect(usage == 2)
  }
}
