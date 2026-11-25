import Synchronization

/// What one planning call saw and said, for the developer-mode command log:
/// the user turn exactly as sent (the element list, fenced), every reply as
/// it came back (two when the plan was asked for again), the model, and a
/// short version of the instruction and schema, so a behaviour can be tied to
/// the prompt that produced it. Filled by the planner as it goes — it can
/// throw part way, and what it saw is most of the diagnosis then.
public final class PlanTrace: Sendable {
  public struct Snapshot: Sendable, Equatable {
    public var prompt: String?
    public var replies: [String] = []
    public var model: String?
    public var promptVersion: String?

    public init(prompt: String? = nil, replies: [String] = [], model: String? = nil, promptVersion: String? = nil) {
      self.prompt = prompt
      self.replies = replies
      self.model = model
      self.promptVersion = promptVersion
    }
  }

  private let state = Mutex(Snapshot())

  public var snapshot: Snapshot { state.withLock { $0 } }

  public init() {
    // Nothing to set up: the snapshot starts empty and the planner fills it.
  }

  func record(prompt: String, model: String, promptVersion: String) {
    state.withLock { snapshot in
      snapshot.prompt = prompt
      snapshot.model = model
      snapshot.promptVersion = promptVersion
    }
  }

  func record(reply: String) { state.withLock { $0.replies.append(reply) } }
}
