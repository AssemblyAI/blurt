import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Stands in for whatever the body producer might fail with — an unencodable
/// `config` part, in production.
struct ProducerFailure: Error {}
