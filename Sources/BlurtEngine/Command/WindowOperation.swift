/// What a `window` step does to the frontmost app's focused window.
public enum WindowOperation: String, CaseIterable, Sendable {
  case minimize
  case fullScreen = "full_screen"
  case maximize
  case center
  case leftHalf = "left_half"
  case rightHalf = "right_half"
  case topHalf = "top_half"
  case bottomHalf = "bottom_half"
  case nextDisplay = "next_display"
}
