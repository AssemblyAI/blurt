import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

struct RewriteCall: Equatable, Sendable {
  let selection: String
  let request: String
}
