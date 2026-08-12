import Foundation
import Testing

@testable import BlurtEngine

/// Exercises `KeychainMigration.read` against isolated service/account pairs so
/// the real `APIKeyStore` item is never touched (same discipline as
/// `KeychainStoreTests`). Serialized because keychain items are process-global
/// state. `.unavailable` can't be provoked here — it needs a locked keychain or
/// a denied ACL prompt — so these pin the reachable arms.
@Suite("KeychainMigration", .serialized)
struct KeychainMigrationTests {

  /// A current/legacy store pair sharing one throwaway account, mirroring the
  /// production shape (same account, two services). Cleaned up by `write(nil)`.
  private func makeStores() -> (current: KeychainStore, legacy: KeychainStore) {
    let account = "test-\(UUID().uuidString)"
    return (
      KeychainStore(service: "dev.alex.blurt.tests.current", account: account),
      KeychainStore(service: "dev.alex.blurt.tests.legacy", account: account)
    )
  }

  @Test("absent everywhere reads as absent")
  func absentEverywhere() {
    let (current, legacy) = makeStores()
    defer {
      current.write(nil)
      legacy.write(nil)
    }
    #expect(KeychainMigration.read(current: current, legacy: legacy) == .absent)
  }

  @Test("a key under the current service is returned and the legacy item is not touched")
  func currentWins() {
    let (current, legacy) = makeStores()
    defer {
      current.write(nil)
      legacy.write(nil)
    }
    #expect(current.write("sk-current"))
    #expect(legacy.write("sk-stale"))

    #expect(KeychainMigration.read(current: current, legacy: legacy) == .value("sk-current"))
    // The stale legacy item stays put: migration only runs when the current
    // service has nothing, so it can never overwrite a newer key with an older one.
    #expect(legacy.read() == .value("sk-stale"))
  }

  @Test("a legacy-only key is returned, moved to the current service, and deleted")
  func migratesLegacyKey() {
    let (current, legacy) = makeStores()
    defer {
      current.write(nil)
      legacy.write(nil)
    }
    #expect(legacy.write("sk-legacy"))

    #expect(KeychainMigration.read(current: current, legacy: legacy) == .value("sk-legacy"))
    #expect(current.read() == .value("sk-legacy"))
    #expect(legacy.read() == .absent)
  }

  @Test("migration is a one-shot: the second read comes from the current service")
  func secondReadHitsCurrent() {
    let (current, legacy) = makeStores()
    defer {
      current.write(nil)
      legacy.write(nil)
    }
    #expect(legacy.write("sk-legacy"))

    #expect(KeychainMigration.read(current: current, legacy: legacy) == .value("sk-legacy"))
    #expect(KeychainMigration.read(current: current, legacy: legacy) == .value("sk-legacy"))
    #expect(legacy.read() == .absent)
  }
}
