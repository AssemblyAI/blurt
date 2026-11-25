import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

struct ComposeCall: Equatable, Sendable {
  let instructions: String
  let app: String?
}
