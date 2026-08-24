import Testing

@testable import BlurtEngine

/// The service names are the whole contract with `tccutil`: it exits 0 for a
/// name it doesn't know as readily as for one it does, so a typo here is a reset
/// that silently clears nothing while reporting success. `reset` itself isn't
/// exercised — running it would clear the developer's own grants — so the names
/// and the roster are what a test can hold.
@Suite("PermissionsReset.Service")
struct PermissionsResetTests {
  @Test("names the services tccutil knows")
  func serviceNames() {
    #expect(PermissionsReset.Service.accessibility.rawValue == "Accessibility")
    #expect(PermissionsReset.Service.microphone.rawValue == "Microphone")
    // Input Monitoring's internal name — what `tccutil` takes, and not what
    // System Settings calls the row.
    #expect(PermissionsReset.Service.inputMonitoring.rawValue == "ListenEvent")
  }

  /// `resetAll` walks the hand-written `sweep` (Periphery can't follow a case
  /// reached only through `allCases`), so this is what keeps that list honest: a
  /// service added to the enum and forgotten there would otherwise survive every
  /// "full" reset in silence. The three are also the ones
  /// `scripts/reset-install.sh` lists — a fourth belongs in both places.
  @Test("the sweep covers every service the enum names")
  func sweepCoversEveryService() {
    #expect(Set(PermissionsReset.sweep) == Set(PermissionsReset.Service.allCases))
    #expect(Set(PermissionsReset.sweep) == [.accessibility, .microphone, .inputMonitoring])
  }
}
