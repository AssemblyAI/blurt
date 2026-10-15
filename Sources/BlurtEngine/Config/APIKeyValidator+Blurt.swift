import AssemblyAI
import Foundation

extension APIKeyValidator {
  /// AssemblyAI's key check as Blurt sends it: with `UserAgent.current`, the same
  /// `Blurt/<version> (…)` agent the dictation requests carry, so a rejected key
  /// can be traced to the build that asked. The validator itself lives in the
  /// AssemblyAI SDK and knows nothing of Blurt; this is where the agent joins it.
  public static func blurt(transport: any HTTPTransport = URLSession.shared) -> APIKeyValidator {
    APIKeyValidator(transport: transport, userAgent: UserAgent.current)
  }
}
