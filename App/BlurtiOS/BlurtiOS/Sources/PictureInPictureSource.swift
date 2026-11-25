import SwiftUI
import UIKit

/// Where the window starts from: the keeper's layer, inline, 369 × 0.079 pt.
/// It has to be in the view hierarchy for Picture in Picture to be possible.
struct PictureInPictureSource: UIViewRepresentable {
  final class LayerHost: UIView {
    private let hosted: CALayer

    init(hosted: CALayer) {
      self.hosted = hosted
      super.init(frame: .zero)
      layer.addSublayer(hosted)
      clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    /// The layer keeps its 0.079-pt height whatever the host is laid out at:
    /// SwiftUI rounds a view that thin to nothing, and a layer of no height
    /// is refused by Picture in Picture (Pegasus -1003).
    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      hosted.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PictureInPictureKeeper.sourceSize.height)
      CATransaction.commit()
    }
  }

  let keeper: PictureInPictureKeeper

  func makeUIView(context _: Context) -> LayerHost {
    LayerHost(hosted: keeper.layer)
  }

  func updateUIView(_: LayerHost, context _: Context) {
    // Nothing to update: the host shows the keeper's one layer for its whole life.
  }
}
