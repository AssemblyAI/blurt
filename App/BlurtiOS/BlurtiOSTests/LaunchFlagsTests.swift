import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOS

@Suite("LaunchFlags")
struct LaunchFlagsTests {
  @Test("a flag's value is read as UserDefaults reads an argument")
  func values() {
    let arguments = ["BlurtiOS", "-BlurtDeveloperMode", "YES", "-BlurtDeviceTrace", "NO", "-BlurtNoKey"]
    #expect(LaunchFlags.value(of: "BlurtDeveloperMode", in: arguments) == true)
    #expect(LaunchFlags.value(of: "BlurtDeviceTrace", in: arguments) == false)
    #expect(LaunchFlags.value(of: "BlurtNoKey", in: arguments) == nil)
    #expect(LaunchFlags.value(of: "BlurtProbe", in: arguments) == nil)
    #expect(LaunchFlags.value(of: "X", in: ["-X", "1"]) == true)
  }

  @Test("a launch writes the flags it carries and leaves the rest as they were")
  func persists() throws {
    let suite = "LaunchFlagsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "BlurtDeviceTrace")

    LaunchFlags.persist(
      ["BlurtDeveloperMode", "BlurtDeviceTrace"], arguments: ["-BlurtDeveloperMode", "YES"], into: defaults)
    #expect(defaults.bool(forKey: "BlurtDeveloperMode"))
    #expect(defaults.bool(forKey: "BlurtDeviceTrace"))

    LaunchFlags.persist(
      ["BlurtDeveloperMode", "BlurtDeviceTrace"], arguments: ["-BlurtDeviceTrace", "NO"], into: defaults)
    #expect(defaults.bool(forKey: "BlurtDeveloperMode"))
    #expect(!defaults.bool(forKey: "BlurtDeviceTrace"))
  }

  @Test("the persisted flags are the developer log's key and the trace's")
  func keys() {
    #expect(LaunchFlags.persisted == [DeveloperModeStore.defaultsKey, DeviceTrace.launchArgument])
    #expect(DeveloperModeStore.defaultsKey == "BlurtDeveloperMode")
  }
}
