/// How one step of a command ran, for the command log: the step as planned,
/// how the performer carried it out ("AXPress, then click"), how long it took,
/// and the error it ended the command with, if any.
public struct StepRecord: Sendable, Equatable, Encodable {
  public let step: String
  public let how: String?
  public let milliseconds: Int
  public let error: String?
}
