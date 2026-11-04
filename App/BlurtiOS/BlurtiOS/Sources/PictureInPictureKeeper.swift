import AVKit
import BlurtEngine
import CoreMedia
import SwiftUI
import UIKit

/// What keeps the app running between dictations so the microphone can close
/// in between: a Picture in Picture window with no height.
///
/// iOS lets a recording start only from a process that is in front, or that
/// holds a foreground-like role — and a Picture in Picture scene gives the
/// process exactly that role for as long as the window exists, floating or
/// stashed off the screen edge. Typeless on iPhone ships this shape (read off
/// a phone log on 2026-11-04): a sample-buffer window whose content is 369 pt
/// wide and 0.079 pt tall, which iOS frames at 112 × 0 pt, so nothing is
/// visible. This keeper does the same: one frame of a 4683 × 1 "video", the
/// window started explicitly while Blurt is in front, and started on its own
/// the next time the user leaves as a backstop. SPIKE: logs everything.
@MainActor
@Observable
final class PictureInPictureKeeper: NSObject {
  nonisolated private static let log = HostIdentity.current.logger("PictureInPicture")
  /// Typeless's content aspect: 369 pt over 0.079 pt ≈ 4683 : 1.
  static let frameWidth = 4683
  static let frameHeight = 1
  /// The layer's size on screen in points, the same aspect.
  static let sourceSize = CGSize(width: 369, height: 0.079)
  /// AVKit's private `controlsStyle` value for no controls at all.
  private static let hiddenControls = 2

  let layer = AVSampleBufferDisplayLayer()
  private(set) var isArmed = false
  private(set) var isActive = false
  private(set) var isPossible = false
  @ObservationIgnored var onStart: (() -> Void)?
  @ObservationIgnored var onStop: (() -> Void)?
  @ObservationIgnored private var controller: AVPictureInPictureController?
  @ObservationIgnored private var possible: NSKeyValueObservation?
  @ObservationIgnored private var startWanted = false

  static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  override init() {
    super.init()
    layer.videoGravity = .resize
  }

  /// Creates the controller, enqueues the frame, and makes the window start
  /// on its own the next time the user leaves. Needs the audio session
  /// active, which the listening window's is.
  func arm() {
    guard Self.isSupported else {
      Self.log.error("picture in picture unsupported on this device")
      return
    }
    if controller == nil {
      let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      controller.requiresLinearPlayback = true
      // Hides the window's play/pause and skip controls — the only thing a
      // zero-height window still draws, and what Typeless's shows as
      // `controlsStyle: None` in the phone log. The key is not public API
      // (0 default, 1 minimal, 2 hidden); the same call ships in Typeless and
      // in open-source call apps. App Review risk noted in the plan.
      controller.setValue(Self.hiddenControls, forKey: "controlsStyle")
      self.controller = controller
      possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
        let value = change.newValue ?? false
        Task { @MainActor in self?.possibleChanged(value) }
      }
    }
    controller?.canStartPictureInPictureAutomaticallyFromInline = true
    isArmed = true
    enqueueFrame()
    Self.log.notice("armed; possible: \(self.controller?.isPictureInPicturePossible ?? false) state: \(UIApplication.shared.applicationState.rawValue)")
  }

  /// Starts the window while Blurt is in front — once the first frame has
  /// been rendered and the layer is on screen, which takes a run-loop turn or
  /// two after `arm()`; retried from the `isPictureInPicturePossible`
  /// observation and after a failure.
  func start() {
    startWanted = true
    attempts = 0
    Task { await startWhenRendering() }
  }

  @ObservationIgnored private var attempts = 0
  private static let startAttempts = 6
  private static let startRetry: Duration = .milliseconds(500)

  private func startWhenRendering() async {
    for _ in 0..<20 where layer.sampleBufferRenderer.status != .rendering || layer.superlayer == nil {
      try? await Task.sleep(for: .milliseconds(50))
    }
    tryStart()
  }

  private func tryStart() {
    guard startWanted, let controller else { return }
    guard !controller.isPictureInPictureActive else {
      startWanted = false
      return
    }
    let bounds = layer.bounds
    guard controller.isPictureInPicturePossible else {
      Self.log.notice(
        "start wanted, not possible yet (on screen: \(self.layer.superlayer != nil); bounds \(bounds.width)x\(bounds.height); renderer \(self.layer.sampleBufferRenderer.status.rawValue))"
      )
      return
    }
    attempts += 1
    Self.log.notice(
      "startPictureInPicture #\(self.attempts); state: \(UIApplication.shared.applicationState.rawValue); bounds \(bounds.width)x\(bounds.height); renderer \(self.layer.sampleBufferRenderer.status.rawValue)"
    )
    controller.startPictureInPicture()
  }

  private func startFailed() {
    guard startWanted, attempts < Self.startAttempts else {
      startWanted = false
      return
    }
    Task {
      try? await Task.sleep(for: Self.startRetry)
      tryStart()
    }
  }

  private func possibleChanged(_ value: Bool) {
    isPossible = value
    Self.log.notice("possible: \(value)")
    if value { tryStart() }
  }

  /// Stops the window and keeps it from starting again.
  func disarm() {
    isArmed = false
    startWanted = false
    controller?.canStartPictureInPictureAutomaticallyFromInline = false
    if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    Self.log.notice("disarmed")
  }

  /// One frame of a live "video": a 4683 × 1 transparent strip, shown the
  /// moment it is enqueued, on no timeline.
  private func enqueueFrame() {
    guard let sample = Self.sampleBuffer(width: Self.frameWidth, height: Self.frameHeight) else {
      Self.log.error("could not build the frame")
      return
    }
    let renderer = layer.sampleBufferRenderer
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
    renderer.enqueue(sample)
    Self.log.notice("frame enqueued \(Self.frameWidth)x\(Self.frameHeight); renderer status \(renderer.status.rawValue)")
  }

  private static func sampleBuffer(width: Int, height: Int) -> CMSampleBuffer? {
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
    ]
    var pixels: CVPixelBuffer?
    guard
      CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixels)
        == kCVReturnSuccess, let pixels
    else { return nil }
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) {
      memset(base, 0, CVPixelBufferGetBytesPerRow(pixels) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        == noErr, let format
    else { return nil }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        == noErr, let sample
    else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}

extension PictureInPictureKeeper: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    Self.log.notice("will start")
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    isActive = true
    startWanted = false
    Self.log.notice("did start; state: \(UIApplication.shared.applicationState.rawValue)")
    onStart?()
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
    Self.log.notice("will stop")
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    isActive = false
    Self.log.notice("did stop; state: \(UIApplication.shared.applicationState.rawValue)")
    onStop?()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
  ) {
    let code = (error as NSError).code
    Self.log.error("failed to start: \(error.localizedDescription, privacy: .public) code \(code)")
    startFailed()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    Self.log.notice("restore user interface")
    completionHandler(true)
  }
}

/// Nothing to play, pause or skip: the controls answer and change nothing.
extension PictureInPictureKeeper: AVPictureInPictureSampleBufferPlaybackDelegate {
  nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

  nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    Self.log.notice("render size \(newRenderSize.width)x\(newRenderSize.height)")
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ controller: AVPictureInPictureController
  ) -> Bool { false }
}

/// Where the window starts from: the keeper's layer, inline, 369 × 0.079 pt.
/// It has to be in the view hierarchy for Picture in Picture to be possible.
struct PictureInPictureSource: UIViewRepresentable {
  let keeper: PictureInPictureKeeper

  func makeUIView(context: Context) -> LayerHost {
    LayerHost(hosted: keeper.layer)
  }

  func updateUIView(_ view: LayerHost, context: Context) {}

  final class LayerHost: UIView {
    private let hosted: CALayer

    init(hosted: CALayer) {
      self.hosted = hosted
      super.init(frame: .zero)
      layer.addSublayer(hosted)
      clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
}
