import AVKit
import BlurtEngine
import CoreMedia
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
/// the next time the user leaves as a backstop. The recipe — the frame, the
/// layer's size, the start after the first frame renders, the hidden
/// controls — is the one proven on a phone (iPhone 13, iOS 18.7.8,
/// 2026-11-04); `PictureInPictureIdle` decides what the mic does around it.
@MainActor
@Observable
final class PictureInPictureKeeper: NSObject {
  nonisolated private static let log = HostIdentity.current.logger("PictureInPicture")
  /// Typeless's content aspect: 369 pt over 0.079 pt ≈ 4683 : 1.
  static let frameWidth = 4_683
  static let frameHeight = 1
  /// The layer's size on screen in points, the same aspect.
  static let sourceSize = CGSize(width: 369, height: 0.079)  // literal-ok: the PiP source's aspect, not a design size
  /// AVKit's private `controlsStyle` value for no controls at all.
  private static let hiddenControls = 2

  static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
  private static let startAttempts = 6
  private static let startRetry: Duration = .milliseconds(500)

  private static let stopPollStep: Duration = .milliseconds(50)

  let layer = AVSampleBufferDisplayLayer()
  private(set) var isArmed = false
  private(set) var isActive = false
  /// `disarm()` asked a live window to stop and `didStop` has not landed: the
  /// window is still active, and nothing may park under it.
  private(set) var isStopping = false
  private(set) var isPossible = false
  @ObservationIgnored var onStart: (() -> Void)?
  @ObservationIgnored var onStop: (() -> Void)?
  @ObservationIgnored private var controller: AVPictureInPictureController?
  @ObservationIgnored private var possible: NSKeyValueObservation?
  @ObservationIgnored private var startWanted = false

  @ObservationIgnored private var attempts = 0

  override init() {
    super.init()
    layer.videoGravity = .resize
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
    else {
      return nil
    }
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) {
      memset(base, 0, CVPixelBufferGetBytesPerRow(pixels) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        == noErr, let format
    else {
      return nil
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
      )
        == noErr, let sample
    else {
      return nil
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        first,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sample
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
      let pip = AVPictureInPictureController(contentSource: source)
      pip.delegate = self
      pip.requiresLinearPlayback = true
      // Hides the window's play/pause and skip controls — the only thing a
      // zero-height window still draws, and what Typeless's shows as
      // `controlsStyle: None` in the phone log. The key is not public API
      // (0 default, 1 minimal, 2 hidden); the same call ships in Typeless and
      // in open-source call apps. App Review risk noted in the plan.
      pip.setValue(Self.hiddenControls, forKey: "controlsStyle")
      self.controller = pip
      possible = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
        let value = change.newValue ?? false
        Task { @MainActor in self?.possibleChanged(value) }
      }
    }
    controller?.canStartPictureInPictureAutomaticallyFromInline = true
    isArmed = true
    enqueueFrame()
    let possibleNow = controller?.isPictureInPicturePossible ?? false
    Self.log.notice("armed; possible: \(possibleNow) state: \(UIApplication.shared.applicationState.rawValue)")
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

  private func startWhenRendering() async {
    for _ in 0..<20 where layer.sampleBufferRenderer.status != .rendering || layer.superlayer == nil {
      try? await Task.sleep(for: .milliseconds(50))
    }
    tryStart()
  }

  private func tryStart() {
    guard startWanted, let controller else {
      return
    }
    guard !controller.isPictureInPictureActive else {
      // Up already — or still stopping, in which case the start keeps and
      // `didStop` tries it again.
      if !isStopping { startWanted = false }
      return
    }
    let bounds = layer.bounds
    let placement = "bounds \(bounds.width)x\(bounds.height); renderer \(layer.sampleBufferRenderer.status.rawValue)"
    guard controller.isPictureInPicturePossible else {
      let onScreen = layer.superlayer != nil
      Self.log.notice("start wanted, not possible yet (on screen: \(onScreen); \(placement, privacy: .public))")
      return
    }
    attempts += 1
    let state = UIApplication.shared.applicationState.rawValue
    Self.log.notice("startPictureInPicture #\(self.attempts); state: \(state); \(placement, privacy: .public)")
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

  /// Stops the window and keeps it from starting again. The stop lands later,
  /// as `didStop`; `isStopping` says so until then.
  func disarm() {
    isArmed = false
    startWanted = false
    controller?.canStartPictureInPictureAutomaticallyFromInline = false
    if controller?.isPictureInPictureActive == true {
      isStopping = true
      controller?.stopPictureInPicture()
    }
    Self.log.notice("disarmed")
  }

  /// Waits for a stop `disarm()` asked for to land, at most `timeout`: a
  /// window still stopping past that is logged and left to its `didStop`.
  func waitUntilStopped(timeout: Duration) async {
    let polls = Int(timeout / Self.stopPollStep)
    for _ in 0..<polls where isStopping {
      try? await Task.sleep(for: Self.stopPollStep)
    }
    if isStopping { Self.log.notice("still stopping after \(timeout, privacy: .public)") }
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
    Self.log.notice("frame enqueued \(Self.frameWidth)x\(Self.frameHeight); renderer \(renderer.status.rawValue)")
  }
}

extension PictureInPictureKeeper: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_: AVPictureInPictureController) {
    Self.log.notice("will start")
  }

  func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
    isActive = true
    startWanted = false
    Self.log.notice("did start; state: \(UIApplication.shared.applicationState.rawValue)")
    onStart?()
  }

  func pictureInPictureControllerWillStopPictureInPicture(_: AVPictureInPictureController) {
    Self.log.notice("will stop")
  }

  func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
    isActive = false
    isStopping = false
    Self.log.notice("did stop; state: \(UIApplication.shared.applicationState.rawValue)")
    // A start asked for while it was stopping is the next window's: this
    // stop is nobody's news, and the window goes up again for it.
    guard startWanted else {
      onStop?()
      return
    }
    tryStart()
  }

  func pictureInPictureController(
    _: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
  ) {
    let code = (error as NSError).code
    Self.log.error("failed to start: \(error.localizedDescription, privacy: .public) code \(code)")
    startFailed()
  }

  func pictureInPictureController(
    _: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: (Bool) -> Void
  ) {
    Self.log.notice("restore user interface")
    completionHandler(true)
  }
}

/// Nothing to play, pause or skip: the controls answer and change nothing.
extension PictureInPictureKeeper: AVPictureInPictureSampleBufferPlaybackDelegate {
  nonisolated func pictureInPictureController(_: AVPictureInPictureController, setPlaying _: Bool) {
    // Nothing plays: the window only keeps the app alive, so play and pause change nothing.
  }

  nonisolated func pictureInPictureControllerTimeRangeForPlayback(
    _: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  nonisolated func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
    false
  }

  nonisolated func pictureInPictureController(
    _: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    Self.log.notice("render size \(newRenderSize.width)x\(newRenderSize.height)")
  }

  nonisolated func pictureInPictureController(
    _: AVPictureInPictureController,
    skipByInterval _: CMTime,
    completion completionHandler: () -> Void
  ) {
    completionHandler()
  }

  nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _: AVPictureInPictureController
  ) -> Bool { false }
}
