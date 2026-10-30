/// The names the Keys tab gives its read and ask actions. The tab's menu, the
/// ready screen's key rows, the Read Aloud tab's footers and the UI tests all
/// quote them, so they're spelled once — here in `Shared/`, where the UI tests
/// can reach them too.
enum KeyActionName {
  static let readAloud = "Read Selection Aloud"
  static let ask = "Ask About Selection"
}
