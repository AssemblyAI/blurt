package import Foundation

extension URL {
  /// A URL from a compile-time literal — the force-unwrap-free spelling for the
  /// engine's known-good constant URLs (`force_unwrapping` is banned repo-wide
  /// by SwiftLint). `StaticString` guarantees the argument is a literal, so a
  /// parse failure is a programmer error the first test run catches: trap with
  /// the offending literal rather than return an Optional nobody can act on.
  ///
  /// `package`, not `public`: the provider packages beside the engine
  /// (`BlurtAssemblyAI`) spell their constant URLs with it too, while
  /// periphery's `retain_public: false` gate requires that nothing be `public`
  /// unless the app itself uses it.
  package init(staticString: StaticString) {
    guard let url = URL(string: "\(staticString)") else {
      preconditionFailure("Invalid URL literal: \(staticString)")
    }
    self = url
  }
}
