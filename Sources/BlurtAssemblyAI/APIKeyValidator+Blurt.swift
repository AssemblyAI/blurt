import AssemblyAI
public import BlurtEngine
import Foundation

extension APIKeyValidator {
  /// AssemblyAI's key check as Blurt sends it: with `UserAgent.current`, the same
  /// `Blurt/<version> (…)` agent the dictation requests carry, so a rejected key
  /// can be traced to the build that asked. The validator itself lives in the
  /// AssemblyAI SDK and knows nothing of Blurt; this is where the agent joins it.
  static func blurt(transport: any HTTPTransport = URLSession.shared) -> APIKeyValidator {
    APIKeyValidator(transport: transport, userAgent: UserAgent.current)
  }
}

extension KeyValidation {
  /// The engine's reading of the SDK's verdict: the same three outcomes.
  init(_ result: APIKeyValidator.Result) {
    switch result {
    case .valid:
      self = .valid

    case .invalid:
      self = .invalid

    case .unreachable:
      self = .unreachable
    }
  }
}

extension APIKeyModel {
  /// The key surface checking keys against AssemblyAI (`APIKeyValidator.blurt()`).
  public convenience init(keyStore: any APIKeyGateway = ProductionAPIKeyStore()) {
    self.init(keyStore: keyStore) { KeyValidation(await APIKeyValidator.blurt().validate($0)) }
  }
}
