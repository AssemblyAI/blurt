import Foundation
import Testing

@testable import BlurtEngine

@Suite("Planner eval · recorded screens")
struct PlannerScreenEvalTests {
  @Test("every recording yields cases, each naming an element its screen lists")
  func generated() throws {
    let cases = try PlannerEval.screenCases()
    #expect(Set(cases.map(\.id)).count == cases.count)
    for name in RecordedNode.names {
      #expect(cases.filter { $0.id.hasPrefix("\(name)-") }.count >= 3, "\(name) yields too few cases")
    }
    for item in cases {
      #expect(item.unlistedLines.isEmpty, "\(item.id): \(item.unlistedLines)")
    }
    // The same cases every run: the seed is the recording's name.
    #expect(try PlannerEval.screenCases().map(\.id) == cases.map(\.id))
  }
}
